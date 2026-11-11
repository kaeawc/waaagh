#!/usr/bin/env bats
# Slot claims against the stale sweep (#236): a claim in progress is never swept, a live holder is
# never swept, and a claim that lost its slot retries. The windows are opened deterministically with
# the test-only pause points in _slots.sh (SLOT_TEST_PAUSE=POINT:DIR), not with sleeps.
# Run: bats slot-race.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_SLOT_DIR="$BATS_TEST_TMPDIR/slots" SLOT_POLL=0.05
  unset ORCHESTRATE_GATE_ENV SLOT_TEST_PAUSE
  T=$BATS_TEST_TMPDIR L="$BATS_TEST_TMPDIR/log"
  mkdir -p "$T/a" "$T/b"
}

gate() { "$SCRIPTS/gate-slot.sh" "$@"; }
held() { echo "while [ ! -e '$T/release-$1' ]; do sleep 0.05; done"; }
release() { touch "$T/release-$1"; }
await() { local _; for _ in $(seq 1 200); do eval "$1" && return 0; sleep 0.05; done; echo "timed out: $1"; return 1; }
stale_slot() {
  mkdir -p "$ORCHESTRATE_SLOT_DIR/gate/slot-1"
  printf '999999\nMon Jan 1 00:00:00 1990\nghost\n' >"$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder"
}

teardown() {
  release a; release b
  touch "$T/a/claim.go" "$T/a/sweep.go" "$T/b/claim.go" "$T/b/sweep.go"
}

@test "a sweeper that judged a slot stale never takes a claim made since; one gate runs at a time" {
  stale_slot
  # B judges slot-1 stale and pauses just before sweeping it.
  SLOT_TEST_PAUSE="sweep:$T/b" gate --slots 1 --wait 20 -- bash -c "echo start >>'$L'; $(held a); echo end >>'$L'" 2>"$T/b.err" &
  await '[ -e "$T/b/sweep.reached" ]'
  # A arrives meanwhile: it either waits for B's sweep or claims slot-1 and pauses mid-write.
  SLOT_TEST_PAUSE="claim,lockwait:$T/a" gate --slots 1 --wait 20 -- bash -c "echo start >>'$L'; $(held a); echo end >>'$L'" 2>"$T/a.err" &
  await '[ -e "$T/a/claim.reached" ] || [ -e "$T/a/lockwait.reached" ]'
  touch "$T/b/sweep.go"
  touch "$T/a/claim.go"
  await '[ "$(grep -c start "$L" 2>/dev/null)" = 1 ]'
  sleep 0.3   # time for the other gate to start, if it did not wait
  [ "$(grep -c start "$L")" -eq 1 ]
  [ "$(find "$ORCHESTRATE_SLOT_DIR/gate" -name holder | wc -l | tr -d ' ')" -eq 1 ]
  release a
  wait
  [ "$(tr '\n' ' ' <"$L")" = "start end start end " ]
  run cat "$T/a.err" "$T/b.err"
  [[ "$output" != *"No such file"* ]]
  [[ "$output" != *"cannot stat"* ]]
  [ ! -e "$ORCHESTRATE_SLOT_DIR/gate/slot-1" ]
}

@test "a claim whose slot vanished mid-write retries and holds a complete slot" {
  SLOT_TEST_PAUSE="claim:$T/a" gate --slots 1 --wait 20 -- bash -c "cat '$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder' >'$T/seen'" 2>"$T/a.err" &
  await '[ -e "$T/a/claim.reached" ]'
  # The slot is swept out from under the claimer (as a lock-breaking sweeper would).
  rm -rf "$ORCHESTRATE_SLOT_DIR/gate/slot-1"
  touch "$T/a/claim.go"
  wait
  [ "$(sed -n 3p "$T/seen")" = gate ]
  run cat "$T/a.err"
  [[ "$output" != *"No such file"* ]]
  [[ "$output" != *"cannot stat"* ]]
}

@test "a live holder is not swept when its start time cannot be read" {
  mkdir -p "$ORCHESTRATE_SLOT_DIR/gate/slot-1" "$T/bin"
  printf '%s\nMon Jan 1 00:00:00 1990\nlive\n' "$$" >"$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder"
  # ps fails under load: no start time to compare.
  printf '#!/bin/sh\nexit 1\n' >"$T/bin/ps"; chmod +x "$T/bin/ps"
  PATH="$T/bin:$PATH" run gate --slots 1 --wait 1 -- true
  [ "$status" -eq 75 ]
  [ "$(sed -n 3p "$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder")" = live ]
}

@test "a holder written while ps failed (no start time) still counts as live" {
  mkdir -p "$ORCHESTRATE_SLOT_DIR/gate/slot-1"
  printf '%s\n\nlive\n' "$$" >"$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder"
  run gate --slots 1 --wait 1 -- true
  [ "$status" -eq 75 ]
  [ "$(sed -n 3p "$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder")" = live ]
}

@test "a lock left by a dead claimer is broken, so gates do not stall" {
  mkdir -p "$ORCHESTRATE_SLOT_DIR/gate/.lock"
  echo 999999 >"$ORCHESTRATE_SLOT_DIR/gate/.lock/pid"
  run gate --slots 1 --wait 5 -- echo ran
  [ "$status" -eq 0 ]
  [ "$output" = ran ]
}

@test "a live claimer's lock makes slot_try give up within its bound; an hour-old one is broken" {
  source "$SCRIPTS/_slots.sh"
  mkdir -p "$ORCHESTRATE_SLOT_DIR/gate/.lock"
  echo "$$" >"$ORCHESTRATE_SLOT_DIR/gate/.lock/pid"
  run slot_try gate 1 "$$" unit
  [ "$status" -eq 1 ]
  [ ! -e "$ORCHESTRATE_SLOT_DIR/gate/slot-1" ]
  touch -t "$(date -d '-1 hour' +%Y%m%d%H%M 2>/dev/null || date -v-1H +%Y%m%d%H%M)" "$ORCHESTRATE_SLOT_DIR/gate/.lock"
  run slot_try gate 1 "$$" unit
  [ "$status" -eq 0 ]
  [ "$output" = "$ORCHESTRATE_SLOT_DIR/gate/slot-1" ]
  [ "$(sed -n 3p "$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder")" = unit ]
  [ ! -e "$ORCHESTRATE_SLOT_DIR/gate/.lock" ]
}
