#!/usr/bin/env bats
# bin/codex-lane-run.sh never signals a process group that is not codex's own (#143). `ps` can run
# before codex's setpgrp and report the runner's group, which is its caller's group. Each test runs
# the runner in a fresh process group next to a sentinel that records any INT or TERM, so a signal
# to the runner's group shows up as a sentinel hit and never reaches bats.
# Run: bats scripts/codex-lane-run-pgid.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  RUNNER="$SCRIPTS/../../../bin/codex-lane-run.sh"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  export HOME="$BATS_TEST_TMPDIR/home" MARK="$BATS_TEST_TMPDIR/mark" HIT="$BATS_TEST_TMPDIR/sentinel-hit"
  unset CODEX_LANE_SERVICE_TIER CODEX_LANE_MESSAGE_CHARS
  CD="$BATS_TEST_TMPDIR/lane"; mkdir -p "$CD"
  SPEC="$BATS_TEST_TMPDIR/spec.md"
  printf 'LANE-WORKTREE: %s\ntask\n' "$(cd "$CD" && pwd -P)" >"$SPEC"
  L="$BATS_TEST_TMPDIR/run/codex.jsonl"
  REAL_PS=$(command -v ps); export REAL_PERL; REAL_PERL=$(command -v perl)
  # Fake codex: one process, no output, no children; an INT or TERM marks it and ends it.
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null; echo $$ >"$MARK.pid"
exec "$REAL_PERL" -e '$SIG{INT} = $SIG{TERM} = sub { open my $f, ">", $ENV{MARK}; print $f "interrupted\n"; exit 0 };
  open my $f, ">", $ENV{MARK}; print $f "started\n"; close $f; sleep 1 while 1'
SH
  chmod +x "$FAKEBIN/codex"
}

# A runner that signalled the wrong group leaves codex running; do not let it outlive the test.
teardown() {
  if [[ -f $MARK.pid ]]; then kill -KILL "$(cat "$MARK.pid")" 2>/dev/null || true; fi
}

# Run the runner in its own process group beside a sentinel; sets rc and leaves stderr in $ERR.
run_in_group() {
  ERR="$BATS_TEST_TMPDIR/stderr"
  cat >"$BATS_TEST_TMPDIR/group.sh" <<'SH'
#!/usr/bin/env bash
"$REAL_PERL" -e '$SIG{INT} = $SIG{TERM} = sub { open my $f, ">>", $ENV{HIT}; print $f "hit\n"; exit 0 }; sleep 1 while 1' &
sentinel=$!
rc=0; "$@" || rc=$?
kill -KILL "$sentinel" 2>/dev/null; wait "$sentinel" 2>/dev/null
exit "$rc"
SH
  chmod +x "$BATS_TEST_TMPDIR/group.sh"
  rc=0
  PATH="$FAKEBIN:$PATH" "$REAL_PERL" -e 'setpgrp(0, 0); exec @ARGV or die' "$BATS_TEST_TMPDIR/group.sh" \
    "$RUNNER" --model gpt-6-luna --spec "$SPEC" --final "$BATS_TEST_TMPDIR/final.md" --log "$L" --cd "$CD" "$@" \
    >/dev/null 2>"$ERR" 3>&- || rc=$?
}

# A ps whose pgid answers name the caller's (the runner's) group: the stub runs in that group.
# With a count file, only the first N pgid answers lie.
lying_ps() {
  cat >"$FAKEBIN/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *pgid=*)
    if [[ -n "\${LIES:-}" ]]; then
      n=\$(cat "$BATS_TEST_TMPDIR/ps-count" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" >"$BATS_TEST_TMPDIR/ps-count"
      ((n > LIES)) && exec "$REAL_PS" "\$@"
    fi
    exec "$REAL_PS" -o pgid= -p \$\$ ;;
esac
exec "$REAL_PS" "\$@"
SH
  chmod +x "$FAKEBIN/ps"
}

@test "ps always reports the runner's group: no group signal, and a stall still stops codex by pid" {
  lying_ps
  run_in_group --poll 1 --stall 1 --hard 60
  [ "$rc" -eq 125 ]
  [ "$(cat "$L.exit")" = 125 ]
  [ ! -e "$HIT" ]
  [ "$(cat "$MARK")" = interrupted ]
  [[ "$(cat "$ERR")" == *"process group is not confirmed"* ]]
}

@test "ps reports the runner's group at first: the runner waits for codex's own group, and the hard cap stops it" {
  # The runner's own group lookup takes the first answer; the next two answers about codex lie.
  lying_ps
  export LIES=3
  run_in_group --poll 1 --stall 60 --hard 1
  [ "$rc" -eq 124 ]
  [ "$(cat "$L.exit")" = 124 ]
  [ ! -e "$HIT" ]
  [ "$(cat "$MARK")" = interrupted ]
  [ "$(cat "$BATS_TEST_TMPDIR/ps-count")" -gt 3 ]
  [ "$(grep -c 'not confirmed' "$ERR" || true)" -eq 0 ]
}

@test "codex's setpgrp delayed past the 2 s wait: pid-only signals until a later poll confirms its group" {
  # perl (which calls setpgrp) starts 2.5 s late, so the initial bounded wait gives up.
  printf '#!/usr/bin/env bash\nsleep 2.5\nexec %s "$@"\n' "$REAL_PERL" >"$FAKEBIN/perl"
  chmod +x "$FAKEBIN/perl"
  run_in_group --poll 1 --stall 60 --hard 4
  [ "$rc" -eq 124 ]
  [ ! -e "$HIT" ]
  [ "$(cat "$MARK")" = interrupted ]
  [[ "$(cat "$ERR")" == *"process group is not confirmed"* ]]
}

@test "a TERM to the runner before codex's group is confirmed interrupts codex by pid, not the caller's group" {
  lying_ps
  rc=0
  cat >"$BATS_TEST_TMPDIR/group.sh" <<'SH'
#!/usr/bin/env bash
"$REAL_PERL" -e '$SIG{INT} = $SIG{TERM} = sub { open my $f, ">>", $ENV{HIT}; print $f "hit\n"; exit 0 }; sleep 1 while 1' &
sentinel=$!
"$@" & runner=$!
for _ in $(seq 1 50); do [ "$(cat "$MARK" 2>/dev/null)" = started ] && break; sleep 0.1; done
kill -TERM "$runner"; rc=0; wait "$runner" || rc=$?
kill -KILL "$sentinel" 2>/dev/null; wait "$sentinel" 2>/dev/null
exit "$rc"
SH
  chmod +x "$BATS_TEST_TMPDIR/group.sh"
  PATH="$FAKEBIN:$PATH" "$REAL_PERL" -e 'setpgrp(0, 0); exec @ARGV or die' "$BATS_TEST_TMPDIR/group.sh" \
    "$RUNNER" --model gpt-6-luna --spec "$SPEC" --final "$BATS_TEST_TMPDIR/final.md" --log "$L" --cd "$CD" --poll 1 \
    >/dev/null 2>&1 3>&- || rc=$?
  [ "$rc" -eq 143 ]
  [ "$(cat "$L.exit")" = 143 ]
  [ ! -e "$HIT" ]
  [ "$(cat "$MARK")" = interrupted ]
}
