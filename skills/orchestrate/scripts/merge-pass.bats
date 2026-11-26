#!/usr/bin/env bats
# merge-pass.sh (#411): one merge pass, the merge bot's steps 2-3 as a script. The scripts it runs
# (main-health, pr-ready, pr-merge, device-recheck, loops) are stubs (ORCHESTRATE_SCRIPTS_DIR);
# gh answers the untested-cap reads. Run: bats merge-pass.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx" ST="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$FX" "$ST" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_SCRIPTS_DIR="$ST" ORCHESTRATE_READ_SLEEP=0
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$STATE"
  # Stubs log their arguments to $FX/calls. main-health: $FX/main (line, exit from $FX/main-rc).
  # pr-ready: $FX/rows-<call number> or $FX/rows. pr-merge: exit from $FX/merge-<n> (default 0),
  # output from $FX/merge-<n>.out. device-recheck: exit 3 when $FX/held-<n> exists.
  cat >"$ST/main-health.sh" <<'STUB'
#!/bin/sh
echo "main-health $*" >>"$FX/calls"; cat "$FX/main" 2>/dev/null || echo "green abc"; exit "$(cat "$FX/main-rc" 2>/dev/null || echo 0)"
STUB
  cat >"$ST/pr-ready.sh" <<'STUB'
#!/bin/sh
echo "pr-ready $*" >>"$FX/calls"
n=$(( $(cat "$FX/ready-n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FX/ready-n"
[ ! -f "$FX/ready-fail" ] || exit 3
echo "extra=$PR_READY_EXTRA" >>"$FX/calls"
if [ -f "$FX/rows-$n" ]; then cat "$FX/rows-$n"; else cat "$FX/rows"; fi
echo "open=4 ready=3$(cat "$FX/ready-sum" 2>/dev/null)" >&2
STUB
  cat >"$ST/pr-merge.sh" <<'STUB'
#!/bin/sh
echo "pr-merge $*" >>"$FX/calls"
n=""; while [ $# -gt 0 ]; do [ "$1" = --pr ] && n=$2; shift; done
cat "$FX/merge-$n.out" 2>/dev/null || true
exit "$(cat "$FX/merge-$n" 2>/dev/null || echo 0)"
STUB
  cat >"$ST/device-recheck.sh" <<'STUB'
#!/bin/sh
echo "device-recheck $*" >>"$FX/calls"
n=""; while [ $# -gt 0 ]; do [ "$1" = --pr ] && n=$2; shift; done
if [ -f "$FX/held-$n" ]; then echo "held: #$n needs a device recheck"; exit 3; fi
if [ -f "$FX/crash-$n" ]; then exit 1; fi
echo "clear"
STUB
  cat >"$ST/loops.sh" <<'STUB'
#!/bin/sh
echo "loops $*" >>"$FX/calls"
STUB
  cat >"$ST/hold.sh" <<'STUB'
#!/bin/sh
echo "hold $*" >>"$FX/calls"; cat "$FX/holds" 2>/dev/null || true
STUB
  cat >"$ST/shipped-blocked.sh" <<'STUB'
#!/bin/sh
echo "shipped-blocked $*" >>"$FX/calls"; cat "$FX/shipped" 2>/dev/null || true
STUB
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"; all=${all% --include}
echo "gh $all" >>"$FX/calls"
case "$all" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  "api repos/o/r/actions/runs?"*) cat "$FX/green" 2>/dev/null ;;
  "api repos/o/r/compare/"*) cat "$FX/ahead" ;;
  "pr list --repo o/r --state open"*) [ ! -f "$FX/titles-fail" ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }; cat "$FX/titles" ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$ST"/*.sh "$BATS_TEST_TMPDIR/bin/gh"
  printf '12\tREADY\taaa12\tMERGEABLE\t3\t\n7\tREADY\taaa07\tMERGEABLE\t3\t\n9\tBLOCK\taaa09\tMERGEABLE\t1\tfail:build\n30\tREADY\taaa30\tMERGEABLE\t3\t\n' >"$FX/rows"
}
mp() { run "$SCRIPTS/merge-pass.sh" --repo o/r "$@"; }

@test "READY rows merge oldest first, priority file first, rows read again after each merge" {
  printf '30\n# comment\n' >"$STATE/merge-priority"
  mp --author me --ignore-check CodeRabbit --every 180 --loop-pid 4242
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "merged 30" ]
  [ "${lines[1]}" = "merged 7" ]
  [ "${lines[2]}" = "merged 12" ]
  [ "${lines[3]}" = "pass merged=3 held=0 ready=3 cap=8 untested=-" ]
  grep -qx 'pr-merge --repo o/r --author me --ignore-check CodeRabbit --pr 30 --head aaa30' "$FX/calls"
  grep -qx 'pr-ready --repo o/r --author me --ignore-check CodeRabbit --exclude-label needs-device-recheck' "$FX/calls"
  [ "$(cat "$FX/ready-n")" -eq 4 ]   # once, then after each of the 3 merges
  grep -qx "loops heartbeat merge-pass --repo o/r --pid 4242 --every 180" "$FX/calls"   # the loop PID, not the pass
  grep -qx 'extra= 30 ' "$FX/calls"                       # priority PRs classified off-page too
  grep -q '^hold check --repo o/r --release$' "$FX/calls"
  grep -q '^shipped-blocked --repo o/r --rows ' "$FX/calls"
}

@test "--cap stops the pass; a refused merge and a device hold are held, the pass goes on" {
  echo 7 >"$FX/merge-7"; echo "not ready: BLOCK threads=1" >"$FX/merge-7.out"
  touch "$FX/held-12"
  mp --cap 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "hold 7 exit=7 not ready: BLOCK threads=1" ]
  [ "${lines[1]}" = "hold 12 held: #12 needs a device recheck" ]
  [ "${lines[2]}" = "merged 30" ]
  [ "${lines[3]}" = "pass merged=1 held=2 ready=3 cap=1 untested=-" ]
  run grep -c '^pr-merge .*--pr 12 ' "$FX/calls"
  [ "$output" = 0 ]
}

@test "a red or unknown main holds the whole pass (exit 4); --dry-run merges nothing" {
  echo "red abc build=failure(1)" >"$FX/main"; echo 1 >"$FX/main-rc"
  mp
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = "hold main red abc build=failure(1)" ]
  run grep -c '^pr-ready' "$FX/calls"
  [ "$output" = 0 ]
  rm "$FX/main" "$FX/main-rc"
  mp --dry-run --cap 2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "would merge 7" ]
  [ "${lines[1]}" = "would merge 12" ]
  run grep -c '^pr-merge' "$FX/calls"
  [ "$output" = 0 ]
}

@test "--max-untested caps merges by commits past the last green run, and holds at the limit" {
  jq -n '{workflow_runs: [{name: "Lint", head_sha: "lint000000", created_at: "2026-11-02"},
    {name: "On Merge", head_sha: "older00000", created_at: "2026-11-01"},
    {name: "On Merge", head_sha: "deadbeef00", created_at: "2026-11-03"}]}' >"$FX/green"
  echo 1 >"$FX/ahead"
  mp --max-untested 3 --workflow "On Merge"
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "pass merged=2 held=0 ready=3 cap=2 untested=1" ]
  grep -qx 'main-health --repo o/r --workflow On Merge' "$FX/calls"
  echo 3 >"$FX/ahead"
  mp --max-untested 3 --workflow "On Merge"
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = "hold untested=3 since=deadbeef0" ]
  grep -q '^gh api repos/o/r/compare/deadbeef00...main' "$FX/calls"   # the newest green run
  echo '{"workflow_runs": []}' >"$FX/green"
  mp --max-untested 3 --workflow 'On "Merge"'
  [ "$status" -eq 4 ]
  [[ "${lines[0]}" == 'hold untested=unknown since=- (no green On "Merge" run on main)' ]]
  mp --max-untested 3 --workflow "On Merge"
  [ "$status" -eq 4 ]
  [[ "${lines[0]}" == "hold untested=unknown since=- (no green On Merge run on main)" ]]
}

@test "review #424: a device-recheck crash holds; met holds are released; a short page is reported" {
  touch "$FX/crash-7"
  printf '#5 met until:main-green\nreleased: PR 5 (until:main-green, held 2h)\n#6 met until:merged:4\n' >"$FX/holds"   # #6: the rewrite failed
  echo ' truncated=yes page=60' >"$FX/ready-sum"
  echo 'shipped-blocked #9 verdict=BLOCK reason=fail:build' >"$FX/shipped"
  mp --cap 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "released: PR 5 (until:main-green, held 2h)" ]
  [ "${lines[1]}" = "note pr-ready open=4 ready=3 truncated=yes page=60" ]
  [ "${lines[2]}" = "shipped-blocked #9 verdict=BLOCK reason=fail:build" ]
  [ "${lines[3]}" = "hold 7 device-recheck.sh exit 1" ]
  [ "${lines[4]}" = "merged 12" ]
}

@test "serial groups merge one PR per group per pass; the rest wait (#412)" {
  printf '# layout files\nweb  prototype-web|prototype\\(web\\)\n' >"$STATE/serial-groups"
  printf '7\tprototype-web: nav\n12\tProtoType-Web: header\n30\tfix crash\n' >"$FX/titles"
  mp
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "merged 7" ]
  [ "${lines[1]}" = "hold 12 serial:web (one merge per pass)" ]
  [ "${lines[2]}" = "merged 30" ]
  # The front cannot merge: the next of its group goes instead.
  echo 7 >"$FX/merge-7"; echo "not ready: BLOCK threads=1" >"$FX/merge-7.out"
  mp
  [ "${lines[0]}" = "hold 7 exit=7 not ready: BLOCK threads=1" ]
  [ "${lines[1]}" = "merged 12" ]
  touch "$FX/titles-fail"
  mp
  [ "$status" -eq 3 ]
}

@test "an outage stops the pass (exit 5); pr-ready failing is exit 3; usage errors are exit 2" {
  echo 10 >"$FX/merge-7"; echo "outage: Pull Requests degraded" >"$FX/merge-7.out"
  mp
  [ "$status" -eq 5 ]
  [ "${lines[1]}" = "stop outage outage: Pull Requests degraded" ]
  touch "$FX/ready-fail"
  mp
  [ "$status" -eq 3 ]
  mp --max-untested 3
  [ "$status" -eq 2 ]
  mp --cap x
  [ "$status" -eq 2 ]
}
