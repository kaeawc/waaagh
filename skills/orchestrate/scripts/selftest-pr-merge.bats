#!/usr/bin/env bats
# Self-test for the orchestrate helper scripts (pr): pr-merge.sh. Shared helpers: selftest_helper.bash;
# setup: selftest_pr_setup.bash. Run: bats scripts/selftest-pr-merge.bats

load selftest_pr_setup

@test "pr-merge merges a verified head and logs it" {
  merge_fixture
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 0 ]
  [[ "$output" == "merged 1 feedface" ]]
  grep -q 'pr merge 1 --repo o/r --squash --match-head-commit abcdef0123456789abcdef0123456789abcdef01$' "$FX/calls"
  grep -q $'head=abcdef0123456789abcdef0123456789abcdef01\tmerged feedface' "$ORCHESTRATE_STATE_DIR/o__r/merges.log"
}

@test "pr-merge refuses when the head moves between its check and the merge" {
  merge_fixture
  touch "$FX/race"; echo 1111111111111111111111111111111111111111 >"$FX/race-head"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 3 ]
  [[ "$output" == "head moved during merge: judged abcdef012, now 111111111"* ]]
  [ ! -f "$FX/merged" ]
  [ "$(grep -c 'pr merge' "$FX/calls")" -eq 1 ]
  grep -q $'head=abcdef0123456789abcdef0123456789abcdef01\trefused head moved during merge to 111111111' "$ORCHESTRATE_STATE_DIR/o__r/merges.log"
}

@test "pr-merge --admin keeps the same head guard" {
  merge_fixture
  sim_fails
  touch "$FX/race"; echo 2222222222222222222222222222222222222222 >"$FX/race-head"
  ORCHESTRATE_FAST_PATH_OVER=0 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --except-check sim --evidence "known flake: sim timeout"
  [ "$status" -eq 3 ]
  grep -q 'pr merge 1 --repo o/r --squash --match-head-commit abcdef0123456789abcdef0123456789abcdef01 --admin' "$FX/calls"
  [ ! -f "$FX/merged" ]
}

@test "pr-merge refuses a moved head, a foreign author, and a red default branch" {
  merge_fixture
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head 1234567
  [ "$status" -eq 3 ]
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --author someone
  [ "$status" -eq 3 ]
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red abc" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 4 ]
  run ! grep -q 'pr merge' "$FX/calls"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --main-fix
  [ "$status" -eq 0 ]
}

@test "pr-merge allows --admin only in the fast path and only with evidence" {
  merge_fixture
  sim_fails
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin
  [ "$status" -eq 6 ]
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --except-check sim --evidence "known flake: sim timeout"
  [ "$status" -eq 6 ]
  [[ "$output" == *"fast-path only"* ]]
  run ! grep -q 'pr merge' "$FX/calls"
  ORCHESTRATE_FAST_PATH_OVER=0 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --evidence "known flake: sim timeout"
  [ "$status" -eq 6 ]
  [[ "$output" == *"needs --except-check"* ]]
  ORCHESTRATE_FAST_PATH_OVER=0 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --except-check sim --evidence "known flake: sim timeout"
  [ "$status" -eq 0 ]
  grep -q 'pr merge 1 --repo o/r --squash --match-head-commit abcdef0123456789abcdef0123456789abcdef01 --admin' "$FX/calls"
}

@test "the admin exception covers only the excepted checks, never review, policy or other failures" {
  merge_fixture
  sim_fails
  export ORCHESTRATE_FAST_PATH_OVER=0
  adm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --evidence "sim: known flake" "$@"; }
  # A classified flake plus an unresolved review thread is refused.
  echo '{"1":[{"isResolved":false,"isOutdated":false}]}' >"$FX/threads.json"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"threads=1"* ]]
  # Unreadable review threads cannot authorize it either.
  echo '{"1":"null"}' >"$FX/threads.json"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"threads=unknown"* ]]
  echo '{}' >"$FX/threads.json"
  # A failure that is not excepted, or a pending check, is refused.
  pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"FAILURE"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"fail:build (not excepted)"* ]]
  pr_row 1 me false false MERGEABLE '[{"name":"build","status":"IN_PROGRESS"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"pending:build"* ]]
  # Unknown policy is not waived by a check exception.
  pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  touch "$FX/rules-fails"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"policy=unknown"* ]]
  run ! grep -q 'pr merge' "$FX/calls"
  rm "$FX/rules-fails"
  adm --except-check sim
  [ "$status" -eq 0 ]
}

@test "pr-merge refuses a PR that is not READY unless direct merging was authorized" {
  merge_fixture
  sim_fails
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 7 ]
  [[ "$output" == "not ready: BLOCK fail:sim"* ]]
  pr_row 1 me false false UNKNOWN '[{"name":"build","status":"IN_PROGRESS"}]' | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 7 ]
  [[ "$output" == "not ready: WAIT pending:build"* ]]
  run ! grep -q 'pr merge' "$FX/calls"
  ORCHESTRATE_DIRECT_MERGE=1 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 0 ]
}

@test "pr-merge reconciles a lost response, a failed readback and a queued merge without merging twice" {
  merge_fixture
  export ORCHESTRATE_READ_SLEEP=0
  J="$ORCHESTRATE_STATE_DIR/o__r/ops/merge-pr1.json"
  # Success, response lost: the readback shows MERGED.
  echo lost >"$FX/merge-mode"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 0 ]
  [ "$(jq -r .state "$J")" = merged ]
  # Success, readback fails: unknown, journaled; the rerun reconciles without a second merge.
  rm -f "$FX/merged"; : >"$FX/calls"
  echo no-readback >"$FX/merge-mode"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 9 ]
  [[ "$output" == "unverified:"* ]]
  [ "$(jq -r .state "$J")" = unknown ]
  grep -q 'unverified: merge exit 0, readback failed' "$ORCHESTRATE_STATE_DIR/o__r/merges.log"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 0 ]
  [[ "$output" == *"(earlier attempt)"* ]]
  [ "$(grep -c 'pr merge' "$FX/calls")" -eq 1 ]
  # Accepted into GitHub's merge queue: queued, and a rerun does not merge again.
  rm -f "$FX/merged"; : >"$FX/calls"
  echo queued >"$FX/merge-mode"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 8 ]
  [[ "$output" == "queued:"* ]]
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 8 ]
  [ "$(grep -c 'pr merge' "$FX/calls")" -eq 1 ]
}

@test "a check failing on the head is never bypassed without logged evidence (#26)" {
  merge_fixture
  sim_fails
  # Waved off as advisory: refused without evidence, merged and logged with it.
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --ignore-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == "refused: sim failing on this head"* ]]
  run ! grep -q 'pr merge' "$FX/calls"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --ignore-check sim --evidence "sim: classifier INFRA run 77 (device farm 503)"
  [ "$status" -eq 0 ]
  grep -q 'evidence=sim: classifier INFRA run 77' "$ORCHESTRATE_STATE_DIR/o__r/merges.log"
  # Direct mode skips the readiness gate, not this rule.
  rm -f "$FX/merged"
  ORCHESTRATE_DIRECT_MERGE=1 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 6 ]
  ORCHESTRATE_DIRECT_MERGE=1 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --evidence "sim: known flake #4"
  [ "$status" -eq 0 ]
}

@test "pr-merge reports a merge GitHub rejected" {
  merge_fixture
  touch "$FX/merge-fails"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 5 ]
}
