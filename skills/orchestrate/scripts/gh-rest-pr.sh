#!/usr/bin/env bash
# REST reads for the PR side, in the JSON shapes `gh pr list/view --json ...` gives, so callers keep
# their jq programs when GraphQL is refused (Claude Code cloud sessions answer every GraphQL call,
# `gh pr list` and `gh pr view` included, with HTTP 403). Read-only; every call goes through
# gh-read.sh (bounded, typed, paced by gh-budget.sh when that is on).
#
# Usage: gh-rest-pr.sh list    [--repo OWNER/REPO] [--limit N] [--asc]
#        gh-rest-pr.sh view    [--repo OWNER/REPO] --pr N [--checks]
#        gh-rest-pr.sh rollup  [--repo OWNER/REPO] --sha SHA
#        gh-rest-pr.sh threads [--repo OWNER/REPO] --pr N
#        gh-rest-pr.sh thread-nodes [--repo OWNER/REPO] --pr N
#        gh-rest-pr.sh files   [--repo OWNER/REPO] --pr N
#        gh-rest-pr.sh review  [--repo OWNER/REPO] --pr N
#   list     open PRs, newest first (--asc: oldest first), at most --limit (default 300), from
#            GET pulls?state=open in pages of 100: number title body state author{login}
#            isDraft isCrossRepository baseRefName headRefName headRefOid labels createdAt
#            updatedAt url closingIssuesReferences, with mergeable "UNKNOWN" and an empty
#            statusCheckRollup (the list endpoint carries neither; use view --checks).
#   view     one PR (GET pulls/<n>) in the same shape, with mergeable read (true MERGEABLE, false
#            CONFLICTING, null UNKNOWN) and state OPEN|CLOSED|MERGED; --checks adds its head's
#            statusCheckRollup (see rollup).
#   rollup   the statusCheckRollup of a commit: GET commits/<sha>/check-runs as CheckRun items
#            (name, status, conclusion upper-cased, startedAt, detailsUrl, workflowName) plus
#            GET commits/<sha>/status as StatusContext items (context, state, targetUrl,
#            createdAt). workflowName comes from GET actions/runs?head_sha=<sha>, read only when a
#            check's details URL names an Actions run; a run it does not list leaves it "".
#   threads  the number of unresolved, current review threads, from GET
#            pulls/<n>/ccr/review_threads (all pages). That route's response shape is not
#            documented: a list of threads, or an object holding one under threads, review_threads,
#            reviewThreads, nodes or data, each thread with isResolved/is_resolved/resolved and
#            optionally isOutdated/is_outdated/outdated (absent: current). A thread without a
#            resolved flag, or any other shape, is unreadable (exit 3), never "0".
#   thread-nodes  the PR as the GraphQL pull request node thread-sweep.sh classifies: {number,
#            commits{nodes[{commit{oid}}]}, reviewThreads{pageInfo{hasNextPage:false}, nodes[{id,
#            isResolved, isOutdated, starter{nodes[{author{login},url}]}, latest{totalCount,
#            nodes[{author{login},body}]}, comments{nodes[{body}]} (the last 100)}]}}. Flags come
#            from ccr/review_threads as in threads; bodies and authors from GET pulls/<n>/comments,
#            commits from GET pulls/<n>/commits (neither is read when the PR has no thread). A
#            thread is tied to its comments by a comment id it carries (root_comment_id,
#            comment_id or first_comment_id, camelCase alike, or its first comment's
#            databaseId/database_id/id); its node id is the REST id of the thread's first comment,
#            the id POST pulls/<n>/ccr/comments/<id>/resolve takes. A thread with no comment id,
#            or one naming no comment of the PR, is unreadable (exit 3).
#   files   the changed files, [{path}], from GET pulls/<n>/files.
#   review   the last review, {state, commit} (both null when there is none), from GET
#            pulls/<n>/reviews.
# closingIssuesReferences over REST is parsed from the body: "close(s|d) / fix(es|ed) /
# resolve(s|d) #N" (or OWNER/REPO#N naming this repository). GraphQL also counts issues linked by
# hand in the Development sidebar; REST cannot see those. This script never tries GraphQL; when to
# use it is the callers' choice, made with orch_gh_api / orch_gh_refused (_lib.sh).
# Exit: 0 ok | 2 usage | 3 unreadable (the gh-read.sh line or the reason is on stderr)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { sed -n '2,51p' "$0"; }
case "${1:-}" in -h | --help) usage; exit 0 ;; -*) echo "gh-rest-pr.sh: unknown argument: $1" >&2; exit 2 ;; esac
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" limit=300 asc=no pr="" sha="" checks=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --asc) asc=yes; shift ;;
    --pr) pr=$2; shift 2 ;;
    --sha) sha=$2; shift 2 ;;
    --checks) checks=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "gh-rest-pr.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  list) [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "gh-rest-pr.sh: --limit must be a positive number" >&2; exit 2; } ;;
  view | threads | thread-nodes | files | review) [[ "$pr" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; } ;;
  rollup) [[ "$sha" =~ ^[0-9a-fA-F]+$ ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
repo=$(orch_repo "$repo")

ghr() { "$here/gh-read.sh" --json -- "$@"; }
unreadable() { echo "gh-rest-pr: $*" >&2; exit 3; }

# The `gh pr list --json` shape of one REST pull request object.
# shellcheck disable=SC2016  # jq variables, not shell expansions
shape='def pr_shape($repo):
  {number, title: (.title // ""), body: (.body // ""),
   state: (if .merged_at != null then "MERGED" else ((.state // "open") | ascii_upcase) end),
   author: {login: (if (.user.type // "") == "Bot" then "app/" + ((.user.login // "") | sub("\\[bot\\]$"; ""))
                    else (.user.login // "") end)},
   isDraft: (.draft // false),
   isCrossRepository: (((.head.repo // {}).full_name // null) != ((.base.repo // {}).full_name // $repo)),
   baseRefName: .base.ref, headRefName: .head.ref, headRefOid: .head.sha,
   labels: [(.labels // [])[] | {name}],
   createdAt: .created_at, updatedAt: .updated_at, url: .html_url,
   mergeable: (if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
   statusCheckRollup: [],
   closingIssuesReferences: ([(.body // "")
       | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\\s+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]+)")
       | select(.[0] == null or (.[0] | ascii_downcase) == ($repo | ascii_downcase))
       | {number: (.[1] | tonumber)}] | unique_by(.number))};'

list_prs() {
  local rows='[]' page=1 out n m order=""
  [[ "$asc" == no ]] || order="&sort=created&direction=asc"
  while :; do
    out=$(ghr api "repos/$repo/pulls?state=open&per_page=100&page=$page$order") || exit 3
    # One jq per page (#174): the page's length, then the rows so far and their count, tab-separated.
    out=$(jq -r --slurpfile rows <(printf '%s\n' "$rows") --argjson lim "$limit" --arg repo "$repo" "$shape"'
      if type != "array" then "-" else length as $n
      | ($rows[0] + map(pr_shape($repo)))[:$lim] | "\($n)\t\(length)\t\(tojson)" end' <<<"$out")
    [[ "$out" != "-" ]] || unreadable "pulls page $page is not a list"
    IFS=$'\t' read -r n m rows <<<"$out"
    ((n == 100 && m < limit)) || break
    page=$((page + 1))
  done
  printf '%s\n' "$rows"
}

# rollup SHA [PR]: SHA's statusCheckRollup items, or, given a PR row, that row with them as its
# statusCheckRollup. Two jq (#174): one reads the check runs and says whether any names an Actions
# run (actions/runs is read only then), one builds the answer.
rollup() {
  local s=$1 row=${2:-null} cr st runs='{}'
  cr=$(ghr api --paginate "repos/$repo/commits/$s/check-runs?per_page=100") || exit 3
  cr=$(jq -sc '[.[] | (.check_runs // [])[]]
    | (try any(.[]; (.details_url // "") | test("/actions/runs/[0-9]+")) catch false), .' <<<"$cr") ||
    unreadable "check runs of $s are malformed"
  st=$(ghr api "repos/$repo/commits/$s/status?per_page=100") || exit 3
  if [[ "${cr%%$'\n'*}" == true ]]; then
    runs=$(ghr api "repos/$repo/actions/runs?head_sha=$s&per_page=100") || exit 3
  fi
  jq -nc --slurpfile cr <(printf '%s\n' "${cr#*$'\n'}") --slurpfile st <(printf '%s\n' "$st") \
    --slurpfile runs <(printf '%s\n' "$runs") --slurpfile row <(printf '%s\n' "$row") '
    $cr[0] as $cr | $st[0] as $st | $runs[0] as $runs |
    (($runs.workflow_runs // []) | map({key: (.id | tostring), value: (.name // "")}) | from_entries) as $wf
    | [$cr[] | ((.details_url // "") | (capture("/actions/runs/(?<r>[0-9]+)") // {}) | .r) as $r
       | {__typename: "CheckRun", name, status: ((.status // "") | ascii_upcase),
          conclusion: ((.conclusion // "") | ascii_upcase), startedAt: (.started_at // ""),
          detailsUrl: (.details_url // .html_url // ""),
          workflowName: (if $r == null then "" else ($wf[$r] // "") end)}]
    + [($st.statuses // [])[] | {__typename: "StatusContext", context, state: ((.state // "") | ascii_upcase),
         targetUrl: (.target_url // ""), createdAt: (.created_at // .updated_at // "")}]
    | . as $c | if $row[0] == null then $c else $row[0] | .statusCheckRollup = $c end'
}

view_pr() {
  local out one
  out=$(ghr api "repos/$repo/pulls/$pr") || exit 3
  if [[ "$checks" == no ]]; then
    jq -c --arg repo "$repo" "$shape"' if type == "object" and has("number") then pr_shape($repo)
      else error("not a pull request") end' <<<"$out" 2>/dev/null || unreadable "PR $pr: not a pull request object"
    return
  fi
  # The row and its head in one jq; rollup sets the row's statusCheckRollup in its own.
  one=$(jq -r --arg repo "$repo" "$shape"' if type == "object" and has("number") then pr_shape($repo)
    | tojson, (.headRefOid | tostring) else error("not a pull request") end' <<<"$out" 2>/dev/null) ||
    unreadable "PR $pr: not a pull request object"
  rollup "${one#*$'\n'}" "${one%%$'\n'*}"
}

# The ccr/review_threads parsing threads and thread-nodes share: every thread of every page, each
# with its resolved (_r, checked) and outdated (_o, absent: false) flags.
# shellcheck disable=SC2016  # jq variables, not shell expansions
tparse='def flag($a; $b; $c): if has($a) then .[$a] elif has($b) then .[$b] elif has($c) then .[$c] else null end;
  def list: if type == "array" then .
    elif type == "object" then
      ([.threads, .review_threads, .reviewThreads, .nodes, .data] | map(select(. != null)) | first // null)
      | if type == "object" and has("nodes") then .nodes else . end
      | if type == "array" then . else error("no thread list") end
    else error("no thread list") end;
  [.[] | list[]
   | if type != "object" then error("thread is not an object") else . end
   | . + {_r: flag("isResolved"; "is_resolved"; "resolved"), _o: (flag("isOutdated"; "is_outdated"; "outdated") // false)}
   | if (._r | type) != "boolean" then error("thread without a resolved flag") else . end]'

threads() {
  local out
  out=$(ghr api --paginate "repos/$repo/pulls/$pr/ccr/review_threads") || exit 3
  jq -se "$tparse"' | map(select((._r | not) and (._o | not))) | length' <<<"$out" 2>/dev/null ||
    unreadable "PR $pr: review threads in an unrecognised shape"
}

thread_nodes() {
  local out cm='[]' co='[]'
  out=$(ghr api --paginate "repos/$repo/pulls/$pr/ccr/review_threads") || exit 3
  out=$(jq -sc "$tparse" <<<"$out" 2>/dev/null) || unreadable "PR $pr: review threads in an unrecognised shape"
  if [[ "$out" != "[]" ]]; then
    cm=$(ghr api --paginate "repos/$repo/pulls/$pr/comments?per_page=100") || exit 3
    co=$(ghr api --paginate "repos/$repo/pulls/$pr/commits?per_page=100") || exit 3
  elif [[ "$pr" =~ ^(0|[1-9][0-9]{0,14})$ ]]; then
    # No thread: the node below with nothing in it, without a jq (#174).
    printf '{"number":%s,"commits":{"nodes":[]},"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}\n' "$pr"
    return
  fi
  jq -nc --argjson n "$pr" --slurpfile t <(printf '%s\n' "$out") --slurpfile cm <(printf '%s\n' "$cm") --slurpfile co <(printf '%s\n' "$co") '
    def num: if type == "number" then . elif type == "string" and test("^[0-9]+$") then tonumber else null end;
    def cmts: if type == "array" then . elif type == "object" and (.nodes | type) == "array" then .nodes else [] end;
    def login: (.user.login // "") | sub("\\[bot\\]$"; "");
    def items: if type == "array" then .[] else error("not a list") end;
    [$cm[] | items] as $all
    | {number: $n, commits: {nodes: [$co[] | items | {commit: {oid: .sha}}]},
       reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [$t[0][]
         | ([.root_comment_id, .rootCommentId, .comment_id, .commentId, .first_comment_id, .firstCommentId,
             ((.comments // null) | cmts | (.[0] // {}) | (.databaseId // .database_id // .id))]
            | map(num | select(. != null)) | first) as $cid
         | (if $cid == null then error("thread without a comment id") else ($all | map(select(.id == $cid)) | first) end) as $m
         | (if $m == null then error("thread names no comment of the PR") else ($m.in_reply_to_id // $m.id) end) as $root
         | ([$all[] | select((.in_reply_to_id // .id) == $root)] | sort_by(.created_at // "", .id)) as $c
         | {id: ($root | tostring), isResolved: ._r, isOutdated: ._o,
            starter: {nodes: [{author: {login: ($c[0] | login)}, url: ($c[0].html_url // "-")}]},
            latest: {totalCount: ($c | length), nodes: [{author: {login: ($c[-1] | login)}, body: ($c[-1].body // "")}]},
            comments: {nodes: [$c[-100:][] | {body: (.body // "")}]}}]}}' 2>/dev/null ||
    unreadable "PR $pr: review threads could not be tied to their comments"
}

files() {
  local out
  out=$(ghr api --paginate "repos/$repo/pulls/$pr/files?per_page=100") || exit 3
  jq -sc '[.[][] | {path: .filename}]' <<<"$out" 2>/dev/null || unreadable "PR $pr: files are malformed"
}

review() {
  local out
  out=$(ghr api --paginate "repos/$repo/pulls/$pr/reviews?per_page=100") || exit 3
  jq -sc '(add // []) | last | {state: (if . == null then null else .state end),
    commit: (if . == null then null else .commit_id end)}' <<<"$out" 2>/dev/null || unreadable "PR $pr: reviews are malformed"
}

case "$cmd" in
  list) list_prs ;;
  view) view_pr ;;
  rollup) rollup "$sha" ;;
  threads) threads ;;
  thread-nodes) thread_nodes ;;
  files) files ;;
  review) review ;;
esac
