#!/usr/bin/env bats
# Lane-private build output (#213): gate-slot.sh and heavy-build-slot.sh give every lane its own
# build output directory (Xcode derived data, Gradle project cache, TMPDIR, XDG cache) from a
# configurable table, and wt-cleanup.sh removes a lane's dir once its worktree is gone. Tools are
# stubs that print their arguments and environment; no real Gradle or Xcode runs.
# Run: bats lane-build-dirs.bats

setup() {
  load test_helper
  stub_spectra   # wt-cleanup and shared-build ask spectra who works in a tree (#331)
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR BIN="$BATS_TEST_TMPDIR/bin"
  export ORCHESTRATE_SLOT_DIR="$T/slots" SLOT_POLL=0.05 ORCHESTRATE_BUILD_ROOT="$T/build" \
    ORCHESTRATE_STATE_DIR="$T/state" TMPDIR="$T/shared-tmp" XDG_CACHE_HOME="$T/shared-cache"
  unset ORCHESTRATE_GATE_ENV ORCHESTRATE_BUILD_DIRS ORCHESTRATE_LANE_ID ORCHESTRATE_LANE_BUILD_DIR \
    SCAN_DERIVED_DATA_PATH GYM_DERIVED_DATA_PATH
  mkdir -p "$BIN" "$T/shared-tmp"
  local tool
  for tool in xcodebuild gradlew gradle fastlane probe; do
    printf '%s\n' '#!/usr/bin/env bash' \
      'printf "arg=%s\n" "$@"' \
      'for v in ORCHESTRATE_LANE_BUILD_DIR ORCHESTRATE_LANE_BUILD_ID TMPDIR XDG_CACHE_HOME SCAN_DERIVED_DATA_PATH GYM_DERIVED_DATA_PATH GATE_SLOT_KIND EXTRA; do' \
      '  printf "%s=%s\n" "$v" "${!v:-}"' \
      'done' >"$BIN/$tool"
    chmod +x "$BIN/$tool"
  done
  export PATH="$BIN:$PATH"
}

teardown() {
  if [[ -n "${busy_pid:-}" ]]; then kill "$busy_pid" 2>/dev/null || true; fi
}

gate() { "$SCRIPTS/gate-slot.sh" "$@"; }
# lane NAME: a checkout at $T/NAME (resolved), entered.
lane() { git init -q "$T/$1"; cd "$T/$1"; L=$(pwd -P); }
val() { printf '%s\n' "$output" | awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'; }
args() { printf '%s\n' "$output" | sed -n 's/^arg=//p' | tr '\n' ' '; }

@test "each lane's gate gets its own build dir, TMPDIR and XDG cache, marked with its worktree" {
  lane a
  run gate -- probe
  [ "$status" -eq 0 ]
  A=$(val ORCHESTRATE_LANE_BUILD_DIR)
  [[ "$A" == "$T/build/a-"* ]]
  [ "$(val TMPDIR)" = "$A/tmp" ]
  [ "$(val XDG_CACHE_HOME)" = "$A/xdg-cache" ]
  [ "$(val ORCHESTRATE_LANE_BUILD_ID)" = "${A##*/}" ]
  [ "$(val GATE_SLOT_KIND)" = gate ]
  [ -d "$A/tmp" ]
  [ -d "$A/xdg-cache" ]
  [ "$(cat "$A/.worktree")" = "$L" ]
  # A subdirectory of the same worktree is the same lane; another worktree is another lane.
  mkdir -p sub; cd sub
  run gate -- probe
  [ "$(val ORCHESTRATE_LANE_BUILD_DIR)" = "$A" ]
  lane b
  run gate -- probe
  B=$(val ORCHESTRATE_LANE_BUILD_DIR)
  [[ "$B" == "$T/build/b-"* ]]
  [ "$B" != "$A" ]
  [ "$(val TMPDIR)" = "$B/tmp" ]
  # Two worktrees with the same basename still differ (the id carries a checksum of the path).
  mkdir -p "$T/other"; git init -q "$T/other/a"; cd "$T/other/a"
  run gate -- probe
  [[ "$(val ORCHESTRATE_LANE_BUILD_DIR)" == "$T/build/a-"* ]]
  [ "$(val ORCHESTRATE_LANE_BUILD_DIR)" != "$A" ]
}

@test "xcodebuild gets a lane-private -derivedDataPath in the heavy slot; an explicit one is kept" {
  lane a
  run gate -- xcodebuild -scheme App test
  [ "$status" -eq 0 ]
  A=$(val ORCHESTRATE_LANE_BUILD_DIR)
  [ "$(val GATE_SLOT_KIND)" = heavy ]
  [ "$(args)" = "-derivedDataPath $A/xcode/DerivedData -scheme App test " ]
  [ -d "$A/xcode/DerivedData" ]
  lane b
  run gate -- env EXTRA=1 xcodebuild test
  B=$(val ORCHESTRATE_LANE_BUILD_DIR)
  [ "$(args)" = "-derivedDataPath $B/xcode/DerivedData test " ]
  [ "$(val EXTRA)" = 1 ]
  run --separate-stderr gate -- xcodebuild -derivedDataPath /tmp/mine test
  [ "$status" -eq 0 ]
  [ "$(args)" = "-derivedDataPath /tmp/mine test " ]
  [[ "$stderr" == *"-derivedDataPath given on the command line"* ]]
}

@test "gradle gets a lane-private --project-cache-dir; --project-cache-dir=... is kept" {
  lane a
  cp "$BIN/gradlew" ./gradlew
  run gate -- ./gradlew assemble
  A=$(val ORCHESTRATE_LANE_BUILD_DIR)
  [ "$(args)" = "--project-cache-dir $A/gradle/project-cache assemble " ]
  run --separate-stderr gate -- gradle --project-cache-dir=/x build
  [ "$(args)" = "--project-cache-dir=/x build " ]
  [[ "$stderr" == *"--project-cache-dir given on the command line"* ]]
}

@test "fastlane gets derived-data env; a tool inside a bash -c string gets env rows, not args" {
  lane a
  run gate -- fastlane scan
  A=$(val ORCHESTRATE_LANE_BUILD_DIR)
  [ "$(val SCAN_DERIVED_DATA_PATH)" = "$A/xcode/DerivedData" ]
  [ "$(val GYM_DERIVED_DATA_PATH)" = "$A/xcode/DerivedData" ]
  run gate -- bash -c 'xcodebuild test'
  [ "$(args)" = "test " ]
  [ "$(val TMPDIR)" = "$A/tmp" ]
  # A gate that names no tool gets no tool rows.
  run gate -- probe
  [ -z "$(val SCAN_DERIVED_DATA_PATH)" ]
}

@test "a repo's table replaces the defaults; ORCHESTRATE_BUILD_DIRS names one or turns it off" {
  lane a
  git remote add origin git@github.com:acme/widget.git
  mkdir -p "$T/state/acme__widget"
  printf '# repo table\n\nprobe\targ\t--out\t{dir}/out\n*\tenv\tEXTRA\t{id}@{worktree}\n' >"$T/state/acme__widget/build-dirs.tsv"
  run gate -- probe x
  A=$(val ORCHESTRATE_LANE_BUILD_DIR)
  [ "$(args)" = "--out $A/out x " ]
  [ "$(val EXTRA)" = "${A##*/}@$L" ]
  [ "$(val TMPDIR)" = "$T/shared-tmp" ]
  [ -d "$A/out" ]
  # An explicit table wins over the repo's; bad rows are noted and skipped.
  printf '*\tenv\tbad-name\tx\n*\tlink\tX\ty\n*\tenv\tEXTRA\tset\n' >"$T/t.tsv"
  ORCHESTRATE_BUILD_DIRS="$T/t.tsv" run --separate-stderr gate -- probe
  [ "$(val EXTRA)" = set ]
  [[ "$stderr" == *"bad env name 'bad-name'"* ]]
  [[ "$stderr" == *"unknown kind 'link'"* ]]
  ORCHESTRATE_BUILD_DIRS="$T/missing.tsv" run --separate-stderr gate -- probe
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not readable"* ]]
  [ -z "$(val ORCHESTRATE_LANE_BUILD_DIR)" ]
  # Off: the command runs as given, with the inherited environment.
  ORCHESTRATE_BUILD_DIRS=off run gate -- xcodebuild test
  [ "$(args)" = "test " ]
  [ "$(val TMPDIR)" = "$T/shared-tmp" ]
  [ -z "$(val ORCHESTRATE_LANE_BUILD_DIR)" ]
}

@test "ORCHESTRATE_LANE_ID names the lane dir; the gate environment can override the build env" {
  lane a
  ORCHESTRATE_LANE_ID='lane 7/x' run gate -- probe
  [ "$(val ORCHESTRATE_LANE_BUILD_DIR)" = "$T/build/lane_7_x" ]
  printf 'export XDG_CACHE_HOME=%s/shared-cache\n' "$T" >"$T/gate-env.sh"
  run gate --env-file "$T/gate-env.sh" -- probe
  [ "$(val XDG_CACHE_HOME)" = "$T/shared-cache" ]
  [[ "$(val TMPDIR)" == "$T/build/a-"*/tmp ]]
  # Through the heavy slot with an env file too.
  run "$SCRIPTS/heavy-build-slot.sh" --env-file "$T/gate-env.sh" -- xcodebuild test
  [ "$(val XDG_CACHE_HOME)" = "$T/shared-cache" ]
  [[ "$(args)" == "-derivedDataPath $T/build/a-"*"/xcode/DerivedData test " ]]
}

@test "a build root that cannot be created leaves the command as given" {
  lane a
  : >"$T/file"
  ORCHESTRATE_BUILD_ROOT="$T/file/build" run --separate-stderr gate -- xcodebuild test
  [ "$status" -eq 0 ]
  [ "$(args)" = "test " ]
  [[ "$stderr" == *"cannot create"* ]]
}

@test "wt-cleanup removes lane build dirs whose worktree is gone, and only those" {
  lane main
  mkdir -p "$T/build/gone" "$T/build/live" "$T/build/busy" "$T/build/unmarked" "$T/build/relative"
  echo "$T/no-such-worktree" >"$T/build/gone/.worktree"
  echo "$L" >"$T/build/live/.worktree"
  echo "$T/also-gone" >"$T/build/busy/.worktree"
  echo "relative/path" >"$T/build/relative/.worktree"
  (cd "$T/build/busy" && exec sleep 30) & busy_pid=$!
  run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$L"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'build\t'"$T/build/gone"$'\tremovable: worktree '"$T/no-such-worktree"' is gone'* ]]
  [[ "$output" == *$'build\t'"$T/build/busy"$'\tkeep: a process is working inside it'* ]]
  [ -d "$T/build/gone" ]
  run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$L" --apply
  [[ "$output" == *$'build\t'"$T/build/gone"$'\tremoved: worktree'* ]]
  [ ! -e "$T/build/gone" ]
  for d in live busy unmarked relative; do [ -d "$T/build/$d" ]; done
  [ "$(printf '%s\n' "$output" | grep -c -e "/build/live" -e "/build/unmarked" -e "/build/relative" || true)" -eq 0 ]
  kill "$busy_pid"
}

@test "removing a finished worktree also removes the build dir its gates used" {
  T=$(cd "$T" && pwd -P)   # wt-cleanup prints git's worktree path, which is physical (macOS /private/var)
  O="$T/origin.git" M="$T/main"
  git init -q --bare "$O"
  git clone -q "$O" "$M" 2>/dev/null
  echo x >"$M/f"; git -C "$M" add f; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main
  git -C "$M" worktree add -q -b done "$T/done"
  git -C "$T/done" push -q origin done
  git -C "$M" fetch -q origin
  cd "$T/done"
  run gate -- xcodebuild test
  D=$(val ORCHESTRATE_LANE_BUILD_DIR)
  [ -d "$D/xcode/DerivedData" ]
  cd "$T"
  run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$M" --older-than-hours 0 --apply
  [[ "$output" == *$'removed\t'"$T/done"* ]]
  [[ "$output" == *$'build\t'"$D"$'\tremoved: worktree'* ]]
  [ ! -e "$D" ]
}
