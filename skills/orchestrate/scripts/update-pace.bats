#!/usr/bin/env bats
# update-pace.sh (#219): a batch of CI-starting branch updates is paced by a per-pass cap, a gap
# between updates and, optionally, the host-load governor. gh is stubbed and the clock is
# ORCHESTRATE_NOW: nothing sleeps.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_SLOT_DIR="$BATS_TEST_TMPDIR/slots"
  export ORCHESTRATE_NOW=1790510400 PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  stub_spectra   # host-load.sh reads the host through spectra (#330): load 1 on 8 CPUs, 31.2 GB free
  export SPECTRA_STUB_LOAD1=1 SPECTRA_STUB_FREE_GB=31.2
  unset ORCHESTRATE_UPDATE_CAP ORCHESTRATE_UPDATE_GAP ORCHESTRATE_UPDATE_HOST_GATE ORCHESTRATE_UPDATE_HOST_ARGS
  # PUT .../pulls/N/update-branch: $FX/fail-N fails it, $FX/current-N answers "no new commits".
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api -X PUT repos/o/r/pulls/"*"/update-branch")
    all="$*"; n=${all#api -X PUT repos/o/r/pulls/}; n=${n%%/*}
    if [ -f "$FX/fail-$n" ]; then echo "gh: Merge conflict between base and head (HTTP 422)" >&2; exit 1; fi
    if [ -f "$FX/current-$n" ]; then echo "gh: There are no new commits on the base branch. (HTTP 422)" >&2; exit 1; fi
    echo '{"message":"Updating pull request branch."}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

up() { "$SCRIPTS/update-pace.sh" "$1" --repo o/r "${@:2}"; }
calls() { if [ -f "$FX/calls" ]; then grep -c update-branch "$FX/calls" || true; else echo 0; fi; }

@test "unconfigured: no pacing, every PR is updated in order and logged" {
  run up run --pr 3 --pr 1 --pr 2
  [ "$status" -eq 0 ]
  [ "$output" = $'updated 3\nupdated 1\nupdated 2' ]
  [ "$(calls)" -eq 3 ]
  [ "$(cut -f2 "$ORCHESTRATE_STATE_DIR/o__r/branch-updates.log" | paste -sd, -)" = 3,1,2 ]
  run up gate
  [ "$status" -eq 0 ]
  [ "$output" = go ]
}

@test "the per-pass cap defers the rest, in order, for the next pass" {
  ORCHESTRATE_UPDATE_CAP=2 run up run --pr 1 --pr 2 --pr 3 --pr 4
  [ "$status" -eq 3 ]
  [ "$output" = $'updated 1\nupdated 2\ndeferred 3 cap: 2 of 2 updates made this pass\ndeferred 4 cap: 2 of 2 updates made this pass' ]
  [ "$(calls)" -eq 2 ]
  # the next pass starts its own count
  run up run --cap 2 --pr 3 --pr 4
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 4 ]
  run up gate --cap 2 --done 2
  [ "$status" -eq 3 ]
  [[ "$output" == "wait cap: 2 of 2"* ]]
}

@test "the gap holds across passes and lifts on the fake clock" {
  export ORCHESTRATE_UPDATE_GAP=600
  run up run --pr 1 --pr 2
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "updated 1" ]
  [[ "${lines[1]}" == "deferred 2 gap: last update (PR 1) 0s ago, gap 600s, next=2026-09-27T12:10:00Z" ]]
  run up status
  [ "$output" = "last=2026-09-27T12:00:00Z pr=1 cap=0 gap=600 host-gate=off next=2026-09-27T12:10:00Z" ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 599)) run up run --pr 2
  [ "$status" -eq 3 ]
  [ "$(calls)" -eq 1 ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 600)) run up run --pr 2
  [ "$status" -eq 0 ]
  [ "$output" = "updated 2" ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 1300)) run up status
  [[ "$output" == *"pr=2 cap=0 gap=600 host-gate=off next=now" ]]
}

@test "a record from another caller (the merge queue) counts toward the gap" {
  run up record --source merge-queue
  [ "$output" = "recorded -" ]
  run up gate --gap 60
  [ "$status" -eq 3 ]
  [[ "$output" == "wait gap: last update (PR -) 0s ago"* ]]
  [ "$(cut -f3 "$ORCHESTRATE_STATE_DIR/o__r/branch-updates.log")" = merge-queue ]
  run up status
  [[ "$output" == "last=2026-09-27T12:00:00Z pr=- "* ]]
}

@test "status with no updates logged says never" {
  run up status --cap 3 --host-gate
  [ "$output" = "last=never pr=- cap=3 gap=0 host-gate=on next=now" ]
}

@test "the host gate waits on HOLD, BACKOFF, an unreadable verdict and a heavy build" {
  export ORCHESTRATE_UPDATE_HOST_GATE=1
  run up gate
  [ "$output" = go ]
  SPECTRA_STUB_LOAD1=40 run up gate
  [ "$status" -eq 3 ]
  [ "$output" = "wait host: host-load.sh says HOLD" ]
  SPECTRA_STUB_FREE_GB=0.9 run up run --pr 1
  [ "$status" -eq 3 ]
  [ "$output" = "deferred 1 host: host-load.sh says BACKOFF" ]
  [ "$(calls)" -eq 0 ]
  ORCHESTRATE_UPDATE_HOST_ARGS="--load-factor nope" run up gate
  [ "$output" = "wait host: host-load.sh exit 2 (unread, so held)" ]
  # the host-load flags pass through: a tighter factor holds the same load
  ORCHESTRATE_UPDATE_HOST_ARGS="--load-factor 0.1" run up gate
  [ "$output" = "wait host: host-load.sh says HOLD" ]
  mkdir -p "$ORCHESTRATE_SLOT_DIR/heavy/slot-1"
  echo $$ >"$ORCHESTRATE_SLOT_DIR/heavy/slot-1/holder"
  run up gate
  [ "$output" = "wait host: a heavy build holds its slot" ]
  run up gate --no-host-gate
  [ "$output" = go ]
}

@test "a failed update does not stop the run; an up-to-date PR is not counted" {
  touch "$FX/fail-2" "$FX/current-3"
  run up run --cap 2 --pr 2 --pr 3 --pr 4 --pr 5
  [ "$status" -eq 5 ]
  [ "${lines[0]}" = "failed 2 gh: Merge conflict between base and head (HTTP 422)" ]
  [ "${lines[1]}" = "current 3" ]
  [ "${lines[2]}" = "updated 4" ]
  [ "${lines[3]}" = "updated 5" ]
  [ "$(cut -f2 "$ORCHESTRATE_STATE_DIR/o__r/branch-updates.log" | paste -sd, -)" = 4,5 ]
}

@test "usage errors exit 2 before any gh call" {
  run up run
  [ "$status" -eq 2 ]
  run up run --pr x
  [ "$status" -eq 2 ]
  run up gate --cap -1
  [ "$status" -eq 2 ]
  run up record --pr 1 --pr 2
  [ "$status" -eq 2 ]
  run up gate --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPTS/update-pace.sh" nope
  [ "$status" -eq 2 ]
  run "$SCRIPTS/update-pace.sh" --bogus
  [ "$status" -eq 2 ]
  [ ! -f "$FX/calls" ]
}
