#!/usr/bin/env bats
# loops.sh: loop scripts installed in the state dir, per-pass heartbeats, and the startup status a
# new orchestrator reads (#80). Run: bats loops.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
  ST="$ORCHESTRATE_STATE_DIR/o__r"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "unexpected gh call: $*" >&2; exit 9\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  printf '#!/usr/bin/env bash\necho pass\n' >"$BATS_TEST_TMPDIR/merge-loop.sh"
}

@test "install copies a scratchpad script into <state dir>/bin, executable" {
  run "$SCRIPTS/loops.sh" install merge-loop "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "installed $ST/bin/merge-loop" ]
  [ -x "$ST/bin/merge-loop" ]
  [ "$("$ST/bin/merge-loop")" = pass ]
  printf '#!/usr/bin/env bash\necho v2\n' >"$BATS_TEST_TMPDIR/merge-loop.sh"
  "$SCRIPTS/loops.sh" install merge-loop "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  [ "$("$ST/bin/merge-loop")" = v2 ]
  [ -z "$(find "$ST/bin" -name '*.tmp.*')" ]
}

@test "usage errors exit 2" {
  run "$SCRIPTS/loops.sh" install merge-loop --repo o/r; [ "$status" -eq 2 ]
  run "$SCRIPTS/loops.sh" install merge-loop "$BATS_TEST_TMPDIR/nope" --repo o/r; [ "$status" -eq 2 ]
  run "$SCRIPTS/loops.sh" install ../x "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r; [ "$status" -eq 2 ]
  run "$SCRIPTS/loops.sh" heartbeat --repo o/r; [ "$status" -eq 2 ]
  run "$SCRIPTS/loops.sh" heartbeat tick --every soon --repo o/r; [ "$status" -eq 2 ]
  run "$SCRIPTS/loops.sh" status --stale x --repo o/r; [ "$status" -eq 2 ]
  run "$SCRIPTS/loops.sh" bogus --repo o/r; [ "$status" -eq 2 ]
  run "$SCRIPTS/loops.sh" -h; [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "# Long-lived campaign loops"* ]]
  [[ "${lines[${#lines[@]}-1]}" == "#       4 a loop's script is missing"* ]]
}

@test "no loops: status says none and exits 0" {
  run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 0 ]; [ "$output" = "loops none" ]
}

@test "heartbeat each pass; a fresh beat with a live pid is alive" {
  "$SCRIPTS/loops.sh" install merge-loop "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  run "$SCRIPTS/loops.sh" heartbeat merge-loop --repo o/r --pid $$ --every 600
  [ "$status" -eq 0 ]
  [ "$output" = "beat=$ORCHESTRATE_NOW pid=$$ host=$(hostname) every=600" ]
  [ "$(cat "$ST/loops/merge-loop.heartbeat")" = "$output" ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 300)) run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "loops ok" ]
  [ "${lines[1]}" = "loop merge-loop alive last_pass=5m script=$ST/bin/merge-loop" ]
}

@test "no beat inside 3x --every (or --stale, or 1800s) is stale: exit 3" {
  "$SCRIPTS/loops.sh" install tick "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  "$SCRIPTS/loops.sh" heartbeat tick --repo o/r --pid 0 --every 60
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 181)) run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "loops act stale=tick" ]
  [ "${lines[1]}" = "loop tick stale last_pass=3m script=$ST/bin/tick" ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 181)) run "$SCRIPTS/loops.sh" status --repo o/r --stale 600
  [ "$status" -eq 0 ]
  "$SCRIPTS/loops.sh" heartbeat tick --repo o/r --pid 0
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 1700)) run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 1801)) run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 3 ]
}

@test "a gone pid on this host is dead; a pid from another host is not checked" {
  "$SCRIPTS/loops.sh" install merge-loop "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  "$SCRIPTS/loops.sh" heartbeat merge-loop --repo o/r --pid 999999
  run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "loops act dead=merge-loop" ]
  [ "${lines[1]}" = "loop merge-loop dead last_pass=0m script=$ST/bin/merge-loop" ]
  echo "beat=$ORCHESTRATE_NOW pid=999999 host=elsewhere every=0" >"$ST/loops/merge-loop.heartbeat"
  run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 0 ]
}

@test "--end records why the loop stopped and keeps the last beat" {
  "$SCRIPTS/loops.sh" install merge-loop "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  "$SCRIPTS/loops.sh" heartbeat merge-loop --repo o/r --pid 0 --every 600
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 120)) run "$SCRIPTS/loops.sh" heartbeat merge-loop --repo o/r --end bound
  [ "$output" = "ended=bound at=$((ORCHESTRATE_NOW + 120)) beat=$ORCHESTRATE_NOW pid=0 host=$(hostname) every=600" ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 120)) run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "loops act ended=merge-loop" ]
  [ "${lines[1]}" = "loop merge-loop ended:bound last_pass=2m script=$ST/bin/merge-loop" ]
}

@test "a heartbeat with no installed script (ran from a scratchpad) is missing: exit 4" {
  "$SCRIPTS/loops.sh" install review "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  "$SCRIPTS/loops.sh" heartbeat review --repo o/r --pid 0
  mkdir -p "$ST/loops"
  echo "beat=$((ORCHESTRATE_NOW - 21600)) pid=4242 host=gone every=600" >"$ST/loops/merge-loop.heartbeat"
  run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = "loops act missing=merge-loop stale=merge-loop" ]
  [ "${lines[1]}" = "loop merge-loop stale last_pass=360m script=missing" ]
  [ "${lines[2]}" = "loop review alive last_pass=0m script=$ST/bin/review" ]
}

@test "an installed script that never beat, and a named loop with nothing at all" {
  "$SCRIPTS/loops.sh" install tick "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "loops act never=tick" ]
  [ "${lines[1]}" = "loop tick never last_pass=- script=$ST/bin/tick" ]
  run "$SCRIPTS/loops.sh" status merge-loop --repo o/r
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = "loops act missing=merge-loop never=merge-loop,tick" ]
  [ "${lines[1]}" = "loop merge-loop never last_pass=- script=missing" ]
}

@test "triage-tick.sh beat also beats the merge-loop heartbeat, and its --end" {
  "$SCRIPTS/loops.sh" install merge-loop "$BATS_TEST_TMPDIR/merge-loop.sh" --repo o/r
  "$SCRIPTS/triage-tick.sh" beat --repo o/r --deadline $((ORCHESTRATE_NOW + 3600)) --pid 0
  [ "$(cat "$ST/loops/merge-loop.heartbeat")" = "beat=$ORCHESTRATE_NOW pid=0 host=$(hostname) every=600" ]
  run "$SCRIPTS/loops.sh" status --repo o/r
  [ "$status" -eq 0 ]
  "$SCRIPTS/triage-tick.sh" beat --repo o/r --end bound
  run "$SCRIPTS/loops.sh" status --repo o/r
  [ "${lines[1]}" = "loop merge-loop ended:bound last_pass=0m script=$ST/bin/merge-loop" ]
}

@test "doctrine: startup checks loops; loop scripts live in the state dir" {
  grep -q 'loops.sh" status' "$ROOT/skills/orchestrate/SKILL.md"
  grep -q '`bin/`, `loops/`' "$ROOT/skills/orchestrate/SKILL.md"
  grep -q 'loops.sh" install merge-loop' "$ROOT/skills/orchestrate/roles/triage-tick.md"
  grep -q 'loops.sh' "$ROOT/README.md"
}
