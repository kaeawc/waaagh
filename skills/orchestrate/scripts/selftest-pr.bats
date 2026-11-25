#!/usr/bin/env bats
# Self-test for the orchestrate helper scripts (pr): pr-ready.sh. pr-merge.sh is in
# selftest-pr-merge.bats. Shared helpers: selftest_helper.bash; setup: selftest_pr_setup.bash.

load selftest_pr_setup

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
  cases=() want=()   # each case is its own PR; one pr-ready run classifies them all (#112)
  # A later sibling in the same run does not replace a cancelled job.
  expect $'BLOCK\tfail:unit' "$(check unit CANCELLED CI $T1 70 700)" "$(check lint SUCCESS CI $T2 70 701)"
  # The same without any run identity: still blocked.
  expect $'BLOCK\tfail:unit' "$(check unit CANCELLED CI $T1)" "$(check lint SUCCESS CI $T2)"
  # Same job name in two workflows: the Linux failure is not hidden by the Mac success.
  expect $'BLOCK\tfail:test' "$(check test FAILURE Linux $T1 71 710)" "$(check test SUCCESS Mac $T2 72 720)"
  # Same name from two providers (an Actions job and a status context).
  expect $'BLOCK\tfail:test' "$(check test FAILURE "" $T1 "" "" StatusContext)" "$(check test SUCCESS CI $T2 73 730)"
  # A rerun attempt (same run, newer job id) replaces the failure, whatever the timestamps say.
  expect $'READY\t-' "$(check unit FAILURE CI $T2 74 740)" "$(check unit SUCCESS CI $T2 74 741)"
  expect $'READY\t-' "$(check unit FAILURE CI "" 74 740)" "$(check unit SUCCESS CI "" 74 741)"
  # A genuinely newer run of the same workflow and job replaces a cancellation...
  expect $'READY\t-' "$(check unit CANCELLED CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)"
  # ...but not a failure: two runs of one workflow on the same head (push and pull_request) both count.
  expect $'BLOCK\tfail:unit' "$(check unit FAILURE CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)"
  # Partial rerun: the rerun job replaces only itself; an untouched failure in that run stays.
  expect $'BLOCK\tfail:e2e' "$(check unit FAILURE CI $T1 77 770)" "$(check e2e FAILURE CI $T1 77 771)" "$(check unit SUCCESS CI $T2 77 772)"
  # Matrix jobs are distinct checks; one failing leg blocks.
  expect $'BLOCK\tfail:test (mac)' "$(check "test (linux)" SUCCESS CI $T1 78 780)" "$(check "test (mac)" FAILURE CI $T1 78 781)"
  # Duplicates without run identity and equal or missing timestamps: every instance counts.
  expect $'BLOCK\tfail:build' "$(check build FAILURE CI $T1)" "$(check build SUCCESS CI $T1)"
  expect $'BLOCK\tfail:build' "$(check build SUCCESS CI "")" "$(check build FAILURE CI "")"
  # A cancelled matrix template without run identity is not superseded.
  expect $'BLOCK\tfail:job (${{ matrix.os }})' "$(check 'job (${{ matrix.os }})' CANCELLED PR $T1)" "$(check build SUCCESS PR $T2)"
  verdicts_match
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
  # The 20 PR lists (20 rows down to 1) from one jq, not two per pass (#112).
  lists=()
  while IFS= read -r l; do lists+=("$l"); done < <(pr_rows 1 20 me false false MERGEABLE "$OKC" | jq -sc '. as $a | range(20; 0; -1) | $a[:.]')
  [ "${#lists[@]}" -eq 20 ]
  for l in "${lists[@]}"; do
    printf '%s\n' "$l" >"$FX/prs.json"
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
