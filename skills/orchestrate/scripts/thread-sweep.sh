#!/usr/bin/env bash
# Find review threads that already carry an answer and resolve them from the local orchestrator.
# Cloud repair sessions can reply on a thread but cannot resolve it (no GraphQL; the REST resolve
# route is denied as an external write), so they reply and the orchestrator resolves afterwards
# (see ../thread-resolution.md).
#
# Usage: thread-sweep.sh scan [--pr N] [--summary] [--repo OWNER/REPO]
#        thread-sweep.sh resolve --pr N [--dry-run] [--repo OWNER/REPO]
#   scan     read-only. One TSV row per unresolved, current (not outdated) review thread on every
#            open PR, or on PR N:   pr  thread-id  answer  ref  url
#            answer: issue  the last reply links an issue (`#N` or an issues/N URL; not the PR itself)
#                  | fix    the last reply names a commit of the PR (a 7-40 hex sha or a commit URL)
#                  | stalled  our own account replied last, after the PR's head commit, and the
#                           reply names neither: an "agreed, proposed fix" reply with no push (#209).
#                           A reply that starts "Disagree" is a stated disagreement and stays open.
#                           Our account is ORCHESTRATE_SELF_LOGIN, else `gh api user`, read only
#                           when such a reply exists (a failed read leaves the thread open)
#                  | open   no reply yet, the thread's starter spoke last, or the reply names neither
#            Last line, on stderr (with --summary, the only line, on stdout):
#              threads unresolved=<n> answered=<n> resolve-now=#a,#b|- repair=#c|- [stalled=#d,...]
#            resolve-now: every unresolved thread on the PR is answered, so resolving them is all it
#            needs (not a repair target). repair: at least one thread is open or stalled. stalled
#            (only when there is one): PRs with a stalled thread, which no session is still working
#            on: send a repair, do not wait. Over GraphQL a PR with more than 100 review threads is
#            never resolve-now.
#   resolve  resolve each answered thread on PR N with thread-resolve.sh (no new reply: the answer
#            is already on the thread); open and stalled threads are left alone. Prints thread-resolve.sh's
#            lines, then "pr=<n> resolved=<n> open=<n> failed=<n>".
# GraphQL first; where GitHub refuses it (Claude Code cloud sessions) the same scan runs over REST
# (orch_gh_api / orch_gh_refused in _lib.sh, ORCHESTRATE_GH_API=auto|rest|graphql): the open PRs
# from gh-rest-pr.sh list, each PR's threads from gh-rest-pr.sh thread-nodes (ccr/review_threads,
# pulls/<n>/comments, pulls/<n>/commits; every page, so no 100-thread cap). Same answers; the
# thread-id column is then the REST id of the thread's first comment, which thread-resolve.sh
# resolves over REST.
# Exit: 0 ok | 2 usage | 4 a read failed | 5 a resolve failed (rerun finishes it) |
#       9 a resolve's outcome is unknown (rerun reconciles).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { orch_usage; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" pr="" summary=no dry=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --summary) summary=yes; shift ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "thread-sweep.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  scan) [[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; } ;;
  resolve) [[ "$pr" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; } ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
api=$(orch_gh_api thread-sweep.sh) || exit 2
repo=$(orch_repo "$repo")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fields='number commits(last:100){nodes{commit{oid committedDate}}}
  reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved isOutdated
    starter: comments(first:1){nodes{author{login} url}}
    latest: comments(last:1){totalCount nodes{author{login} body createdAt}}}}'
# prs_graphql -> a JSON array of pull request nodes (every open PR, or PR $pr). A failed read
# returns gh-read.sh's exit code, with its stderr in $work/err.
prs_graphql() {
  local page cursor="" first=yes all="[]" args
  if [[ -n "$pr" ]]; then
    page=$("$here/gh-read.sh" --json --tries 3 -- api graphql -F owner="${repo%%/*}" -F name="${repo##*/}" \
      -F pr="$pr" -f query="query(\$owner:String!,\$name:String!,\$pr:Int!){repository(owner:\$owner,name:\$name){
        pullRequest(number:\$pr){$fields}}}" 2>"$work/err") || return
    jq -ce '.data.repository.pullRequest | select(.reviewThreads.nodes | type == "array") | [.]' <<<"$page"
    return
  fi
  while [[ "$first" == yes || -n "$cursor" ]]; do
    first=no
    args=(-F owner="${repo%%/*}" -F name="${repo##*/}" -f query="query(\$owner:String!,\$name:String!,\$cursor:String){
      repository(owner:\$owner,name:\$name){pullRequests(states:OPEN,first:25,after:\$cursor){
        pageInfo{hasNextPage endCursor} nodes{$fields}}}}")
    [[ -z "$cursor" ]] || args+=(-f cursor="$cursor")
    page=$("$here/gh-read.sh" --json --tries 3 -- api graphql "${args[@]}" 2>"$work/err") || return
    jq -e '.data.repository.pullRequests.nodes | type == "array"' >/dev/null 2>&1 <<<"$page" || return 1
    all=$(jq -c --slurpfile p <(printf '%s\n' "$page") '. + $p[0].data.repository.pullRequests.nodes' <<<"$all")
    cursor=$(jq -r '.data.repository.pullRequests.pageInfo | if .hasNextPage then (.endCursor // "") else "" end' <<<"$page")
  done
  echo "$all"
}

# prs_rest -> the same array over REST: the open PRs (gh-rest-pr.sh list), then each one's threads
# with their comments and commits (gh-rest-pr.sh thread-nodes).
prs_rest() {
  local nums n
  if [[ -n "$pr" ]]; then nums=$pr
  else nums=$("$here/gh-rest-pr.sh" list --repo "$repo" 2>/dev/null | jq -r '.[].number') || return 1; fi
  : >"$work/nodes"
  for n in $nums; do
    "$here/gh-rest-pr.sh" thread-nodes --repo "$repo" --pr "$n" 2>/dev/null >>"$work/nodes" || return 1
  done
  jq -sc . "$work/nodes"
}

# prs_json -> the array: GraphQL first (orch_gh_api), REST when GitHub refuses GraphQL.
prs_json() {
  local rc=0 out
  if [[ "$api" == graphql ]]; then
    out=$(prs_graphql) || rc=$?
    if ((rc == 0)); then echo "$out"; return; fi
    orch_gh_refused "$rc" "$(cat "$work/err")" || return 1
  fi
  prs_rest
}

prs=$(prs_json) || {
  echo "thread-sweep: review threads${pr:+ of PR $pr} could not be read" >&2
  [[ "$summary" == no ]] || echo "threads unknown"
  exit 4
}

# The jq definitions both passes below share. epoch: an ISO time as epoch seconds, null when absent
# or unparsable. head: the epoch of the PR's last commit (0 without one). late: the thread's last
# reply is not its starter's and came after the head commit, so whoever wrote it pushed nothing since.
defs='
  def epoch: if type == "string" then (try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) else null end;
  def head: ((.commits.nodes // []) | last | .commit.committedDate // null | epoch) // 0;
  def late($h): (.latest.nodes[0] // {}) as $l
    | (.latest.totalCount // 0) >= 2 and (($l.author.login // "") != (.starter.nodes[0].author.login // ""))
      and (($l.createdAt | epoch) // -1) > $h;
  def current: .reviewThreads.nodes[] | select((.isResolved | not) and (.isOutdated | not));'

# Our own login, read only when some current thread has a late reply: an agreed but unpushed reply
# is ours, and a reply from anyone else is not a stalled session of ours.
self=""
if jq -e "$defs"' any(.[]; head as $h | any(current; late($h)))' >/dev/null 2>&1 <<<"$prs"; then
  self=${ORCHESTRATE_SELF_LOGIN:-}
  if [[ -z "$self" ]]; then
    self=$("$here/gh-read.sh" --json --tries 3 -- api user 2>/dev/null | jq -r '.login // empty' 2>/dev/null) || self=""
  fi
  self=${self%\[bot\]}
fi

# One TSV row per unresolved, current thread, then a "TRUNC<TAB>n" row per PR whose threads did
# not fit in one page.
rows=$(jq -r --arg self "$self" "$defs"'
  def answer($n; $oids; $h):
    (.latest.nodes[0] // {}) as $l
    | if (.latest.totalCount // 0) < 2 or (($l.author.login // "") == (.starter.nodes[0].author.login // "")) then ["open", "-"]
      else ($l.body // "") as $b
      | ([$b | (scan("(?:^|[^\\w&/])#([0-9]+)"), scan("/issues/([0-9]+)")) | .[0]
          | select(. != ($n | tostring))] | first) as $iss
      | ([$b | scan("\\b[0-9a-fA-F]{7,40}\\b") | ascii_downcase | . as $s
          | select(any($oids[]; startswith($s)))] | first) as $sha
      | if $iss then ["issue", "#\($iss)"] elif $sha then ["fix", $sha[0:12]]
        elif $self != "" and ($l.author.login // "") == $self and late($h)
          and ($b | test("^[\\s*_>]*disagree"; "i") | not) then ["stalled", "-"]
        else ["open", "-"] end
      end;
  .[] | .number as $n | [(.commits.nodes // [])[] | .commit.oid] as $oids | head as $h
  | ((current | [$n, .id] + answer($n; $oids; $h) + [.starter.nodes[0].url // "-"] | @tsv),
     (select(.reviewThreads.pageInfo.hasNextPage) | "TRUNC\t\($n)"))' <<<"$prs")

summary_line=$(awk -F'\t' '
  $1 == "TRUNC" { trunc[$2] = 1; next }
  NF >= 5 { u++; if (!($1 in seen)) { seen[$1] = 1; order[++k] = $1 }
            if ($3 == "open" || $3 == "stalled") open[$1]++; else a++
            if ($3 == "stalled" && !($1 in st)) { st[$1] = 1; sl = sl (sl == "" ? "" : ",") "#" $1 } }
  END {
    now = ""; rep = ""
    for (i = 1; i <= k; i++) { p = order[i]
      if (open[p] > 0 || (p in trunc)) rep = rep (rep == "" ? "" : ",") "#" p
      else now = now (now == "" ? "" : ",") "#" p }
    for (p in trunc) if (!(p in seen)) rep = rep (rep == "" ? "" : ",") "#" p
    printf "threads unresolved=%d answered=%d resolve-now=%s repair=%s%s\n", u, a, (now == "" ? "-" : now), (rep == "" ? "-" : rep), (sl == "" ? "" : " stalled=" sl)
  }' <<<"$rows")

if [[ "$cmd" == scan ]]; then
  if [[ "$summary" == yes ]]; then echo "$summary_line"; exit 0; fi
  awk -F'\t' '$1 != "TRUNC" && NF >= 5' <<<"$rows"
  echo "$summary_line" >&2
  exit 0
fi

# ---- resolve -----------------------------------------------------------------------------------
resolved=0 open=0 failed=0 rc=0
while IFS=$'\t' read -r n id answer _ref _url; do
  [[ "$n" != TRUNC && -n "$id" ]] || continue
  if [[ "$answer" == open || "$answer" == stalled ]]; then open=$((open + 1)); continue; fi
  args=(--repo "$repo" --pr "$pr" --thread "$id")
  [[ "$dry" == no ]] || args+=(--dry-run)
  r=0
  "$here/thread-resolve.sh" "${args[@]}" </dev/null || r=$?
  case "$r" in
    0) resolved=$((resolved + 1)) ;;
    9) failed=$((failed + 1)); rc=9 ;;
    *) failed=$((failed + 1)); ((rc == 9)) || rc=5 ;;
  esac
done <<<"$rows"
echo "pr=$pr resolved=$resolved open=$open failed=$failed"
exit "$rc"
