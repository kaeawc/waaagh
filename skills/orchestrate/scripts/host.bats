#!/usr/bin/env bats
# Host-load governor: gate and heavy-build slots, and conservative worktree cleanup.
# Run: bats host.bats

setup() {
  # git prints worktree paths physically (macOS: /var/... is /private/var/...); spell them alike.
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  load test_helper
  stub_spectra   # wt-cleanup and shared-build ask spectra who works in a tree (#331)
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_SLOT_DIR="$BATS_TEST_TMPDIR/slots" SLOT_POLL=0.05 ORCHESTRATE_BUILD_ROOT="$BATS_TEST_TMPDIR/build"
  unset ORCHESTRATE_GATE_ENV ORCHESTRATE_BUILD_DIRS ORCHESTRATE_LANE_ID
}

gate() { "$SCRIPTS/gate-slot.sh" "$@"; }
holders() { find "$ORCHESTRATE_SLOT_DIR/$1" -name holder 2>/dev/null | wc -l | tr -d ' '; }
# Order is made observable through files, not sleeps (#112): a held command runs until its release
# file appears, and the test waits (bounded, 10 s) for the state it needs before the next step.
held() { echo "while [ ! -e '$BATS_TEST_TMPDIR/release-$1' ]; do sleep 0.05; done"; }
release() { touch "$BATS_TEST_TMPDIR/release-$1"; }
await() { local _; for _ in $(seq 1 200); do eval "$1" && return 0; sleep 0.05; done; echo "timed out: $1"; return 1; }

# A background child left running holds bats' fd 3 and hangs the run: a failed test still releases
# its held commands and stops the process it parked in a worktree.
teardown() {
  release a; release b
  if [[ -n "${busy_pid:-}" ]]; then kill "$busy_pid" 2>/dev/null || true; fi
}

@test "gates beyond the slot count wait, and every slot is freed afterwards" {
  for i in 1 2 3; do gate --slots 2 -- bash -c "echo start >>'$BATS_TEST_TMPDIR/log'; $(held a); echo end >>'$BATS_TEST_TMPDIR/log'" 2>"$BATS_TEST_TMPDIR/err-$i" & done
  await '[ "$(grep -c start "$BATS_TEST_TMPDIR/log" 2>/dev/null)" = 2 ]'
  # The third gate says it is waiting (it has looked at the slots and found none), not a sleep (#112).
  await 'grep -qh "^gate-slot: waiting (2/2 gates busy" "$BATS_TEST_TMPDIR"/err-*'
  [ "$(holders gate)" -eq 2 ]
  [ "$(grep -c start "$BATS_TEST_TMPDIR/log")" -eq 2 ]
  release a
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
  gate --slots 1 -- bash -c "$(held a)" &
  await '[ "$(holders gate)" = 1 ]'
  run gate --slots 1 --wait 1 -- true
  [ "$status" -eq 75 ]
  [[ "$output" == *"no gate slot within 1s"* ]]
  release a
  wait
}

@test "Gradle and Xcode commands are routed to the heavy slot, with capped workers" {
  run gate -- bash -c 'echo "$GATE_SLOT_KIND|$GRADLE_OPTS"' ./gradlew
  [ "$output" = "heavy|-Dorg.gradle.workers.max=2 -Dorg.gradle.daemon=false" ]
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$GATE_SLOT_KIND $GRADLE_OPTS"\n' >"$BATS_TEST_TMPDIR/bin/xcodebuild"; chmod +x "$BATS_TEST_TMPDIR/bin/xcodebuild"
  HEAVY_BUILD_WORKERS=4 GRADLE_OPTS=-Xmx2g PATH="$BATS_TEST_TMPDIR/bin:$PATH" run gate -- xcodebuild test
  [ "$output" = "heavy -Xmx2g -Dorg.gradle.workers.max=4 -Dorg.gradle.daemon=false" ]
  # No long-lived Gradle daemon (#318), unless the caller chose otherwise.
  HEAVY_BUILD_GRADLE_DAEMON=1 run gate -- bash -c 'echo "$GRADLE_OPTS"' ./gradlew
  [ "$output" = "-Dorg.gradle.workers.max=2" ]
  GRADLE_OPTS=-Dorg.gradle.daemon=true run gate -- bash -c 'echo "$GRADLE_OPTS"' ./gradlew
  [ "$output" = "-Dorg.gradle.daemon=true -Dorg.gradle.workers.max=2" ]
  run gate -- bash -c 'echo "$GATE_SLOT_KIND"'
  [ "$output" = gate ]
}

@test "a heavy build never overlaps a gate, in either order" {
  L="$BATS_TEST_TMPDIR/order"
  gate -- bash -c "echo gate-start >>'$L'; $(held a); echo gate-end >>'$L'" &
  await '[ -s "$L" ]'
  # The heavy build takes its slot, then waits for the running gate; a gate asked for after that
  # waits for the heavy build.
  "$SCRIPTS/heavy-build-slot.sh" -- bash -c "echo heavy-start >>'$L'; $(held b); echo heavy-end >>'$L'" &
  await '[ "$(holders heavy)" = 1 ]'
  gate -- bash -c "echo gate2-start >>'$L'; echo gate2-end >>'$L'" 2>"$BATS_TEST_TMPDIR/gate2.err" &
  # Each waits, as each says, instead of a sleep that gives them time to start (#112).
  await 'grep -q "^gate-slot: waiting" "$BATS_TEST_TMPDIR/gate2.err"'
  [ "$(cat "$L")" = gate-start ]
  release a
  await 'grep -q heavy-start "$L"'
  [ "$(tr '\n' ' ' <"$L")" = "gate-start gate-end heavy-start " ]   # gate2 still waits for the heavy build
  release b
  wait
  [ "$(tr '\n' ' ' <"$L")" = "gate-start gate-end heavy-start heavy-end gate2-start gate2-end " ]
}

@test "a heavy build that cannot start in time exits 75 and releases its slot" {
  gate -- bash -c "$(held a)" &
  await '[ "$(holders gate)" = 1 ]'
  run "$SCRIPTS/heavy-build-slot.sh" --wait 0 -- true   # one look, then exit 75: no need to wait a second (#112)
  [ "$status" -eq 75 ]
  [[ "$output" == *"gates still running"* ]]
  [ "$(holders heavy)" -eq 0 ]
  release a
  wait
}

@test "a nested wrap runs inside the slot its ancestor holds instead of waiting on it (#313)" {
  H="$SCRIPTS/heavy-build-slot.sh" G="$SCRIPTS/gate-slot.sh"
  # The incident: heavy-build-slot.sh wrapping itself. The inner one keeps the outer's worker cap.
  run "$H" -- "$H" --wait 1 --workers 9 -- bash -c 'echo "ran $GATE_SLOT_KIND|$GRADLE_OPTS"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran heavy|-Dorg.gradle.workers.max=2"* && "$output" == *"already inside a heavy slot"* ]]
  # A gate that wraps its own Gradle step, and a gate inside a heavy build or inside the only gate slot.
  run "$H" -- "$G" --wait 1 -- bash -c 'echo "routed $GATE_SLOT_KIND"' ./gradlew
  [ "$status" -eq 0 ]
  [[ "$output" == *"routed heavy"* ]]
  run "$H" -- "$G" --wait 1 -- bash -c 'echo "ran $GATE_SLOT_KIND"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran heavy"* ]]
  run "$G" --slots 1 -- "$G" --slots 1 --wait 1 -- bash -c 'echo "ran $GATE_SLOT_KIND"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran gate"* && "$output" == *"already inside a gate slot"* ]]
  [ "$(holders gate)" -eq 0 ]
  [ "$(holders heavy)" -eq 0 ]
}

@test "a heavy build inside a gate parks that gate; two such gates do not deadlock or overlap (#313)" {
  H="$SCRIPTS/heavy-build-slot.sh" G="$SCRIPTS/gate-slot.sh" L="$BATS_TEST_TMPDIR/order"
  run "$G" -- "$H" --wait 2 -- bash -c 'echo "ran $GATE_SLOT_KIND"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran heavy"* ]]
  for i in 1 2; do
    "$G" -- "$H" --wait 20 -- bash -c "echo start >>'$L'; sleep 0.3; echo end >>'$L'" &
  done
  wait
  [ "$(tr '\n' ' ' <"$L")" = "start end start end " ]
  # A gate that is not parked still holds a nested heavy build back.
  "$G" -- bash -c "$(held a)" &
  await '[ "$(holders gate)" = 1 ]'
  run "$G" -- "$H" --wait 0 -- true
  [ "$status" -eq 75 ]
  [[ "$output" == *"gates still running"* ]]
  release a
  wait
  [ "$(holders gate)" -eq 0 ]
  [ "$(holders heavy)" -eq 0 ]
  [ -z "$(find "$ORCHESTRATE_SLOT_DIR" -name parked)" ]
}

@test "a slot marker that is no longer true is ignored (#313)" {
  gate --slots 1 -- bash -c "$(held a)" &
  await '[ "$(holders gate)" = 1 ]'
  slot="$ORCHESTRATE_SLOT_DIR/gate/slot-1"
  # Another process's slot (the PID does not match), a slot outside this pool root, and no PID.
  # --wait 0: one look at the slots, then exit 75, the same refusal without the second's wait (#112).
  ORCHESTRATE_SLOT_HELD="$slot" ORCHESTRATE_SLOT_HOLDER=$$ run gate --slots 1 --wait 0 -- true
  [ "$status" -eq 75 ]
  ORCHESTRATE_SLOT_HELD="$slot" run gate --slots 1 --wait 0 -- true
  [ "$status" -eq 75 ]
  mkdir -p "$BATS_TEST_TMPDIR/other/gate/slot-1"
  cp "$slot/holder" "$BATS_TEST_TMPDIR/other/gate/slot-1/holder"
  ORCHESTRATE_SLOT_HELD="$BATS_TEST_TMPDIR/other/gate/slot-1" ORCHESTRATE_SLOT_HOLDER=$(sed -n 1p "$slot/holder") run gate --slots 1 --wait 0 -- true
  [ "$status" -eq 75 ]
  release a
  wait
  # A marker left by a wrapper that has exited: its slot is gone, so a slot is taken as usual.
  ORCHESTRATE_SLOT_HELD="$slot" ORCHESTRATE_SLOT_HOLDER=999999 run gate --slots 1 -- bash -c 'echo "$ORCHESTRATE_SLOT_HOLDER"'
  [ "$status" -eq 0 ]
  [ "$output" != 999999 ]
}

@test "a failed Gradle build names a Gradle or Kotlin daemon whose JDK is gone (#335)" {
  stub_spectra
  H="$SCRIPTS/heavy-build-slot.sh"
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  printf '#!/bin/sh\necho "A problem occurred starting process command /x/bin/jlink" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/proj/gradlew"
  chmod +x "$BATS_TEST_TMPDIR/proj/gradlew"
  jq -n '[{pid: 4242, main_class: "org.gradle.launcher.daemon.bootstrap.GradleDaemon", java_home: "/opt/homebrew/Cellar/openjdk@21/21.0.5/libexec", java_home_missing: true},
          {pid: 4343, main_class: "org.jetbrains.kotlin.daemon.KotlinCompileDaemon", java_home: "/x", executable_deleted: true},
          {pid: 4444, main_class: "org.gradle.launcher.daemon.bootstrap.GradleDaemon", java_home: "/ok"},
          {pid: 4545, main_class: "com.example.App", java_home: "/gone", java_home_missing: true}]' >"$BATS_TEST_TMPDIR/spectra-jvm.json"
  run "$H" -- "$BATS_TEST_TMPDIR/proj/gradlew" assembleDebug
  [ "$status" -eq 1 ]
  [[ "$output" == *"Gradle daemon 4242 runs on a JDK that is gone (java.home /opt/homebrew/Cellar/openjdk@21/21.0.5/libexec)"*"stop PID 4242; never gradle --stop"* ]]
  [[ "$output" == *"Kotlin daemon 4343 runs on a JDK that is gone (java.home /x, executable deleted)"* ]]
  [[ "$output" != *4444* && "$output" != *4545* ]]
  [ "$(holders heavy)" -eq 0 ]
  # Only after a failed Gradle command: a passing one, or a failing non-Gradle one, asks nothing.
  : >"$BATS_TEST_TMPDIR/spectra-calls"
  run "$H" -- bash -c 'exit 1'
  [ "$status" -eq 1 ]
  run "$H" -- true ./gradlew
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/spectra-calls" ]
  # No spectra: the build's own exit code still wins, with one line saying the check could not run.
  SPECTRA="$BATS_TEST_TMPDIR/none" run "$H" -- "$BATS_TEST_TMPDIR/proj/gradlew"
  [ "$status" -eq 1 ]
  [[ "$output" == *"spectra unavailable; could not check for a Gradle or Kotlin daemon on a missing JDK"* ]]
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
  run ! grep -nE '\b(pkill|killall)\b|kill +-[0-9A-Z]+ +-?\$\(pgrep' "$SCRIPTS"/gate-slot.sh "$SCRIPTS"/heavy-build-slot.sh "$SCRIPTS"/wt-cleanup.sh "$SCRIPTS"/_slots.sh
  ! grep -n '\bkill\b' "$SCRIPTS"/gate-slot.sh "$SCRIPTS"/heavy-build-slot.sh "$SCRIPTS"/wt-cleanup.sh "$SCRIPTS"/_slots.sh | grep -v 'kill -0'
}
