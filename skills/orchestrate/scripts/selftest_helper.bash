# Helpers shared by the selftest-*.bats suites. Each suite loads this file from setup().
fp() { "$SCRIPTS/fingerprint.sh" --dir "$REPO" "$@"; }

# --- PR takeover: claims and intake -------------------------------------------------------
claim() { ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" "$SCRIPTS/pr-claim.sh" "$@" --repo o/r --pr 7; }

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

intake() {
  cd "$REPO"
  ORCHESTRATE_AUTHOR=octocat ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 \
    "$SCRIPTS/pr-intake.sh" --repo o/r --owner ME "$@"
}

# --- codex-lane-run.sh cross-lane guard ---
runner_env() {
  RUNNER="$SCRIPTS/../../../bin/codex-lane-run.sh"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
out=""; while (($#)); do [[ $1 == --output-last-message ]] && out=$2; shift; done
spec=$(cat); printf 'saw:%s\n' "$(printf '%s\n' "$spec" | sed -n 2p)" >"$out"
SH
  chmod +x "$FAKEBIN/codex"
  OTHER="$BATS_TEST_TMPDIR/other"; mkdir -p "$OTHER"
  RUNDIR="$BATS_TEST_TMPDIR/run"; mkdir -p "$RUNDIR"
}

run_lane() { PATH="$FAKEBIN:$PATH" HOME="$BATS_TEST_TMPDIR/home" "$RUNNER" --model gpt-6-luna --spec "$1" --final "$RUNDIR/final.md" --log "$RUNDIR/codex.jsonl" --cd "$REPO" --poll 1 3>&-; }   # fd 3 closed: see selftest-lanes.bats teardown

WAITER() { "$SCRIPTS/../../../bin/codex-lane-wait.sh" "$@"; }

# --- campaign scripts: readiness, merge, main health, issues, lanes, device lock ---------------

# gh stub that answers by subcommand from fixture files and records every call. It reads its
# arguments with test_helper.bash's gh_stub_args, as stub_gh_routes does: `--include` and `-i` are
# dropped from `gh api` calls, so a read through gh-read.sh matches the same routes as a direct gh
# call, and $FX/calls logs the call without them (#166). A new suite should start from
# test_helper.bash's stub_gh_routes instead of another case statement.
stub_gh_router() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  {
    gh_stub_header
    cat <<'STUB'
gh_stub_args "$@"
echo "$a" >>"$FX/calls"
case "$a" in
  "api user") echo '{"login":"me"}' ;;
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) [ -f "$FX/rules-fails" ] && { echo "HTTP 403: Resource not accessible" >&2; exit 1; }; cat "$FX/rules.json" ;;
  "api repos/o/r/branches/"*) [ -f "$FX/branch-fails" ] && { echo "HTTP 403" >&2; exit 1; }; cat "$FX/branch.json" ;;
  *graphql*) # threads.json maps PR number -> thread nodes, "null" (no data), "more" (a next page
    # without a cursor) or {"pages": [[nodes], [nodes], ...]} (served through real cursors c1, c2, ...)
    [ -f "$FX/graphql-fails" ] && exit 1
    if [[ "$*" == *"cursor=c"* ]]; then
      n=$(printf '%s\n' "$*" | sed -nE 's/.*-F pr=([0-9]+).*/\1/p')
      c=$(printf '%s\n' "$*" | sed -nE 's/.*-f cursor=c([0-9]+).*/\1/p')
      echo "page $n $c" >>"$FX/pages"
      jq -n --argjson t "$(cat "$FX/threads.json")" --arg n "$n" --argjson c "$c" '$t[$n].pages as $p
        | {data: {repository: {pullRequest: {reviewThreads: {pageInfo: {hasNextPage: (($c + 1) < ($p | length)),
           endCursor: ("c" + (($c + 1) | tostring))}, nodes: $p[$c]}}}}}'
    else
      jq -n --argjson t "$(cat "$FX/threads.json")" --args '{data: {repository: (reduce $ARGS.positional[] as $n ({};
        .["p" + $n] = ($t[$n] // [] | if . == "null" then null
          elif . == "more" then {reviewThreads: {pageInfo: {hasNextPage: true}, nodes: []}}
          elif type == "object" then {reviewThreads: {pageInfo: {hasNextPage: ((.pages | length) > 1), endCursor: "c1"}, nodes: .pages[0]}}
          else {reviewThreads: {pageInfo: {hasNextPage: false}, nodes: .}} end)))}}' \
        $(printf '%s\n' "$*" | grep -oE ' p[0-9]+:' | tr -dc '0-9\n')
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
  "pr view"*) if [ -s "$FX/view-fails" ] && [ "$(cat "$FX/view-fails")" -gt 0 ]; then
      echo $(($(cat "$FX/view-fails") - 1)) >"$FX/view-fails"; echo "HTTP 502" >&2; exit 1; fi
    if [ -f "$FX/merged" ]; then cat "$FX/pr-merged.json"
    elif [ -f "$FX/queued" ]; then jq '.autoMergeRequest = {"enabledAt": "2026-09-27T12:00:00Z"}' "$FX/pr.json"
    elif [ -f "$FX/remote-head" ]; then jq --arg h "$(cat "$FX/remote-head")" '.headRefOid = $h' "$FX/pr.json"
    else cat "$FX/pr.json"; if [ -f "$FX/race" ]; then rm "$FX/race"; cp "$FX/race-head" "$FX/remote-head"; fi; fi ;;
  "pr list"*merged*) cat "$FX/prs-merged.json" ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "api repos/o/r/actions/runs?"*) jq '{workflow_runs: map({name: .workflowName, status, conclusion, head_sha: .headSha, id: .databaseId, created_at: .createdAt})}' "$FX/runs.json" ;;
  "issue list"*--label*) cat "$FX/pause.json" ;;
  "issue list"*) cat "$FX/issues.json" ;;
  "issue view"*) # issue.json plus what earlier closes changed; $FX/view-fails counts down failures
    if [ -s "$FX/view-fails" ] && [ "$(cat "$FX/view-fails")" -gt 0 ]; then
      echo $(($(cat "$FX/view-fails") - 1)) >"$FX/view-fails"; echo "HTTP 502" >&2; exit 1; fi
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

pr_row() { # number author draft fork mergeable checks-json [labels-json]
  jq -cn --argjson n "$1" --arg a "$2" --argjson d "$3" --argjson f "$4" --arg m "$5" --argjson c "$6" --argjson l "${7:-[]}" \
    '{number:$n,author:{login:$a},isDraft:$d,isCrossRepository:$f,baseRefName:"main",headRefOid:("abcdef0123456789"+($n|tostring)),mergeable:$m,labels:$l,statusCheckRollup:$c}'
}

OKC='[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]'

check() { # name conclusion workflow startedAt [run] [job] [typename]
  jq -cn --arg n "$1" --arg c "$2" --arg w "$3" --arg t "$4" --arg r "${5:-}" --arg j "${6:-}" --arg ty "${7:-CheckRun}" \
    '{__typename: $ty, name: $n, conclusion: $c, workflowName: $w, startedAt: $t}
     + (if $r == "" then {} else {detailsUrl: ("https://github.com/o/r/actions/runs/\($r)" + (if $j == "" then "" else "/job/\($j)" end))} end)'
}

verdict_of() { # checks... -> the verdict and detail of one PR built from them
  printf '%s\n' "$@" | jq -s . >"$FX/checks.json"
  pr_row 1 me false false MERGEABLE "$(cat "$FX/checks.json")" | jq -s . >"$FX/prs.json"
  "$SCRIPTS/pr-ready.sh" --repo o/r --no-threads 2>/dev/null | cut -f2,6
}

pr_rows() { # from to author draft fork mergeable checks-json: pr_row for each number from..to
  # (counting down when from > to), from one jq instead of one per row
  jq -cn --argjson a "$1" --argjson b "$2" --arg au "$3" --argjson d "$4" --argjson f "$5" --arg m "$6" --argjson c "$7" \
    '(if $a <= $b then range($a; $b + 1) else range($a; $b - 1; -1) end)
     | {number:.,author:{login:$au},isDraft:$d,isCrossRepository:$f,baseRefName:"main",headRefOid:("abcdef0123456789"+tostring),mergeable:$m,labels:[],statusCheckRollup:$c}'
}

ready_prs() { # n: n mergeable, green PRs by me
  if (($1 > 0)); then pr_rows 1 "$1" me false false MERGEABLE "$OKC"; fi | jq -s . >"$FX/prs.json"
}

merge_fixture() {
  stub_gh_router
  echo '{"state":"OPEN","isDraft":false,"isCrossRepository":false,"headRefOid":"abcdef0123456789abcdef0123456789abcdef01","author":{"login":"me"},"mergeable":"MERGEABLE"}' >"$FX/pr.json"
  echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}' >"$FX/pr-merged.json"
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
}

# The readiness row for the admin tests: build passes, "sim" failed (a classified flake).
sim_fails() { pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"; }

run_json() { # workflow status conclusion sha id createdAt
  jq -cn --arg w "$1" --arg s "$2" --arg c "$3" --arg h "$4" --argjson id "$5" --arg t "$6" \
    '{workflowName:$w,status:$s,conclusion:$c,headSha:$h,databaseId:$id,createdAt:$t}'
}

# n issues titled the same, numbered 1..n, plus optional extra JSON rows.
dupes_fixture() {
  jq -n --argjson n "$1" --argjson extra "${2:-[]}" \
    '[range(1; $n + 1) | {number: ., title: "Fix shared device session recovery failure"}] + $extra' >"$FX/issues.json"
}

DIVERSE='[{"number":901,"title":"Crash when the keyboard opens on tablet"},
          {"number":902,"title":"Crash when keyboard opens on tablets"},
          {"number":903,"title":"Login screen shows stale avatar image"},
          {"number":904,"title":"Login screen shows a stale avatar"}]'

# --- validation receipts ---------------------------------------------------------------------
val() { ORCHESTRATE_VALIDATE_DIR="$BATS_TEST_TMPDIR/store" "$SCRIPTS/validate.sh" "$@" --dir "$REPO"; }
