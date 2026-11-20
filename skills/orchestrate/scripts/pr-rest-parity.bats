#!/usr/bin/env bats
# pr-ready.sh over REST against the same run over GraphQL (#109): check supersession, review threads
# and --delta/--pr/SIGPIPE-ignored runs give the same rows either way. The rest of the REST suite is
# pr-rest.bats; setup in pr_rest_setup.bash. Run: bats scripts/pr-rest-parity.bats

load pr_rest_setup

@test "rest: only proven replacements supersede a check, as over GraphQL" {
  echo '[]' >"$FX/rules.json"
  T1=2026-09-27T01:00:00Z T2=2026-09-27T02:00:00Z
  [ "$(verdict_both "$(check unit CANCELLED CI $T1 70 700)" "$(check lint SUCCESS CI $T2 70 701)")" = $'BLOCK\tfail:unit' ]
  [ "$(verdict_both "$(check unit CANCELLED CI $T1)" "$(check lint SUCCESS CI $T2)")" = $'BLOCK\tfail:unit' ]
  [ "$(verdict_both "$(check test FAILURE Linux $T1 71 710)" "$(check test SUCCESS Mac $T2 72 720)")" = $'BLOCK\tfail:test' ]
  [ "$(verdict_both "$(check test FAILURE "" $T1 "" "" StatusContext)" "$(check test SUCCESS CI $T2 73 730)")" = $'BLOCK\tfail:test' ]
  [ "$(verdict_both "$(check unit FAILURE CI $T2 74 740)" "$(check unit SUCCESS CI $T2 74 741)")" = $'READY\t-' ]
  [ "$(verdict_both "$(check unit CANCELLED CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)")" = $'READY\t-' ]
  [ "$(verdict_both "$(check unit FAILURE CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)")" = $'BLOCK\tfail:unit' ]
  [ "$(verdict_both "$(check unit FAILURE CI $T1 77 770)" "$(check e2e FAILURE CI $T1 77 771)" "$(check unit SUCCESS CI $T2 77 772)")" = $'BLOCK\tfail:e2e' ]
  [ "$(verdict_both "$(check build FAILURE CI $T1)" "$(check build SUCCESS CI $T1)")" = $'BLOCK\tfail:build' ]
  [ "$(verdict_both "$(check 'job (${{ matrix.os }})' CANCELLED PR $T1)" "$(check build SUCCESS PR $T2)")" = $'BLOCK\tfail:job (${{ matrix.os }})' ]
  old=$(jq -cn '{__typename: "StatusContext", context: "ci/legacy", state: "FAILURE", startedAt: "2026-09-27T01:00:00Z"}')
  new=$(jq -cn '{__typename: "StatusContext", context: "ci/legacy", state: "SUCCESS", startedAt: "2026-09-27T02:00:00Z"}')
  [ "$(verdict_both "$old" "$new")" = $'READY\t-' ]
}

@test "rest: review threads block, fail closed and follow pages as over GraphQL" {
  { pr_row 1 me false false MERGEABLE "$OKC"; pr_row 2 me false false MERGEABLE "$OKC"; pr_row 3 me false false MERGEABLE "$OKC"
    pr_row 4 me false false MERGEABLE "$OKC"; pr_row 5 me false false MERGEABLE '[{"name":"test","conclusion":"FAILURE"}]'; } |
    jq -s . >"$FX/prs.json"
  jq -n '{"1": [{isResolved: false, isOutdated: false}, {isResolved: false, isOutdated: true}], "2": "null", "3": "more",
          "4": {pages: [[range(0; 100) | {isResolved: true, isOutdated: false}], [{isResolved: false, isOutdated: false}]]},
          "5": [{isResolved: false, isOutdated: false}]}' >"$FX/threads.json"
  both --repo o/r
  [[ "$output" == *$'1\tBLOCK\t'*$'\tthreads=1'* ]]
  [[ "$output" == *$'2\tBLOCK\t'*"threads=unknown"* ]]
  [[ "$output" == *$'3\tBLOCK\t'*"threads=unknown"* ]]
  [[ "$output" == *$'4\tBLOCK\t'*$'\tthreads=1'* ]]
  [[ "$output" == *$'5\tBLOCK\t'*"fail:test missing-required:build few-checks=0 threads=1"* ]]
  grep -q 'pulls/1/ccr/review_threads' "$FX/rest-calls"
  # The same answers in the other shapes the undocumented route may use.
  for shape in snake wrapped; do
    echo "$shape" >"$FX/thread-shape"
    both --repo o/r
    [[ "$output" == *$'1\tBLOCK\t'*$'\tthreads=1'* ]]
  done
  # Every thread read failing: nothing is READY.
  echo '{}' >"$FX/threads.json"; rm -f "$FX/thread-shape"
  touch "$FX/graphql-fails"
  both --repo o/r
  [[ "$output" == *"ready=0"* ]]
}

@test "rest: --delta, --pr and SIGPIPE-ignored runs give the same rows" {
  ready_prs 20
  both --repo o/r --delta
  [ "$(printf '%s\n' "$output" | grep -c READY)" -eq 20 ]
  both --repo o/r --delta
  [[ "$output" == "no-change"*"changed=0"* ]]
  jq '.[1:] | (.[0].headRefOid = "ffffffffff") | (.[1].statusCheckRollup += [{"name":"lint","conclusion":"FAILURE"}])' \
    "$FX/prs.json" >"$FX/p2" && mv "$FX/p2" "$FX/prs.json"
  both --repo o/r --delta
  [[ "$output" == *$'1\tGONE'* ]]
  [[ "$output" == *$'2\tREADY\tfffffffff'* ]]
  [[ "$output" == *$'3\tBLOCK'*"fail:lint"* ]]
  : >"$FX/rest-calls"
  both --repo o/r --pr 3
  [ "$(printf '%s\n' "$output" | grep -c $'\t')" -eq 1 ]
  [ "$(grep -c '/check-runs' "$FX/rest-calls")" -eq 1 ]   # only the named PR is read
  run bash -c "trap '' PIPE; ORCHESTRATE_GH_API=rest exec '$SCRIPTS/pr-ready.sh' --repo o/r --no-threads"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Broken pipe"* ]]
  [[ "$output" == *"api=rest"* ]]
}

# --- the merge-selection fixtures ------------------------------------------------------------
