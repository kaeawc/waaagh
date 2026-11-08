#!/usr/bin/env bats
# pr-merge.sh refusal paths the other suites do not reach: a missing or stale readiness row (exit 7),
# unreadable check state without --evidence (exit 6), an unreadable review state (exit 9), the
# merge-sensitive refusals (exit 9) and lock loop, a superseded journal, and --method.
# Stubbed gh. Run: bats scripts/pr-merge-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_DIRECT_MERGE ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE ORCHESTRATE_REVIEW_BOTS
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  HEAD=abcdef0123456789abcdef0123456789abcdef01
  # Fixture switches in $FX: list-forbidden (PR list answers HTTP 403), list-head (the head the PR
  # list shows), view-state (state `pr view` reports), reviews-fail, files-fail, base-fail, behind.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
HEAD=abcdef0123456789abcdef0123456789abcdef01
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) echo '{"data":{"repository":{"p1":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' ;;
  "api --paginate repos/o/r/pulls/1/files"*) [ ! -f "$FX/files-fail" ] || { echo "HTTP 404" >&2; exit 1; }; printf 'gradle/libs.versions.toml\nsrc/a.kt\n' ;;
  "api repos/o/r/pulls/1/reviews"*) [ ! -f "$FX/reviews-fail" ] || { echo "HTTP 404" >&2; exit 1; }; echo '[]' ;;
  "api repos/o/r/issues/1/comments"*) echo '[]' ;;
  "api repos/o/r/pulls/1 "*) [ ! -f "$FX/base-fail" ] || { echo "HTTP 404" >&2; exit 1; }; echo main ;;
  "api repos/o/r/compare/"*) cat "$FX/behind" 2>/dev/null || echo 0 ;;
  "pr list"*) [ ! -f "$FX/list-forbidden" ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    jq -n --arg h "$(cat "$FX/list-head" 2>/dev/null || echo "$HEAD")" '[{number: 1, author: {login: "me"}, isDraft: false,
      isCrossRepository: false, baseRefName: "main", headRefOid: $h, mergeable: "MERGEABLE", labels: [],
      statusCheckRollup: [{name: "build", conclusion: "SUCCESS"}]}]' ;;
  "pr merge"*) echo MERGED >"$FX/merged" ;;
  "pr view"*) if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}'
    else jq -n --arg h "$HEAD" --arg s "$(cat "$FX/view-state" 2>/dev/null || echo OPEN)" '{state: $s, isDraft: false,
      isCrossRepository: false, headRefOid: $h, author: {login: "me"}, mergeable: "MERGEABLE", autoMergeRequest: null}'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

pm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 "$@"; }
merges() { grep -c '^pr merge' "$FX/calls" || true; }

@test "--method merge is passed to the merge, still bound to the full head" {
  pm --method merge
  [ "$status" -eq 0 ]
  grep -q "^pr merge 1 --repo o/r --merge --match-head-commit $HEAD$" "$FX/calls"
  grep -q 'method=merge' "$STATE/merges.log"
}

@test "no readiness row, or a row for another head, is refused with exit 7 and nothing merged" {
  echo 1111111111111111111111111111111111111111 >"$FX/list-head"
  pm
  [ "$status" -eq 7 ]
  [ "$output" = "refused: readiness row is for head 111111111, not abcdef012" ]
  grep -q $'\trefused: readiness row is for head 111111111' "$STATE/merges.log"
  rm "$FX/list-head"
  touch "$FX/list-forbidden"
  pm
  [ "$status" -eq 7 ]
  [ "$output" = "refused: no readiness row for PR 1" ]
  [ "$(merges)" -eq 0 ]
}

@test "direct mode without --evidence refuses when the head's checks cannot be read (exit 6)" {
  touch "$FX/list-forbidden"
  ORCHESTRATE_DIRECT_MERGE=1 pm
  [ "$status" -eq 6 ]
  [ "$output" = "refused: the head's checks could not be read; a merge past them needs --evidence" ]
  grep -q 'refused: check state unreadable and no --evidence' "$STATE/merges.log"
  [ "$(merges)" -eq 0 ]
  # With evidence the unreadable check state is not consulted.
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 0 ]
}

@test "an unreadable review state, or an unknown policy, is exit 9 and nothing is attempted" {
  mkdir -p "$STATE"
  echo review-at-head >"$STATE/review-policy"
  touch "$FX/reviews-fail"
  pm
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: review state of PR 1 unreadable; nothing was attempted" ]
  grep -q 'refused: review state unreadable: unverified: reviews of PR 1 could not be read' "$STATE/merges.log"
  echo sometimes >"$STATE/review-policy"
  pm
  [ "$status" -eq 9 ]
  [ "$(merges)" -eq 0 ]
  [ ! -f "$STATE/ops/merge-pr1.json" ]
}

@test "merge-sensitive: unreadable PR files or an unverifiable check refuse with exit 9 and release the lock" {
  export ORCHESTRATE_MERGE_SENSITIVE=gradle/libs.versions.toml
  touch "$FX/files-fail"
  pm
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: the files of PR 1 could not be read; nothing was attempted" ]
  rm "$FX/files-fail"
  touch "$FX/base-fail"
  pm
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: the base branch of PR 1 could not be read; nothing was attempted" ]
  [ -z "$(ls -A "$STATE/locks" 2>/dev/null)" ]
  [ "$(merges)" -eq 0 ]
}

@test "merge-sensitive: every touched pattern is locked for the merge, then released" {
  export ORCHESTRATE_MERGE_SENSITIVE='gradle/libs.versions.toml,src/'
  pm
  [ "$status" -eq 0 ]
  grep -q 'sensitive clear: PR 1 touches gradle/libs.versions.toml,src/ and its head contains main' "$STATE/merges.log"
  [ "$(merges)" -eq 1 ]
  [ -z "$(ls -A "$STATE/locks")" ]
}

@test "an unfinished journal for a PR that is no longer open is superseded, then the PR is ineligible" {
  mkdir -p "$STATE/ops"
  jq -cn --arg h "$HEAD" '{op: "merge", repo: "o/r", pr: 1, head: $h, attempt: "1-1", state: "intent"}' >"$STATE/ops/merge-pr1.json"
  echo CLOSED >"$FX/view-state"
  pm
  [ "$status" -eq 3 ]
  [[ "$output" == "ineligible: "*'"state":"CLOSED"'* ]]
  [ "$(jq -r .state "$STATE/ops/merge-pr1.json")" = superseded ]
  [ "$(merges)" -eq 0 ]
}
