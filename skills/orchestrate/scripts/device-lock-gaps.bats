#!/usr/bin/env bats
# device-lock.sh paths the other suites do not reach: the lock path from --repo, --stale-hours, a
# guard left by a dead process (broken, the claim goes on), and a lock file that cannot be written
# (exit 3). A guard held by a live process is waited on for 5 s; that wait is not tested here.
# Run: bats scripts/device-lock-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
  unset ORCHESTRATE_DEVICE_LOCK_DIR
  L="$BATS_TEST_TMPDIR/locks/device.lock"; mkdir -p "${L%/*}"
}

dl() { run "$SCRIPTS/device-lock.sh" "$@"; }

@test "--repo puts the lock under that repo's state dir" {
  dl claim --name a --no-pid --repo o/r
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = claimed ]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/device.lock" ]
  dl status --repo o/r
  [[ "$output" == "held name=a pid=0 age=0 live=yes" ]]
}

@test "--stale-hours sets when an old lock may be taken over" {
  dl claim --name a --no-pid --path "$L"
  [ "$status" -eq 0 ]
  export ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 7200))
  dl claim --name b --no-pid --path "$L"
  [ "$status" -eq 3 ]
  [ "$output" = "held by a (pid 0, 7200s)" ]
  dl claim --name b --no-pid --path "$L" --stale-hours 1
  [ "$status" -eq 0 ]
  [ "$(awk 'NR == 1 { print $3 }' "$L")" = b ]
}

@test "a guard left by a dead process is broken and the claim goes on" {
  mkdir "$L.guard"; echo 2147483646 >"$L.guard/pid"
  dl claim --name a --no-pid --path "$L"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = claimed ]
  [ ! -e "$L.guard" ]
}

@test "a lock file that cannot be written loses the race (exit 3)" {
  mkdir "$L"   # a directory where the lock file goes: the write fails
  dl claim --name a --no-pid --path "$L"
  [ "$status" -eq 3 ]
  [ "$output" = "lost the race for $L" ]
  [ ! -e "$L.guard" ]
}
