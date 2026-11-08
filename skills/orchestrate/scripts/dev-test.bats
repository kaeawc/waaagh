#!/usr/bin/env bats
# dev/test.sh, the parallel suite runner: --ignore-sigpipe reproduces CI's runner, a failing suite
# fails the run and shows its output.

setup() {
  load test_helper
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  P="$BATS_TEST_TMPDIR/probe"
  mkdir -p "$P"
}

# A suite whose one test passes only when SIGPIPE (signal 13, mask bit 0x1000) is ignored.
sigpipe_probe() {
  cat >"$P/sigpipe.bats" <<'PROBE'
@test "SIGPIPE is ignored in this test process" {
  mask=$(awk '/^SigIgn:/ { print $2 }' /proc/self/status)
  (( (16#$mask & 0x1000) != 0 ))
}
PROBE
}

@test "--ignore-sigpipe runs every suite with SIGPIPE ignored, and says so" {
  [ -r /proc/self/status ] || skip "no /proc to read the signal mask from"
  sigpipe_probe
  run "$ROOT/dev/test.sh" -j 1 --ignore-sigpipe "$P/sigpipe.bats"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"1/1 tests passed"*"SIGPIPE ignored"* ]]
}

@test "a failing suite fails the run, and its output is printed" {
  printf '@test "fails on purpose" {\n  false\n}\n' >"$P/bad.bats"
  printf '@test "passes" {\n  true\n}\n' >"$P/good.bats"
  run "$ROOT/dev/test.sh" -j 2 "$P/bad.bats" "$P/good.bats"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"bad.bats"* ]]
  [[ "$output" == *"not ok 1 fails on purpose"* ]]
  [[ "$output" == *"1/2 tests passed"* ]]
  [[ "$output" != *"SIGPIPE ignored"* ]]
}

@test "unknown options and missing suites are usage errors" {
  run "$ROOT/dev/test.sh" --no-such-option
  [ "$status" -eq 2 ]
  run "$ROOT/dev/test.sh" "$P/missing.bats"
  [ "$status" -eq 2 ]
  run "$ROOT/dev/test.sh" -j 0
  [ "$status" -eq 2 ]
}
