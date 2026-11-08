#!/usr/bin/env bats
# bin/codex-lane-run.sh paths selftest-lanes.bats does not reach: the log name built from the model
# slug, a --cd that is not a git work tree, the process-group CPU time parsed from `ps -o time=`
# (m:s and h:m:s), soft checkpoints, a TERM that interrupts codex's process group, and a failure
# after the exit trap is armed. Fake codex and ps on PATH.
# Not tested (real multi-second waits): the TERM and KILL escalation when codex ignores INT (5 s in
# the exit trap, 60 s after a stall or the hard cap).
# Run: bats scripts/codex-lane-run-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  RUNNER="$SCRIPTS/../../../bin/codex-lane-run.sh"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  export HOME="$BATS_TEST_TMPDIR/home" MARK="$BATS_TEST_TMPDIR/mark"
  unset CODEX_LANE_SERVICE_TIER CODEX_LANE_MESSAGE_CHARS
  CD="$BATS_TEST_TMPDIR/my lane"; mkdir -p "$CD"
  SPEC="$BATS_TEST_TMPDIR/spec.md"
  printf 'LANE-WORKTREE: %s\ntask\n' "$(cd "$CD" && pwd -P)" >"$SPEC"
}

# A runner or fake codex that outlives its test keeps bats' fd 3 open, and bats then waits for it
# forever: every runner here starts with fd 3 closed (3>&-), and long-lived children record their
# PIDs in $BATS_TEST_TMPDIR/leftover.pids, killed here.
teardown() {
  local p
  if [[ -f "$BATS_TEST_TMPDIR/leftover.pids" ]]; then
    while read -r p; do kill -KILL "$p" 2>/dev/null || true; done <"$BATS_TEST_TMPDIR/leftover.pids"
  fi
}

@test "no --log: the log is named from the model slug under the worktree's lane dir; CPU time, checkpoints, non-git --cd" {
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
out=""; while (($#)); do [[ $1 == --output-last-message ]] && out=$2; shift; done
cat >/dev/null; sleep 1.5; echo done >"$out"
SH
  real=$(command -v ps)
  # 1:05 is m:s (65 s), 1:00:02.50 is h:m:s (3602 s): 3667 s for the group.
  printf '#!/usr/bin/env bash\ncase "$*" in *time=*) printf "  1:05\\n1:00:02.50\\n\\n" ;; *) exec %s "$@" ;; esac\n' "$real" >"$FAKEBIN/ps"
  chmod +x "$FAKEBIN/codex" "$FAKEBIN/ps"
  run env PATH="$FAKEBIN:$PATH" "$RUNNER" --model gpt-6-luna --spec "$SPEC" --final "$BATS_TEST_TMPDIR/final.md" \
    --cd "$CD" --poll 1 --soft 1 3>&-
  [ "$status" -eq 0 ]
  logs=("$HOME/.claude/codex-lanes/my_lane/"luna-*-*.jsonl)
  [ "${#logs[@]}" -eq 1 ] && [ -f "${logs[0]}" ]
  L=${logs[0]}
  [[ "$output" == *"log=$L "* ]]
  [ "$(cat "$L.exit")" = 0 ]
  grep -qx 'Codex process-group CPU seconds: 3667' "$L.progress.latest"
  grep -q '(not a git work tree)' "$L.progress.state"
  grep -q 'Changed entries: 0' "$L.progress.state"
  [ "$(grep -c '^---$' "$L.progress")" -ge 1 ]
  [ "$(readlink "$HOME/.claude/codex-lanes/my_lane/latest.jsonl")" = "$L" ]
}

@test "a TERM to the runner interrupts codex's process group and records exit 143" {
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
trap 'echo interrupted >"$MARK"; exit 0' INT
cat >/dev/null; echo $$ >>"$BATS_TEST_TMPDIR/leftover.pids"; echo started >"$MARK"
while :; do sleep 0.1; done
SH
  # The runner reads codex's process group with `ps -o pgid=` right after the fork; delay that read
  # so codex's setpgrp has run (read too early, it names the runner's own group). The runner also
  # gets a process group of its own, so a signal to the wrong group never reaches bats.
  real=$(command -v ps)
  printf '#!/usr/bin/env bash\ncase "$*" in *pgid=*) sleep 0.5 ;; esac\nexec %s "$@"\n' "$real" >"$FAKEBIN/ps"
  chmod +x "$FAKEBIN/codex" "$FAKEBIN/ps"
  L="$BATS_TEST_TMPDIR/run/codex.jsonl"
  PATH="$FAKEBIN:$PATH" perl -e 'setpgrp(0, 0); exec @ARGV or die' "$RUNNER" --model gpt-6-luna --spec "$SPEC" \
    --final "$BATS_TEST_TMPDIR/final.md" --log "$L" --cd "$CD" --poll 1 >/dev/null 2>&1 3>&- &
  pid=$!
  echo "$pid" >>"$BATS_TEST_TMPDIR/leftover.pids"
  for _ in $(seq 1 50); do [ "$(cat "$MARK" 2>/dev/null)" = started ] && break; sleep 0.1; done
  [ "$(cat "$MARK")" = started ]
  kill -TERM "$pid"
  rc=0; wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ "$(cat "$L.exit")" = 143 ]
  [ "$(cat "$MARK")" = interrupted ]
}

@test "a failure after the exit trap is armed still writes .exit with its status, and codex never starts" {
  printf '#!/usr/bin/env bash\ntouch "%s/codex-ran"\n' "$BATS_TEST_TMPDIR" >"$FAKEBIN/codex"; chmod +x "$FAKEBIN/codex"
  : >"$BATS_TEST_TMPDIR/afile"
  L="$BATS_TEST_TMPDIR/run/codex.jsonl"; mkdir -p "${L%/*}"
  run env PATH="$FAKEBIN:$PATH" "$RUNNER" --model gpt-6-luna --spec "$SPEC" --final "$BATS_TEST_TMPDIR/afile/final.md" \
    --log "$L" --cd "$CD" --poll 1 3>&-
  [ "$status" -eq 1 ]
  [ "$(cat "$L.exit")" = 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/codex-ran" ]
  [ ! -e "$L.args" ]
}
