#!/usr/bin/env bats
# The shared pieces #304 pulled together: the one PR-row fixture (pr_fixture.bash), orch_state_root
# in _lib.sh, and lane-claim.sh keeping the reason when gh-rest-pr.sh fails.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  source "$SCRIPTS/pr_fixture.bash"
}

@test "the PR-row fixture gives a 40-character head ending in the number, and state OPEN" {
  run pr_fixture_row 7 me false false MERGEABLE '[]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.headRefOid | length' <<<"$output")" -eq 40 ]
  [ "$(jq -r '.headRefOid[-1:]' <<<"$output")" = 7 ]
  [ "$(jq -r .state <<<"$output")" = OPEN ]
}

@test "the PR-row fixture merges extra fields over the row, and pr_fixture_rows matches it row for row" {
  run pr_fixture_row 12 bob true false CONFLICTING '[]' '[]' '{"state":"MERGED","headRefName":"b12"}'
  [ "$(jq -r '.state + .headRefName' <<<"$output")" = MERGEDb12 ]
  one=$(pr_fixture_row 3 me false false MERGEABLE '[]')
  [ "$(pr_fixture_rows 3 3 me false false MERGEABLE '[]')" = "$one" ]
  [ "$(pr_fixture_rows 3 1 me false false MERGEABLE '[]' | jq -s -c 'map(.number)')" = "[3,2,1]" ]
}

@test "orch_state_root is ORCHESTRATE_STATE_DIR, else ~/.claude/orchestrate" {
  source "$SCRIPTS/_lib.sh"
  ORCHESTRATE_STATE_DIR=/x/y run orch_state_root
  [ "$output" = /x/y ]
  unset ORCHESTRATE_STATE_DIR
  HOME=/h run orch_state_root
  [ "$output" = /h/.claude/orchestrate ]
}

@test "lane-claim keeps gh-rest-pr.sh's failure reason on stderr when the REST read fails" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "stub-boom: no route" >&2; exit 1\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_GH_API=rest GH_READ_TRIES=1
  run --separate-stderr "$SCRIPTS/lane-claim.sh" check --issues 1 --repo o/r
  [ "$status" -eq 4 ]
  [[ "$output" == *"unverified"* ]]
  [[ "$stderr" == *"lane-claim.sh: gh-rest-pr.sh list failed"* ]]
  [[ "$stderr" == *"stub-boom"* ]]
}
