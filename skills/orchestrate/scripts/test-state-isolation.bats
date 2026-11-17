#!/usr/bin/env bats
# test_helper.bash points ORCHESTRATE_STATE_DIR at a per-test directory, so no suite reads the
# user's $HOME/.claude/orchestrate (#292); dev/test.sh fails fast when bats is missing.

setup() {
  load test_helper
  LIB="$BATS_TEST_DIRNAME/_lib.sh"
}

# orch_gh_api prints graphql or rest; ORCHESTRATE_GH_API is unset so the memo is consulted.
gh_api_mode() {
  env -u ORCHESTRATE_GH_API bash -c '. "$1"; orch_gh_api t' _ "$LIB"
}

@test "default state dir is a per-test directory, not under HOME" {
  [[ "$ORCHESTRATE_STATE_DIR" == "$BATS_TEST_TMPDIR"/* ]]
  [[ "$ORCHESTRATE_STATE_DIR" != "$HOME"/* ]]
}

@test "an inherited ORCHESTRATE_STATE_DIR is replaced by the helper" {
  inherited="$BATS_TEST_TMPDIR/inherited"
  run env ORCHESTRATE_STATE_DIR="$inherited" bash -c 'load() { :; }; BATS_TEST_TMPDIR=$1; source "$2/test_helper.bash" 2>/dev/null; echo "$ORCHESTRATE_STATE_DIR"' _ "$BATS_TEST_TMPDIR" "$BATS_TEST_DIRNAME"
  [[ "$output" != "$inherited" ]]
  [[ "$output" == "$BATS_TEST_TMPDIR"/* ]]
}

@test "a gh-no-graphql memo in the real HOME does not switch orch_gh_api to REST" {
  mkdir -p "$BATS_TEST_TMPDIR/realhome/.claude/orchestrate"
  date +%s >"$BATS_TEST_TMPDIR/realhome/.claude/orchestrate/gh-no-graphql"
  HOME="$BATS_TEST_TMPDIR/realhome" run gh_api_mode
  [ "$status" -eq 0 ]
  [ "$output" = graphql ]
}

@test "a memo in the test's own state dir still switches to REST" {
  mkdir -p "$ORCHESTRATE_STATE_DIR"
  date +%s >"$ORCHESTRATE_STATE_DIR/gh-no-graphql"
  run gh_api_mode
  [ "$output" = rest ]
}

@test "dev/test.sh exits 2 with a clear message when bats cannot be found" {
  run --separate-stderr env BATS="$BATS_TEST_TMPDIR/no-such-bats" "$BATS_TEST_DIRNAME/../../../dev/test.sh" test-state-isolation.bats
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"bats not found"* ]]
  [[ "$output" != *"FAIL"* ]]
}
