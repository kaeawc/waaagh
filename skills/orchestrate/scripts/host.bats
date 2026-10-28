#!/usr/bin/env bats
# Host-load governor: gate and heavy-build slots, and conservative worktree cleanup.
# Run: bats host.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_SLOT_DIR="$BATS_TEST_TMPDIR/slots" SLOT_POLL=0.2
  unset ORCHESTRATE_GATE_ENV
}

gate() { "$SCRIPTS/gate-slot.sh" "$@"; }
holders() { find "$ORCHESTRATE_SLOT_DIR/$1" -name holder 2>/dev/null | wc -l | tr -d ' '; }

@test "gates beyond the slot count wait, and every slot is freed afterwards" {
  for i in 1 2 3; do gate --slots 2 -- bash -c "echo start >>'$BATS_TEST_TMPDIR/log'; sleep 1; echo end >>'$BATS_TEST_TMPDIR/log'" & done
  sleep 0.5
  [ "$(holders gate)" -eq 2 ]
  wait
  [ "$(grep -c start "$BATS_TEST_TMPDIR/log")" -eq 3 ]
  [ "$(holders gate)" -eq 0 ]
}

@test "a gate passes its command's exit code through" {
  run gate -- bash -c 'exit 7'
  [ "$status" -eq 7 ]
  run gate -- true
  [ "$status" -eq 0 ]
}

@test "a slot held by a dead or reused PID is reclaimed; a live one is not" {
  mkdir -p "$ORCHESTRATE_SLOT_DIR/gate/slot-1"
  printf '999999\nMon Jan 1 00:00:00 1990\nghost\n' >"$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder"
  run gate --slots 1 --wait 2 -- true
  [ "$status" -eq 0 ]
  # PID reuse: a live PID with another start time is stale too.
  mkdir -p "$ORCHESTRATE_SLOT_DIR/gate/slot-1"
  printf '%s\nMon Jan 1 00:00:00 1990\nreused\n' "$$" >"$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder"
  run gate --slots 1 --wait 2 -- true
  [ "$status" -eq 0 ]
  # A live holder blocks until the bounded wait runs out (exit 75).
  gate --slots 1 -- sleep 3 &
  sleep 0.5
  run gate --slots 1 --wait 1 -- true
  [ "$status" -eq 75 ]
  [[ "$output" == *"no gate slot within 1s"* ]]
  wait
}

@test "Gradle and Xcode commands are routed to the heavy slot, with capped workers" {
  run gate -- bash -c 'echo "$GATE_SLOT_KIND|$GRADLE_OPTS"' ./gradlew
  [ "$output" = "heavy|-Dorg.gradle.workers.max=2" ]
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$GATE_SLOT_KIND $GRADLE_OPTS"\n' >"$BATS_TEST_TMPDIR/bin/xcodebuild"; chmod +x "$BATS_TEST_TMPDIR/bin/xcodebuild"
  HEAVY_BUILD_WORKERS=4 GRADLE_OPTS=-Xmx2g PATH="$BATS_TEST_TMPDIR/bin:$PATH" run gate -- xcodebuild test
  [ "$output" = "heavy -Xmx2g -Dorg.gradle.workers.max=4" ]
  run gate -- bash -c 'echo "$GATE_SLOT_KIND"'
  [ "$output" = gate ]
}

@test "a heavy build never overlaps a gate, in either order" {
  L="$BATS_TEST_TMPDIR/order"
  gate -- bash -c "echo gate-start >>'$L'; sleep 1; echo gate-end >>'$L'" &
  sleep 0.3
  "$SCRIPTS/heavy-build-slot.sh" -- bash -c "echo heavy-start >>'$L'; sleep 1; echo heavy-end >>'$L'" &
  sleep 0.3
  gate -- bash -c "echo gate2-start >>'$L'; echo gate2-end >>'$L'" &
  wait
  [ "$(tr '\n' ' ' <"$L")" = "gate-start gate-end heavy-start heavy-end gate2-start gate2-end " ]
}

@test "a heavy build that cannot start in time exits 75 and releases its slot" {
  gate -- sleep 2 &
  sleep 0.3
  run "$SCRIPTS/heavy-build-slot.sh" --wait 1 -- true
  [ "$status" -eq 75 ]
  [[ "$output" == *"gates still running"* ]]
  [ "$(holders heavy)" -eq 0 ]
  wait
}

@test "the per-repo gate environment is sourced before the command" {
  printf 'export BUN_JOBS=2 TEST_TIMEOUT=60\n' >"$BATS_TEST_TMPDIR/gate-env.sh"
  run gate --env-file "$BATS_TEST_TMPDIR/gate-env.sh" -- bash -c 'echo "$BUN_JOBS/$TEST_TIMEOUT"'
  [ "$output" = "2/60" ]
  # Found from the checkout's origin when not given.
  R="$BATS_TEST_TMPDIR/co"; git init -q "$R"; git -C "$R" remote add origin git@github.com:acme/widget.git
  mkdir -p "$BATS_TEST_TMPDIR/state/acme__widget"
  printf 'export BUN_JOBS=1\n' >"$BATS_TEST_TMPDIR/state/acme__widget/gate-env.sh"
  cd "$R"
  ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" run gate -- bash -c 'echo "$BUN_JOBS"'
  [ "$output" = 1 ]
}

# --- wt-cleanup ---------------------------------------------------------------------------
wt_repo() {
  O="$BATS_TEST_TMPDIR/origin.git" M="$BATS_TEST_TMPDIR/main"
  git init -q --bare "$O"
  git clone -q "$O" "$M" 2>/dev/null
  echo x >"$M/f"; git -C "$M" add f; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main
  old=$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)
}
mkwt() { # name [push]
  git -C "$M" worktree add -q -b "$1" "$BATS_TEST_TMPDIR/$1"
  echo "$1" >"$BATS_TEST_TMPDIR/$1/$1.txt"; git -C "$BATS_TEST_TMPDIR/$1" add -A; git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$1"
  [ "${2:-push}" = nopush ] || git -C "$BATS_TEST_TMPDIR/$1" push -q origin "$1"
  git -C "$M" fetch -q origin
}
age() { touch -t "$old" "$BATS_TEST_TMPDIR/$1" "$(git -C "$BATS_TEST_TMPDIR/$1" rev-parse --path-format=absolute --git-path index)"; }
verdict() { printf '%s\n' "$output" | awk -F'\t' -v p="$BATS_TEST_TMPDIR/$1" '$2 == p { print $1 "\t" $3 }'; }

@test "wt-cleanup removes only clean, idle, pushed, unprotected worktrees nobody is in" {
  wt_repo
  mkwt done;       age done
  mkwt dirty;      age dirty; echo junk >"$BATS_TEST_TMPDIR/dirty/new.txt"
  mkwt unpushed nopush; age unpushed
  mkwt recent
  mkwt busy;       age busy
  mkwt locked;     age locked; git -C "$M" worktree lock "$BATS_TEST_TMPDIR/locked"
  git -C "$M" worktree add -q -b release/1.0 "$BATS_TEST_TMPDIR/rel"; git -C "$BATS_TEST_TMPDIR/rel" push -q origin release/1.0; age rel
  (cd "$BATS_TEST_TMPDIR/busy" && exec sleep 30) & busy_pid=$!
  run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$M"
  [ "$status" -eq 0 ]
  [[ "$(verdict done)" == remove* ]]
  [[ "$(verdict dirty)" == $'keep\tuncommitted'* ]]
  [[ "$(verdict unpushed)" == $'keep\tHEAD is not on any remote branch'* ]]
  [[ "$(verdict recent)" == $'keep\ttouched 0h ago'* ]]
  [[ "$(verdict busy)" == $'keep\ta process is working inside it'* ]]
  [[ "$(verdict locked)" == $'keep\tlocked'* ]]
  [[ "$(verdict rel)" == $'keep\tprotected branch release/1.0'* ]]
  [[ "$output" == *$'keep\t'"$M"$'\tmain worktree'* ]]
  # Dry run touched nothing; --apply removes exactly the one.
  [ -d "$BATS_TEST_TMPDIR/done" ]
  run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$M" --apply
  [[ "$(verdict done)" == removed* ]]
  [ ! -d "$BATS_TEST_TMPDIR/done" ]
  for d in dirty unpushed recent busy locked rel; do [ -d "$BATS_TEST_TMPDIR/$d" ]; done
  kill "$busy_pid"   # the test's own process, by its recorded PID
}

@test "no script here kills by name or pattern" {
  ! grep -nE '\b(pkill|killall)\b|kill +-[0-9A-Z]+ +-?\$\(pgrep' "$SCRIPTS"/gate-slot.sh "$SCRIPTS"/heavy-build-slot.sh "$SCRIPTS"/wt-cleanup.sh "$SCRIPTS"/_slots.sh
  ! grep -n '\bkill\b' "$SCRIPTS"/gate-slot.sh "$SCRIPTS"/heavy-build-slot.sh "$SCRIPTS"/wt-cleanup.sh "$SCRIPTS"/_slots.sh | grep -v 'kill -0'
}
