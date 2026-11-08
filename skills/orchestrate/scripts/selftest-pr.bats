#!/usr/bin/env bats
# Self-test for the orchestrate helper scripts (pr). Shared helpers: selftest_helper.bash.

setup() {
  load test_helper
  load selftest_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  echo one >"$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" commit -qm init
}

@test "pr-ready classifies ready, waiting, blocked and skipped PRs" {
  stub_gh_router
  {
    pr_row 1 me false false MERGEABLE "$OKC"
    pr_row 2 me false false MERGEABLE '[{"name":"build","status":"IN_PROGRESS","conclusion":""}]'
    pr_row 3 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"lint","conclusion":"FAILURE"}]'
    pr_row 4 me false false CONFLICTING "$OKC"
    pr_row 5 me true false MERGEABLE "$OKC"
    pr_row 6 me false true MERGEABLE "$OKC"
    pr_row 7 other false false MERGEABLE "$OKC"
    pr_row 8 me false false MERGEABLE '[{"name":"lint","conclusion":"SUCCESS"}]'
    pr_row 9 me false false MERGEABLE "$OKC" '[{"name":"hold"}]'
    pr_row 10 me false false MERGEABLE '[{"name":"build","conclusion":"FAILURE","startedAt":"2026-09-27T01:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/50/job/500"},{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T02:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/50/job/501"}]'
    pr_row 11 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]'
    pr_row 12 me false false MERGEABLE '[{"name":"job (${{ matrix.os }})","conclusion":"CANCELLED","workflowName":"PR","startedAt":"2026-09-27T01:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/60/job/600"},{"name":"build","conclusion":"SUCCESS","workflowName":"PR","startedAt":"2026-09-27T02:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/61/job/610"}]'
    pr_row 13 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS","workflowName":"PR","startedAt":"2026-09-27T01:00:00Z"},{"name":"slow","conclusion":"CANCELLED","workflowName":"PR","startedAt":"2026-09-27T02:00:00Z"}]'
  } | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r --ignore-check sim
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tREADY'* ]]
  [[ "$output" == *$'2\tWAIT'*"pending:build"* ]]
  [[ "$output" == *$'3\tBLOCK'*"fail:lint"* ]]
  [[ "$output" == *$'4\tBLOCK'*"conflict"* ]]
  [[ "$output" == *$'5\tSKIP'*"draft"* ]]
  [[ "$output" == *$'6\tSKIP'*"fork"* ]]
  [[ "$output" != *$'\n7\t'* ]]
  [[ "$output" == *$'8\tBLOCK'*"missing-required:build"* ]]
  [[ "$output" == *$'9\tSKIP'*"hold"* ]]
  [[ "$output" == *$'10\tREADY'* ]]
  [[ "$output" == *$'11\tREADY'* ]]
  [[ "$output" == *$'12\tREADY'* ]]
  [[ "$output" == *$'13\tBLOCK'*"fail:slow"* ]]
  [[ "$output" == *"open=12 ready=4"* ]]
}

@test "pr-ready supersedes only proven replacements of the same check" {
  stub_gh_router
  echo '[]' >"$FX/rules.json"
  T1=2026-09-27T01:00:00Z T2=2026-09-27T02:00:00Z
  # A later sibling in the same run does not replace a cancelled job.
  [ "$(verdict_of "$(check unit CANCELLED CI $T1 70 700)" "$(check lint SUCCESS CI $T2 70 701)")" = $'BLOCK\tfail:unit' ]
  # The same without any run identity: still blocked.
  [ "$(verdict_of "$(check unit CANCELLED CI $T1)" "$(check lint SUCCESS CI $T2)")" = $'BLOCK\tfail:unit' ]
  # Same job name in two workflows: the Linux failure is not hidden by the Mac success.
  [ "$(verdict_of "$(check test FAILURE Linux $T1 71 710)" "$(check test SUCCESS Mac $T2 72 720)")" = $'BLOCK\tfail:test' ]
  # Same name from two providers (an Actions job and a status context).
  [ "$(verdict_of "$(check test FAILURE "" $T1 "" "" StatusContext)" "$(check test SUCCESS CI $T2 73 730)")" = $'BLOCK\tfail:test' ]
  # A rerun attempt (same run, newer job id) replaces the failure, whatever the timestamps say.
  [ "$(verdict_of "$(check unit FAILURE CI $T2 74 740)" "$(check unit SUCCESS CI $T2 74 741)")" = $'READY\t-' ]
  [ "$(verdict_of "$(check unit FAILURE CI "" 74 740)" "$(check unit SUCCESS CI "" 74 741)")" = $'READY\t-' ]
  # A genuinely newer run of the same workflow and job replaces a cancellation...
  [ "$(verdict_of "$(check unit CANCELLED CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)")" = $'READY\t-' ]
  # ...but not a failure: two runs of one workflow on the same head (push and pull_request) both count.
  [ "$(verdict_of "$(check unit FAILURE CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)")" = $'BLOCK\tfail:unit' ]
  # Partial rerun: the rerun job replaces only itself; an untouched failure in that run stays.
  [ "$(verdict_of "$(check unit FAILURE CI $T1 77 770)" "$(check e2e FAILURE CI $T1 77 771)" "$(check unit SUCCESS CI $T2 77 772)")" = $'BLOCK\tfail:e2e' ]
  # Matrix jobs are distinct checks; one failing leg blocks.
  [ "$(verdict_of "$(check "test (linux)" SUCCESS CI $T1 78 780)" "$(check "test (mac)" FAILURE CI $T1 78 781)")" = $'BLOCK\tfail:test (mac)' ]
  # Duplicates without run identity and equal or missing timestamps: every instance counts.
  [ "$(verdict_of "$(check build FAILURE CI $T1)" "$(check build SUCCESS CI $T1)")" = $'BLOCK\tfail:build' ]
  [ "$(verdict_of "$(check build SUCCESS CI "")" "$(check build FAILURE CI "")")" = $'BLOCK\tfail:build' ]
  # A cancelled matrix template without run identity is not superseded.
  [ "$(verdict_of "$(check 'job (${{ matrix.os }})' CANCELLED PR $T1)" "$(check build SUCCESS PR $T2)")" = $'BLOCK\tfail:job (${{ matrix.os }})' ]
}

@test "pr-ready lets a legacy status context's newer status replace its older one" {
  stub_gh_router
  echo '[]' >"$FX/rules.json"
  old=$(jq -cn '{__typename: "StatusContext", context: "ci/legacy", state: "FAILURE", startedAt: "2026-09-27T01:00:00Z"}')
  new=$(jq -cn '{__typename: "StatusContext", context: "ci/legacy", state: "SUCCESS", startedAt: "2026-09-27T02:00:00Z"}')
  [ "$(verdict_of "$old" "$new")" = $'READY\t-' ]
  [[ "$(verdict_of "$new" "$(jq -c '.startedAt = "2026-09-27T03:00:00Z"' <<<"$old")")" == $'BLOCK\tfail:ci/legacy'* ]]
}

@test "pr-ready blocks an otherwise ready PR with an unresolved review thread" {
  stub_gh_router
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  echo '{"1":[{"isResolved":false,"isOutdated":false},{"isResolved":false,"isOutdated":true}]}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'1\tBLOCK'*"threads=1"* ]]
}

@test "pr-ready fails closed when review threads are unreadable or span more than one page" {
  stub_gh_router
  { pr_row 1 me false false MERGEABLE "$OKC"; pr_row 2 me false false MERGEABLE "$OKC"; pr_row 3 me false false MERGEABLE "$OKC"; } |
    jq -s . >"$FX/prs.json"
  echo '{"1":"null","2":"more"}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'1\tBLOCK'*"threads=unknown"* ]]
  [[ "$output" == *$'2\tBLOCK'*"threads=unknown"* ]]
  [[ "$output" == *$'3\tREADY'* ]]
  touch "$FX/graphql-fails"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'3\tBLOCK'*"threads=unknown"* ]]
  [[ "$output" == *"ready=0"* ]]
}

@test "pr-ready never reports READY when the required-check policy is unreadable or malformed" {
  stub_gh_router
  pr_row 7 me false false MERGEABLE '[{"name":"lint","conclusion":"SUCCESS"}]' | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"missing-required:build"* ]]
  echo '[]' >"$FX/rules.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tREADY'* ]]
  touch "$FX/rules-fails"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'7\tBLOCK'*"policy=unknown"* ]]
  [[ "$output" == *"policy=unknown diagnostics="* ]]
  diag=$(printf '%s\n' "$output" | sed -n 's/.*diagnostics=//p')
  grep -q 'HTTP 403' "$diag"
  rm "$FX/rules-fails"
  echo '{"message":"oops"}' >"$FX/rules.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"policy=unknown"* ]]
  echo '[]' >"$FX/rules.json"
  touch "$FX/branch-fails"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"policy=unknown"* ]]
}

@test "pr-ready reads required checks from classic branch protection too" {
  stub_gh_router
  echo '[]' >"$FX/rules.json"
  echo '{"protected":true,"protection":{"required_status_checks":{"contexts":["ci/legacy"],"checks":[{"context":"build"}]}}}' >"$FX/branch.json"
  pr_row 7 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"missing-required:ci/legacy"* ]]
}

@test "pr-ready follows review-thread pages: an unresolved 101st thread blocks, all resolved passes" {
  stub_gh_router
  pr_row 7 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  jq -n '{"7": {pages: [[range(0; 100) | {isResolved: true, isOutdated: false}], [{isResolved: false, isOutdated: false}]]}}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"threads=1"* ]]
  [ "$(cat "$FX/pages")" = "page 7 1" ]
  jq -n '{"7": {pages: [[range(0; 100) | {isResolved: true, isOutdated: false}], [range(0; 100) | {isResolved: true, isOutdated: false}], [{isResolved: true, isOutdated: false}]]}}' >"$FX/threads.json"
  : >"$FX/pages"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tREADY'* ]]
  [ "$(wc -l <"$FX/pages")" -eq 2 ]
}

@test "pr-ready reads review threads in one batched call per 50 ready PRs" {
  stub_gh_router
  ready_prs 20
  run "$SCRIPTS/pr-ready.sh" --repo o/r --base main --author me
  [ "$status" -eq 0 ]
  [[ "$output" == *"open=20 ready=20"* ]]
  [ "$(grep -c graphql "$FX/calls")" -eq 1 ]
  [ "$(wc -l <"$FX/calls")" -eq 4 ]
  : >"$FX/calls"
  ready_prs 100
  run "$SCRIPTS/pr-ready.sh" --repo o/r --base main
  [[ "$output" == *"open=100 ready=100"* ]]
  [ "$(grep -c graphql "$FX/calls")" -eq 2 ]
}

@test "the merge-bot loop over 20 ready PRs makes 20 thread calls, not 210" {
  stub_gh_router
  for n in $(seq 20 -1 1); do
    ready_prs "$n"
    "$SCRIPTS/pr-ready.sh" --repo o/r --base main >/dev/null 2>&1
  done
  [ "$(grep -c graphql "$FX/calls")" -eq 20 ]
}

@test "pr-ready --delta prints only changes, GONE rows, or a one-line no-change" {
  stub_gh_router
  ready_prs 20
  run "$SCRIPTS/pr-ready.sh" --repo o/r --delta
  [ "$(printf '%s\n' "$output" | grep -c READY)" -eq 20 ]
  run "$SCRIPTS/pr-ready.sh" --repo o/r --delta
  [[ "$output" == "no-change"*"changed=0"* ]]
  [ "${#output}" -lt 80 ]
  # PR 1 merged (gone), PR 2 got a new head, PR 3 gained a failing check.
  jq '.[1:] | (.[0].headRefOid = "ffffffffff") | (.[1].statusCheckRollup += [{"name":"lint","conclusion":"FAILURE"}])' \
    "$FX/prs.json" >"$FX/p2" && mv "$FX/p2" "$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r --delta
  [[ "$output" == *$'1\tGONE'* ]]
  [[ "$output" == *$'2\tREADY\tfffffffff'* ]]
  [[ "$output" == *$'3\tBLOCK'*"fail:lint"* ]]
  [ "$(printf '%s\n' "$output" | grep -vc '^open=')" -eq 3 ]
  # A different invocation (other arguments) keeps its own snapshot.
  run "$SCRIPTS/pr-ready.sh" --repo o/r --delta --no-threads
  [ "$(printf '%s\n' "$output" | grep -c READY)" -eq 18 ]
}

@test "large outputs stay intact where SIGPIPE is ignored, as on CI runners" {
  stub_gh_router
  ready_prs 300
  # GitHub Actions starts steps with SIGPIPE ignored: an early-closed pipe then makes writers
  # print "Broken pipe" instead of dying, which once corrupted the JSON pr-ready parses.
  run bash -c "trap '' PIPE; exec '$SCRIPTS/pr-ready.sh' --repo o/r --no-threads"
  [ "$status" -eq 0 ]
  [[ "$output" == *"open=300 ready=300"* ]]
  [[ "$output" != *"Broken pipe"* ]]
}

@test "pr-ready reports a PR list that hit its limit" {
  stub_gh_router
  ready_prs 300
  run "$SCRIPTS/pr-ready.sh" --repo o/r --no-threads
  [[ "$output" == *"truncated=yes"* ]]
}

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

@test "pr-ready reports every blocker of a failing PR, including review threads it now reads" {
  stub_gh_router
  pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"test","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  echo '{"1":[{"isResolved":false,"isOutdated":false}]}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'1\tBLOCK\t'*$'\tfail:test threads=1'* ]]
  grep -q graphql "$FX/calls"
  pr_row 2 me false false UNKNOWN '[{"name":"build","status":"IN_PROGRESS"},{"name":"test","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'2\tBLOCK\t'*$'\tfail:test pending:build mergeable=UNKNOWN'* ]]
  run "$SCRIPTS/pr-ready.sh" --repo o/r --pr 3
  [ -z "$(printf '%s\n' "$output" | grep -v '^open=')" ]
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
