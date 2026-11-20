#!/usr/bin/env bats
# pr-merge.sh without GraphQL (#266): against the cloud-session gh (rest_stub.bash: every `gh pr`
# call refused with HTTP 403), it reads the PR over REST and merges with PUT pulls/<n>/merge bound
# to the full head (sha=). Covers the merge, a moved head (409), a PR GitHub will not merge (405),
# 5xx outcomes reconciled through the journal, the auto-mode fallback and the guards on this path.
# Run: bats scripts/pr-merge-rest.bats

setup() {
  load test_helper
  load selftest_helper
  load rest_stub
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  merge_fixture
  rest_wrap
  export ORCHESTRATE_AUTHOR=me ORCHESTRATE_READ_SLEEP=0 ORCHESTRATE_MERGE_FAKE_SLEEP=1 ORCHESTRATE_GH_API=rest
  unset ORCHESTRATE_DIRECT_MERGE ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE
  HEAD=abcdef0123456789abcdef0123456789abcdef01
  ST="$ORCHESTRATE_STATE_DIR/o__r"
  J="$ST/ops/merge-pr1.json"
  # One green PR at the full head: the list row pr-ready.sh judges and the pulls/1 object.
  pr_row 1 me false false MERGEABLE "$OKC" | jq -c --arg h "$HEAD" '.headRefOid = $h | .state = "OPEN"' >"$FX/row.json"
  jq -s . "$FX/row.json" >"$FX/prs.json"
  cp "$FX/row.json" "$FX/view-1.json"
  touch "$FX/rest-mode"
  export GITHUB_STATUS_URL="file://$BATS_TEST_TMPDIR/githubstatus.json"
  echo '{"status":{"indicator":"none"},"components":[{"name":"Pull Requests","status":"operational","group":false}]}' \
    >"$BATS_TEST_TMPDIR/githubstatus.json"
}

pm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 "$@"; }
puts() { [ -f "$FX/writes" ] || { echo 0; return; }; grep -c "^rest-merge 1 " "$FX/writes" || true; }
graphql_tries() { [ -f "$FX/rest-calls" ] || { echo 0; return; }; grep -cE '^(pr |api graphql)' "$FX/rest-calls" || true; }

@test "rest: merges with PUT pulls/1/merge bound to the full head, confirmed by re-reading the PR" {
  pm
  [ "$status" -eq 0 ]
  [ "$output" = "merged 1 feedface" ]
  [ "$(cat "$FX/writes")" = "rest-merge 1 sha=$HEAD" ]
  grep -q "^api -X PUT repos/o/r/pulls/1/merge -f merge_method=squash -f sha=$HEAD$" "$FX/rest-calls"
  [ "$(graphql_tries)" -eq 0 ]
  grep -q $'\tmerged feedface method=squash admin=no api=rest$' "$ST/merges.log"
  [ "$(jq -r '.state + " " + .api' "$J")" = "merged rest" ]
}

@test "rest: auto mode falls back after GraphQL is refused, and remembers the refusal" {
  unset ORCHESTRATE_GH_API
  pm --method merge
  [ "$status" -eq 0 ]
  [ "$output" = "merged 1 feedface" ]
  [ -f "$ORCHESTRATE_STATE_DIR/gh-no-graphql" ]
  grep -q "^api -X PUT repos/o/r/pulls/1/merge -f merge_method=merge -f sha=$HEAD$" "$FX/rest-calls"
  # The one GraphQL attempt was the first PR read; nothing after it tried GraphQL again.
  [ "$(grep -c '^pr ' "$FX/rest-calls")" -eq 1 ]
  [ "$(grep -c '^pr merge' "$FX/rest-calls" || true)" -eq 0 ]
}

@test "rest: a head moved before the merge gets 409 and is reported as a moved head (exit 3)" {
  echo moved >"$FX/rest-merge"
  pm
  [ "$status" -eq 3 ]
  [ "$output" = "head moved during merge: judged abcdef012, now 111111111; re-judge it" ]
  [ "$(puts)" -eq 1 ]
  [ "$(jq -r .state "$FX/view-1.json")" = OPEN ]
  grep -q $'\trefused head moved during merge to 111111111' "$ST/merges.log"
  [ "$(jq -r .state "$J")" = rejected ]
}

@test "rest: a PR GitHub will not merge (405) is a rejected merge (exit 5), not retried" {
  echo 405 >"$FX/rest-merge"
  pm
  [ "$status" -eq 5 ]
  [ "$output" = "merge failed: gh: Pull Request is not mergeable (HTTP 405)" ]
  [ "$(puts)" -eq 1 ]
  [ "$(jq -r .state "$J")" = rejected ]
}

@test "rest: a 502 on a merge that landed is read back as merged (exit 0)" {
  echo lost >"$FX/rest-merge"
  pm
  [ "$status" -eq 0 ]
  [ "$output" = "merged 1 feedface" ]
  [ "$(puts)" -eq 1 ]
}

@test "rest: a 5xx on a merge that landed, then no readback, is unknown (exit 9); the rerun reconciles it from the journal" {
  echo no-readback >"$FX/rest-merge"
  pm
  [ "$status" -eq 9 ]
  [[ "$output" == *"gh-rest-pr.sh view failed"*"unverified: the merge of PR 1 may or may not have happened (exit 1, readback failed)"* ]]
  [ "$(jq -r .state "$J")" = unknown ]
  rm "$FX/rest-view-fails"
  pm
  [ "$status" -eq 0 ]
  [ "$output" = "merged 1 feedface (earlier attempt)" ]
  [ "$(puts)" -eq 1 ]
  [ "$(jq -r .state "$J")" = merged ]
}

@test "rest: a 5xx with the PR still open is pending (exit 10), re-sent bound to the head, and a rerun merges" {
  echo 5xx >"$FX/rest-merge"
  ORCHESTRATE_MERGE_TRIES=2 pm
  [ "$status" -eq 10 ]
  [[ "$output" == *"pr-merge: wait 60"*"pending: the merge of PR 1 got 5xx (gh: HTTP 502: Bad Gateway) and the PR is still OPEN after 2 rounds"* ]]
  [ "$(puts)" -eq 2 ]
  [ "$(grep -c "sha=$HEAD$" "$FX/writes")" -eq 2 ]
  [ "$(jq -r .state "$J")" = pending ]
  rm "$FX/rest-merge"
  pm
  [ "$status" -eq 0 ]
  [ "$output" = "merged 1 feedface" ]
  [ "$(puts)" -eq 3 ]
}

@test "rest: the guards hold on this path: a hold (exit 14) and a red default branch (exit 4) merge nothing" {
  "$SCRIPTS/hold.sh" add --repo o/r --pr 1 --until owner --reason "owner wants a look" >/dev/null
  pm
  [ "$status" -eq 14 ]
  [[ "$output" == "held: PR 1 is in the hold file (#1 until:owner "* ]]
  "$SCRIPTS/hold.sh" release --repo o/r --pr 1 >/dev/null
  echo "red abc" >"$ST/MAIN_RED"
  pm
  [ "$status" -eq 4 ]
  [ "$(puts)" -eq 0 ]
  [ "$(graphql_tries)" -eq 0 ]
}

@test "rest: --admin counts the open PRs over REST for the fast-path check" {
  pm --admin --except-check sim --evidence "known flake: sim timeout"
  [ "$status" -eq 6 ]
  [[ "$output" == "refused: --admin is fast-path only (1 open PRs, threshold >20)" ]]
  grep -q '^api repos/o/r/pulls?state=open' "$FX/rest-calls"
  [ "$(puts)" -eq 0 ]
  [ "$(graphql_tries)" -eq 0 ]
}
