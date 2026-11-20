#!/usr/bin/env bats
# Shared builds per commit (#215): verification and device lanes on one tree fingerprint build once
# (shared-build.sh); the first lane builds under a lock and marks the build complete, the others
# reuse it read-only or as a copy, a failed build leaves no marker, and old shared builds are pruned
# to a cap (also through wt-cleanup.sh's build rows). The build tool is a stub that counts its runs;
# waits run on a fake clock.
# Run: bats shared-build.bats

setup() {
  load test_helper
  stub_spectra   # wt-cleanup and shared-build ask spectra who works in a tree (#331)
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR BIN="$BATS_TEST_TMPDIR/bin"
  export ORCHESTRATE_BUILD_ROOT="$T/build" ORCHESTRATE_STATE_DIR="$T/state" ORCHESTRATE_NOW=1000 \
    SHARED_BUILD_POLL=10 SHARED_BUILD_SLEEP=0.01 COUNT="$T/count"
  unset ORCHESTRATE_LANE_CLASS ORCHESTRATE_BUILD_SHARE ORCHESTRATE_LANE_ID ORCHESTRATE_SHARED_WAIT \
    ORCHESTRATE_SHARED_BUILD_KEEP ORCHESTRATE_SHARED_BUILD_MAX_MB ORCHESTRATE_SHARED_BUILD_MAX_AGE GO FAIL
  mkdir -p "$BIN"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo run >>"$COUNT"' \
    'if [[ -n "${GO:-}" ]]; then touch "$GO.started"; for _ in $(seq 1 200); do [[ -e "$GO" ]] && break; sleep 0.05; done; fi' \
    '[[ "${FAIL:-}" != 1 ]] || { mkdir -p out; echo half >out/app.apk; exit 3; }' \
    'mkdir -p out/sub; echo "apk $(git rev-parse HEAD)" >out/app.apk; echo lib >out/sub/lib.so' \
    'if [[ -n "${ORCHESTRATE_SHARED_BUILD_OUT:-}" ]]; then echo direct >"$ORCHESTRATE_SHARED_BUILD_OUT/direct.txt"; fi' \
    'echo built' >"$BIN/mkapk"
  chmod +x "$BIN/mkapk"
  export PATH="$BIN:$PATH"
  S="$T/src"
  git init -q "$S"
  printf 'out/\n' >"$S/.gitignore"
  echo one >"$S/f"
  git -C "$S" add -A
  git -C "$S" commit -qm one
  git -C "$S" worktree add -q --detach "$T/a"
  git -C "$S" worktree add -q --detach "$T/b"
}

teardown() {
  if [[ -n "${hold_pid:-}" ]]; then kill "$hold_pid" 2>/dev/null || true; fi
  chmod -R u+w "$T/build" 2>/dev/null || true
}

sb() { "$SCRIPTS/shared-build.sh" "$@"; }
runs() { if [[ -f "$COUNT" ]]; then wc -l <"$COUNT" | tr -d ' '; else echo 0; fi; }
row() { printf '%s\n' "$output" | awk -F'\t' '$1 == "shared-build"' | tail -n 1; }
fp() { "$SCRIPTS/fingerprint.sh" --dir "$1" --fingerprint-only; }

@test "two verify lanes on one commit build once; the second reuses the read-only artifacts" {
  run sb --class verify --name apk --dir "$T/a" --artifact out/app.apk --artifact out/sub -- mkapk
  [ "$status" -eq 0 ]
  [[ "$output" == *built* ]]
  D="$T/build/shared/$(fp "$T/a")--apk"
  [ "$(row)" = "$(printf 'shared-build\tbuilt\t%s' "$D")" ]
  [ "$(cat "$D/out/app.apk")" = "apk $(git -C "$S" rev-parse HEAD)" ]
  [ "$(cat "$D/out/sub/lib.so")" = lib ]
  [ "$(cat "$D/direct.txt")" = direct ]
  [[ "$(cat "$D/.done")" == *$'fingerprint\t'"$(fp "$T/a")"* ]]
  [[ "$(cat "$D/.done")" == *$'lane\ta'* ]]
  [ -z "$(find "$D" -mindepth 1 -perm -u=w ! -name .used)" ]
  [ "$(runs)" = 1 ]
  # Lane b, same commit, another worktree: no build, the same directory.
  ORCHESTRATE_NOW=1500 ORCHESTRATE_LANE_CLASS=device run sb --name apk --dir "$T/b" --artifact out/app.apk -- mkapk
  [ "$status" -eq 0 ]
  [ "$(row)" = "$(printf 'shared-build\treused\t%s' "$D")" ]
  [ "$(runs)" = 1 ]
  [ ! -e "$T/b/out" ]
  [ "$(cat "$D/.used")" = 1500 ]
  # --copy: a writable copy without the markers.
  run sb --class device --name apk --dir "$T/b" --copy "$T/b/prebuilt" -- mkapk
  [ "$(row)" = "$(printf 'shared-build\treused\t%s' "$(cd "$T/b/prebuilt" && pwd -P)")" ]
  [ "$(cat "$T/b/prebuilt/out/app.apk")" = "apk $(git -C "$S" rev-parse HEAD)" ]
  [ ! -e "$T/b/prebuilt/.done" ]
  [ -z "$(find "$T/b/prebuilt" ! -perm -u=w)" ]
  [ "$(runs)" = 1 ]
}

@test "another commit, another name, or a dirty tree is another build" {
  run sb --class verify --name apk --dir "$T/a" -- mkapk
  [ "$(runs)" = 1 ]
  run sb --class verify --name ios-runner --dir "$T/b" -- mkapk
  [[ "$(row)" == *$'\tbuilt\t'*--ios-runner ]]
  [ "$(runs)" = 2 ]
  echo two >"$T/b/f"
  run sb --class verify --name apk --dir "$T/b" -- mkapk
  [[ "$(row)" == *$'\tbuilt\t'* ]]
  [ "$(runs)" = 3 ]
  git -C "$T/b" commit -qam two
  run sb --class verify --name apk --dir "$T/b" -- mkapk
  [[ "$(row)" == *$'\tbuilt\t'* ]]
  [ "$(runs)" = 4 ]
  # Without --name the key is a hash of the command and artifacts: the same command shares.
  run sb --class verify --dir "$T/a" -- mkapk
  [[ "$(row)" == *$'\tbuilt\t'* ]]
  run sb --class verify --dir "$T/a" -- mkapk
  [[ "$(row)" == *$'\treused\t'* ]]
  [ "$(runs)" = 5 ]
}

@test "implementation lanes and ORCHESTRATE_BUILD_SHARE=off build privately, every time" {
  run sb --name apk --dir "$T/a" --artifact out/app.apk -- mkapk
  [ "$status" -eq 0 ]
  P=$(row | cut -f3)
  [[ "$(row)" == $'shared-build\tprivate\t'"$T/build/a-"*/artifacts/apk ]]
  [ "$(cat "$P/out/app.apk")" = "apk $(git -C "$S" rev-parse HEAD)" ]
  [ "$(cat "$P/direct.txt")" = direct ]
  run sb --name apk --dir "$T/a" --artifact out/app.apk -- mkapk
  [ "$(runs)" = 2 ]
  ORCHESTRATE_BUILD_SHARE=off run sb --class verify --name apk --dir "$T/b" -- mkapk
  [[ "$(row)" == *$'\tprivate\t'* ]]
  ORCHESTRATE_BUILD_SHARE="impl,device" run sb --class impl --name apk --dir "$T/b" -- mkapk
  [[ "$(row)" == *$'\tbuilt\t'* ]]
  [ "$(runs)" = 4 ]
  [ -d "$T/build/shared/$(fp "$T/a")--apk" ]
  # Not a checkout: no fingerprint, so a verify lane builds privately and says so.
  mkdir "$T/plain"
  run --separate-stderr sb --class verify --name apk --dir "$T/plain" -- true
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no tree fingerprint"* ]]
  [[ "$output" == *$'\tprivate\t'* ]]
  # A failing private build passes its exit code through.
  FAIL=1 run sb --name apk --dir "$T/a" -- mkapk
  [ "$status" -eq 3 ]
}

@test "a failed or partial build leaves no marker, and the next lane rebuilds" {
  FAIL=1 run --separate-stderr sb --class verify --name apk --dir "$T/a" --artifact out/app.apk -- mkapk
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"no completion marker, the next lane rebuilds"* ]]
  [ -z "$(ls -A "$T/build/shared")" ]
  # CMD succeeds but an artifact is missing: exit 1, still no marker.
  run --separate-stderr sb --class verify --name apk --dir "$T/b" --artifact out/missing.apk -- mkapk
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--artifact out/missing.apk is missing"* ]]
  [ -z "$(ls -A "$T/build/shared")" ]
  run sb --class verify --name apk --dir "$T/b" --status
  [ "$status" -eq 1 ]
  [[ "$output" == $'shared-build\tmissing\t'* ]]
  run sb --class verify --name apk --dir "$T/b" --artifact out/app.apk -- mkapk
  [ "$status" -eq 0 ]
  [[ "$(row)" == *$'\tbuilt\t'* ]]
  [ "$(runs)" = 3 ]
  run sb --class verify --name apk --dir "$T/a" --status
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'shared-build\tready\t%s' "$T/build/shared/$(fp "$T/a")--apk")" ]
  run sb --name apk --dir "$T/a" --status
  [ "$status" -eq 1 ]
  [[ "$output" == $'shared-build\tprivate\t'* ]]
  # A finished-looking dir with no marker (left by hand) is rebuilt over.
  D="$T/build/shared/$(fp "$T/a")--other"
  mkdir -p "$D"; echo stale >"$D/junk"; chmod a-w "$D/junk"
  run sb --class verify --name other --dir "$T/a" -- mkapk
  [[ "$(row)" == *$'\tbuilt\t'* ]]
  [ ! -e "$D/junk" ]
}

@test "a lane waits for another lane's build of the same commit and then reuses it" {
  export GO="$T/go"
  sb --class verify --name apk --dir "$T/a" --artifact out/app.apk -- mkapk >"$T/a.out" 2>&1 &
  a_pid=$!
  for _ in $(seq 1 200); do [[ -e "$GO.started" ]] && break; sleep 0.05; done
  [ -e "$GO.started" ]
  unset GO
  SHARED_BUILD_POLL=1 SHARED_BUILD_SLEEP=0.05 sb --class verify --name apk --dir "$T/b" -- mkapk >"$T/b.out" 2>"$T/b.err" &
  b_pid=$!
  for _ in $(seq 1 200); do [[ -s "$T/b.err" ]] && break; sleep 0.05; done
  [[ "$(cat "$T/b.err")" == *"waiting for a to finish building"* ]]
  touch "$T/go"
  wait "$a_pid"
  wait "$b_pid"
  [[ "$(cat "$T/a.out")" == *$'\tbuilt\t'* ]]
  [[ "$(cat "$T/b.out")" == *$'\treused\t'* ]]
  [ "$(runs)" = 1 ]
}

@test "the wait is bounded on the fake clock; a dead or overdue lock holder is broken" {
  F=$(fp "$T/a")
  mkdir -p "$T/build/shared/$F--apk.lock"
  sleep 300 & hold_pid=$!
  printf '%s\n1000\nlane-x\n' "$hold_pid" >"$T/build/shared/$F--apk.lock/owner"
  run --separate-stderr sb --class verify --name apk --dir "$T/a" --wait 30 -- mkapk
  [ "$status" -eq 75 ]
  [[ "$stderr" == *"still being built by lane-x after 30s"* ]]
  [ "$(runs)" = 0 ]
  # The same live holder, but past the build age limit on the fake clock: broken, and built.
  ORCHESTRATE_NOW=9000 run --separate-stderr sb --class verify --name apk --dir "$T/a" -- mkapk
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"breaking the stale build lock"* ]]
  [ "$(runs)" = 1 ]
  [ ! -e "$T/build/shared/$F--apk.lock" ]
  # A holder whose PID is gone: broken at once.
  sleep 0 & dead=$!
  wait "$dead"
  mkdir -p "$T/build/shared/$F--two.lock"
  printf '%s\n1000\nlane-y\n' "$dead" >"$T/build/shared/$F--two.lock/owner"
  run sb --class verify --name two --dir "$T/a" --wait 0 -- mkapk
  [ "$status" -eq 0 ]
  [[ "$(row)" == *$'\tbuilt\t'* ]]
  # A held lock does not hold up a lane whose build is already complete.
  mkdir -p "$T/build/shared/$F--two.lock"
  printf '%s\n1000\nlane-z\n' "$hold_pid" >"$T/build/shared/$F--two.lock/owner"
  run sb --class verify --name two --dir "$T/b" --wait 0 -- mkapk
  [[ "$(row)" == *$'\treused\t'* ]]
  [ "$(runs)" = 2 ]
}

@test "shared builds are pruned to the keep count and size cap; partial builds go too" {
  export ORCHESTRATE_SHARED_BUILD_KEEP=2
  for n in one two three; do
    ORCHESTRATE_NOW=$((1000 + ${#n})) run sb --class verify --name "$n" --dir "$T/a" -- mkapk
    [ "$status" -eq 0 ]
  done
  F=$(fp "$T/a") R="$T/build/shared"
  # one (1003), two (1003), three (1005): "two" sorts above "one" on a tie, so one goes.
  [ ! -e "$R/$F--one" ]
  [ -d "$R/$F--two" ]
  [ -d "$R/$F--three" ]
  # A staging dir of a dead builder, a marker-less dir, a live builder's staging dir and a lock.
  sleep 0 & dead=$!
  wait "$dead"
  sleep 300 & hold_pid=$!
  mkdir -p "$R/$F--x.tmp-$dead" "$R/$F--nomark" "$R/$F--y.tmp-$hold_pid" "$R/$F--z.lock"
  run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'build\t'"$R/$F--x.tmp-$dead"$'\tremovable: partial shared build, builder '"$dead is gone"* ]]
  [[ "$output" == *$'build\t'"$R/$F--nomark"$'\tremovable: shared build with no completion marker'* ]]
  [ "$(printf '%s\n' "$output" | grep -c -e "--y.tmp" -e "--z.lock" -e "--two" -e "--three" || true)" -eq 0 ]
  # A size cap of 0 MB keeps only the newest; a process inside a build keeps it.
  (cd "$R/$F--two" && exec sleep 300) & busy=$!
  ORCHESTRATE_SHARED_BUILD_MAX_MB=0 run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$S" --apply
  kill "$busy"
  [[ "$output" == *$'build\t'"$R/$F--x.tmp-$dead"$'\tremoved: '* ]]
  [[ "$output" == *$'build\t'"$R/$F--nomark"$'\tremoved: '* ]]
  [[ "$output" == *$'build\t'"$R/$F--two"$'\tkeep: a process is working inside it'* ]]
  [ ! -e "$R/$F--x.tmp-$dead" ]
  [ ! -e "$R/$F--nomark" ]
  [ -d "$R/$F--two" ]
  [ -d "$R/$F--three" ]
  [ -d "$R/$F--y.tmp-$hold_pid" ]
  [ -d "$R/$F--z.lock" ]
  ORCHESTRATE_SHARED_BUILD_MAX_MB=0 run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$S" --apply
  [[ "$output" == *$'build\t'"$R/$F--two"$'\tremoved: shared build over the cap (2 builds, 0 MB'* ]]
  [ ! -e "$R/$F--two" ]
  [ -d "$R/$F--three" ]
}

@test "usage errors exit 2 before building" {
  run sb --class verify --artifact /abs -- mkapk
  [ "$status" -eq 2 ]
  run sb --class verify --artifact ../up -- mkapk
  [ "$status" -eq 2 ]
  run sb --wait soon -- mkapk
  [ "$status" -eq 2 ]
  run sb --status
  [ "$status" -eq 2 ]
  run sb --class verify
  [ "$status" -eq 2 ]
  run sb --name
  [ "$status" -eq 2 ]
  run sb --dir "$T/none" -- mkapk
  [ "$status" -eq 2 ]
  [ "$(runs)" = 0 ]
}
