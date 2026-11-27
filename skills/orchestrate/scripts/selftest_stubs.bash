# The gh stubs of the selftest-*.bats suites and the suites that share them: stub_gh, stub_gh_router
# and stub_gh_merge_path. selftest_helper.bash loads this with selftest_fixtures.bash; load this file
# alone to get the stubs without the fixtures' names (#310).
#
# gh-read.sh appends `--include` to every `gh api` call that has no --paginate, so a stub that matches
# `api repos/o/r/actions/jobs/9` literally misses the call (gh-read reports the miss as transient and
# retries it). Read the arguments with test_helper.bash's gh_stub_args (it drops `--include` and
# `-i` from a `gh api` call and sets a), or glob a trailing `*` on the pattern. Both stubs below
# do the former; test_helper.bash's "Stubbing gh" comment has the whole story.

# gh stub: serves $GH_FIXTURE for `gh pr list`, and records the args it was called with.
stub_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/gh.args"
cat "$GH_FIXTURE"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" GH_FIXTURE="$BATS_TEST_TMPDIR/prs.json"
  cat >"$GH_FIXTURE" <<'JSON'
[
 {"number":1,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/a","updatedAt":"2026-09-27T00:00:00Z","url":"u1"},
 {"number":2,"author":{"login":"someone"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/b","updatedAt":"2026-09-27T00:00:00Z","url":"u2"},
 {"number":3,"author":{"login":"octocat"},"isDraft":true,"isCrossRepository":false,"headRefName":"work/c","updatedAt":"2026-09-27T00:00:00Z","url":"u3"},
 {"number":4,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":true,"headRefName":"work/d","updatedAt":"2026-09-27T00:00:00Z","url":"u4"},
 {"number":5,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/e","updatedAt":"2026-09-27T11:55:00Z","url":"u5"},
 {"number":6,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/f","updatedAt":"2026-09-27T00:00:00Z","url":"u6"},
 {"number":7,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/g","updatedAt":"2026-09-27T00:00:00Z","url":"u7"}
]
JSON
}

# gh stub that answers by subcommand from fixture files and records every call. It reads its
# arguments with test_helper.bash's gh_stub_args, as stub_gh_routes does: `--include` and `-i` are
# dropped from `gh api` calls, so a read through gh-read.sh matches the same routes as a direct gh
# call, and $FX/calls logs the call without them (#166). Classic branch protection
# (branches/<b>/protection/...) has its own route, $FX/protection.json or a 404, so a suite can stub
# it apart from the branch itself (#233). A new suite should start from test_helper.bash's
# stub_gh_routes instead of another case statement.
stub_gh_router() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  {
    gh_stub_header fast   # called hundreds of times per suite: the fast shebang (#112)
    cat <<'STUB'
gh_stub_args "$@"
echo "$a" >>"$FX/calls"
# prs_of_query ARGS: the PR numbers of a batched threads query's `pN:` aliases, one per line, with
# no grep or tr process per call (#112).
prs_of_query() {
  local q=$1 re=' p([0-9]+):'
  while [[ "$q" =~ $re ]]; do echo "${BASH_REMATCH[1]}"; q=${q#*"${BASH_REMATCH[0]}"}; done
}
case "$a" in
  "api user") echo '{"login":"me"}' ;;
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) [ -f "$FX/rules-fails" ] && { echo "HTTP 403: Resource not accessible" >&2; exit 1; }; cat "$FX/rules.json" ;;
  "api repos/o/r/branches/"*"/protection"*) # classic protection, its own route (#233): served from
    # $FX/protection.json, else the 404 a token without admin rights gets
    [ -f "$FX/protection.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$FX/protection.json" ;;
  "api repos/o/r/branches/"*) [ -f "$FX/branch-fails" ] && { echo "HTTP 403" >&2; exit 1; }; cat "$FX/branch.json" ;;
  *graphql*) # threads.json maps PR number -> thread nodes, "null" (no data), "more" (a next page
    # without a cursor) or {"pages": [[nodes], [nodes], ...]} (served through real cursors c1, c2, ...)
    [ -f "$FX/graphql-fails" ] && exit 1
    if [[ "$*" == *"cursor=c"* ]]; then
      n=$(printf '%s\n' "$*" | sed -nE 's/.*-F pr=([0-9]+).*/\1/p')
      c=$(printf '%s\n' "$*" | sed -nE 's/.*-f cursor=c([0-9]+).*/\1/p')
      echo "page $n $c" >>"$FX/pages"
      jq -n --argjson t "$(<"$FX/threads.json")" --arg n "$n" --argjson c "$c" '$t[$n].pages as $p
        | {data: {repository: {pullRequest: {reviewThreads: {pageInfo: {hasNextPage: (($c + 1) < ($p | length)),
           endCursor: ("c" + (($c + 1) | tostring))}, nodes: $p[$c]}}}}}'
    else
      jq -n --argjson t "$(<"$FX/threads.json")" --args '{data: {repository: (reduce $ARGS.positional[] as $n ({};
        .["p" + $n] = ($t[$n] // [] | if . == "null" then null
          elif . == "more" then {reviewThreads: {pageInfo: {hasNextPage: true}, nodes: []}}
          elif type == "object" then {reviewThreads: {pageInfo: {hasNextPage: ((.pages | length) > 1), endCursor: "c1"}, nodes: .pages[0]}}
          else {reviewThreads: {pageInfo: {hasNextPage: false}, nodes: .}} end)))}}' \
        $(prs_of_query "$*")
    fi ;;
  "pr merge"*) [ -f "$FX/merge-fails" ] && { echo "blocked"; exit 1; }
    # Like GitHub: refuse unless --match-head-commit names the current remote head exactly.
    want=$(printf '%s\n' "$*" | sed -nE 's/.*--match-head-commit ([0-9a-f]+).*/\1/p')
    cur=$(cat "$FX/remote-head" 2>/dev/null || jq -r .headRefOid "$FX/pr.json")
    { [ -n "$want" ] && [ "$want" = "$cur" ]; } || { echo "Head branch was modified. Review and try the merge again."; exit 1; }
    # $FX/merge-mode: lost (merged, error returned) | no-readback (merged, next reads fail) | queued
    case "$(cat "$FX/merge-mode" 2>/dev/null)" in
      lost) echo MERGED >"$FX/merged"; echo "HTTP 502 Bad Gateway" >&2; exit 1 ;;
      no-readback) echo MERGED >"$FX/merged"; echo 3 >"$FX/view-fails" ;;
      queued) touch "$FX/queued"; echo "! Pull request will be added to the merge queue"; exit 0 ;;
      *) echo MERGED >"$FX/merged" ;;
    esac ;;
  "pr view"*) if [ -s "$FX/view-fails" ] && [ "$(<"$FX/view-fails")" -gt 0 ]; then
      echo $(($(<"$FX/view-fails") - 1)) >"$FX/view-fails"; echo "HTTP 502" >&2; exit 1; fi
    if [ -f "$FX/merged" ]; then cat "$FX/pr-merged.json"
    elif [ -f "$FX/queued" ]; then jq '.autoMergeRequest = {"enabledAt": "2026-09-27T12:00:00Z"}' "$FX/pr.json"
    elif [ -f "$FX/remote-head" ]; then jq --arg h "$(<"$FX/remote-head")" '.headRefOid = $h' "$FX/pr.json"
    else cat "$FX/pr.json"; if [ -f "$FX/race" ]; then rm "$FX/race"; cp "$FX/race-head" "$FX/remote-head"; fi; fi ;;
  "pr list"*merged*) cat "$FX/prs-merged.json" ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "api repos/o/r/actions/runs?"*) jq '{workflow_runs: map({name: .workflowName, status, conclusion, head_sha: .headSha, id: .databaseId, created_at: .createdAt})}' "$FX/runs.json" ;;
  "issue list"*--label*) cat "$FX/pause.json" ;;
  "issue list"*) cat "$FX/issues.json" ;;
  "issue view"*) # issue.json plus what earlier closes changed; $FX/view-fails counts down failures
    if [ -s "$FX/view-fails" ] && [ "$(<"$FX/view-fails")" -gt 0 ]; then
      echo $(($(<"$FX/view-fails") - 1)) >"$FX/view-fails"; echo "HTTP 502" >&2; exit 1; fi
    n=$3
    jq --argjson c "$(cat "$FX/comments-$n" 2>/dev/null || echo '[]')" --arg closed "$([ -f "$FX/closed-$n" ] && echo yes)" \
      '. + {comments: $c} + (if $closed == "yes" then {state: "CLOSED"} else {} end)' "$FX/issue.json" ;;
  "issue close"*) # $FX/close-mode: ok | comment-only (comment posted, close fails) | lost (done, error
    # returned) | no-readback (done, then the next reads fail)
    n=$3 body=""; while [ $# -gt 0 ]; do [ "$1" = --comment ] && body=$2; shift; done
    mode=$(cat "$FX/close-mode" 2>/dev/null || echo ok)
    if [ -n "$body" ]; then
      jq --arg b "$body" '. + [{body: $b}]' "${FX}/comments-$n" 2>/dev/null >"$FX/c.tmp" || jq -n --arg b "$body" '[{body: $b}]' >"$FX/c.tmp"
      mv "$FX/c.tmp" "$FX/comments-$n"
    fi
    case "$mode" in
      comment-only) exit 1 ;;
      lost) touch "$FX/closed-$n"; echo "HTTP 502" >&2; exit 1 ;;
      no-readback) touch "$FX/closed-$n"; echo 3 >"$FX/view-fails" ;;
      *) touch "$FX/closed-$n" ;;
    esac ;;
  *) echo "unexpected gh call: $a" >&2; exit 9 ;;
esac
STUB
  } >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
  echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' >"$FX/rules.json"
  echo '{}' >"$FX/threads.json"
  echo '{"protected":false}' >"$FX/branch.json"
  echo '[]' >"$FX/pause.json"
  echo '[]' >"$FX/prs-merged.json"
}

# stub_gh_merge_path: the gh stub for suites that run the real merge path (pr-ready.sh, pr-merge.sh,
# merge-queue.sh) end to end against the local bare origin seed_origin_copy makes (merge-holds.bats,
# review-holds.bats, review-head-cover.bats; #233). It reads its arguments with gh_stub_args and
# appends each call to $FX/calls. A PR's head is origin's refs/heads/<its branch>, its one check is
# green, it has no review threads and touches f.txt; rulesets are empty and the branch unprotected
# (classic protection: $FX/protection.json, else a 404). Exports FX and puts the stub first on PATH.
# Fixture switches in $FX:
#   branch          the branch `pr view` and `pr list` answer for (`pr list --head B` writes it)
#   num-<branch>    the PR number of <branch> (default 5)
#   merged-<n>      written by `pr merge <n>`: `pr view <n>` then reports MERGED
#   hold-on-view    a PR number: the first `pr view` adds a hold on it (a hold set mid-merge)
#   review-on-view  a PR number: the first `pr view` records a fix pass on it (mid-merge)
stub_gh_merge_path() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  {
    gh_stub_header
    cat <<'STUB'
gh_stub_args "$@"
echo "$a" >>"$FX/calls"
br=$(cat "$FX/branch" 2>/dev/null || true)
head_of() { git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify "refs/heads/$br" || echo none; }
num=$(cat "$FX/num-$br" 2>/dev/null || echo 5)
st="$ORCHESTRATE_STATE_DIR/o__r"
case "$a" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  "api repos/o/r/branches/"*"/protection"*)
    [ -f "$FX/protection.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$FX/protection.json" ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) jq -n --arg p "p$num" '{data: {repository: {($p): {reviewThreads: {pageInfo: {hasNextPage: false}, nodes: []}}}}}' ;;
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[]}' ;;
  "api --paginate repos/o/r/pulls/"*"/files"*) echo f.txt ;;
  "api repos/o/r/pulls/"*"/reviews"*) echo '[]' ;;
  "api repos/o/r/issues/"*"/comments"*) echo '[]' ;;
  "api repos/o/r/pulls/"*) echo main ;;
  "api repos/o/r/compare/"*) echo 0 ;;
  "pr list"*"--state merged"*) echo '[]' ;;
  "pr list"*--head*) b=$(echo "$a" | sed 's/.*--head \([^ ]*\).*/\1/'); echo "$b" >"$FX/branch"; br=$b
    jq -n --arg h "$(head_of)" --argjson n "$(cat "$FX/num-$b" 2>/dev/null || echo 5)" '[{number: $n, headRefOid: $h}]' ;;
  "pr list"*"--json number") jq -n --argjson n "$num" '[{number: $n}]' ;;
  "pr list"*) jq -n --arg h "$(head_of)" --argjson n "$num" \
      '[{number: $n, author: {login: "me"}, isDraft: false, isCrossRepository: false, baseRefName: "main",
         headRefOid: $h, mergeable: "MERGEABLE", labels: [],
         statusCheckRollup: [{name: "build", conclusion: "SUCCESS", startedAt: "2026-09-27T01:00:00Z"}]}]' ;;
  "pr create"*) ;;
  "pr merge"*) n=${a#pr merge }; touch "$FX/merged-${n%% *}" ;;
  "pr view"*) n=${a#pr view }; n=${n%% *}
    if [ -f "$FX/hold-on-view" ]; then
      echo "$(<"$FX/hold-on-view") until:owner since:2026-09-27T12:00:00Z fix pass started" >>"$st/holds"
      rm "$FX/hold-on-view"
    fi
    if [ -f "$FX/review-on-view" ]; then
      printf '2026-09-27T12:00:00Z\t%s\tfixing\t-\tfix lane started\n' "$(<"$FX/review-on-view")" >>"$st/reviews.tsv"
      rm "$FX/review-on-view"
    fi
    if [ -f "$FX/merged-$n" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}'
    else jq -n --arg h "$(head_of)" '{state: "OPEN", isDraft: false, isCrossRepository: false, headRefOid: $h,
      baseRefName: "main", author: {login: "me"}, mergeable: "MERGEABLE", autoMergeRequest: null}'; fi ;;
  *) echo "unexpected gh call: $a" >&2; exit 9 ;;
esac
STUB
  } >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
