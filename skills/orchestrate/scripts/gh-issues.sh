#!/usr/bin/env bash
# Issue-side list reads that work with or without GitHub GraphQL. Prints the JSON array that
# `gh issue list` / `gh pr list --json FIELDS` would print, so callers' jq stays unchanged. Each
# read tries the gh command first (GraphQL) and, when GitHub refuses it with a 403 that names
# GraphQL (Claude Code cloud sessions: "GitHub GraphQL is not available ..."), answers the same
# read over REST. Every call goes through gh-read.sh: bounded, typed, read-only, paced.
#
# Usage: gh-issues.sh issues     [--repo R] [--fields F] [--limit N] [--label L] [--since DATE]
#        gh-issues.sh prs-open   [--repo R] [--fields F] [--limit N]
#        gh-issues.sh prs-merged [--repo R] [--fields F] [--limit N] [--merged QUALIFIER]
#   common: [--tries N] [--budget SECONDS] (passed to gh-read.sh)
#   issues      open issues, pull requests excluded. --label: only issues carrying L. --since:
#               updated on or after DATE, newest update first. REST: GET /repos/R/issues
#               (items with a pull_request key dropped).
#   prs-open    open pull requests. REST: GET /repos/R/pulls?state=open.
#   prs-merged  merged pull requests; --merged is a search qualifier value such as ">=2026-01-01"
#               or ">2026-01-01T00:00:00Z". REST: GET /search/issues (at most 1000 results).
# --fields: comma-separated `gh --json` names (default number,title). Mapped over REST: number,
# title, body, labels ({name,color,description}), updatedAt, createdAt, state, url, author,
# assignees ({login}), comments ({author,body,createdAt}; one extra read per issue), mergedAt,
# headRefName, isDraft, closingIssuesReferences ({number}). Anything else is null over REST.
# closingIssuesReferences over REST: prs-open parses the PR body for GitHub's closing keywords
# (close[sd], fix(e[sd]), resolve[sd], optional colon, then #N); issues linked by hand in the
# sidebar, or from another repository, are not seen. prs-merged gives [] (callers already scan
# the body of merged PRs). REST pages hold 100 items; reads stop at --limit (default 300) or a
# page cap (limit/100 x2, at least 2, at most 20), noting a truncation on stderr.
# Env: ORCHESTRATE_GH_API=auto (default) | rest (skip the GraphQL attempt) | graphql (no
# fallback). After a GraphQL refusal, <state root>/gh-no-graphql makes later reads on this state
# root (PR side included) go straight to REST for 12 hours (orch_gh_api in _lib.sh).
# Exit: 0 ok | 2 usage | 3-9 gh-read.sh's typed failure (see gh-read.sh -h).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
# The caller's budget priority when it declared one (each caller runs this as a child).
caller_priority=${GH_BUDGET_PRIORITY:-}
orch_gh_priority normal
[[ -z "$caller_priority" ]] || orch_gh_priority "$caller_priority"

usage_end=$(($(grep -n '^set -euo pipefail' "$0" | cut -d: -f1 | sed -n 1p) - 1))
cmd=${1:-}
case "$cmd" in
  issues | prs-open | prs-merged) shift ;;
  -h | --help) sed -n "2,${usage_end}p" "$0"; exit 0 ;;
  -*) echo "gh-issues.sh: unknown argument: $cmd" >&2; exit 2 ;;
  *) sed -n "2,${usage_end}p" "$0" >&2; exit 2 ;;
esac
repo="" fields=number,title limit=300 label="" since="" merged="" ghr_opts=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --fields) fields=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --since) since=$2; shift 2 ;;
    --merged) merged=$2; shift 2 ;;
    --tries | --budget) ghr_opts+=("$1" "$2"); shift 2 ;;
    -h | --help) sed -n "2,${usage_end}p" "$0"; exit 0 ;;
    *) echo "gh-issues.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "gh-issues.sh: --limit must be a positive number" >&2; exit 2; }
api=$(orch_gh_api gh-issues.sh) || exit 2
repo=$(orch_repo "$repo")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ghr() { "$here/gh-read.sh" ${ghr_opts[@]+"${ghr_opts[@]}"} --json -- "$@"; }

# --- GraphQL first (gh issue list / gh pr list) ---------------------------------------------------
if [[ "$api" == graphql ]]; then
  case "$cmd" in
    issues)
      args=(issue list --repo "$repo" --state open --limit "$limit" --json "$fields")
      [[ -z "$label" ]] || args+=(--label "$label")
      [[ -z "$since" ]] || args+=(--search "updated:>=$since sort:updated-desc") ;;
    prs-open) args=(pr list --repo "$repo" --state open --limit "$limit" --json "$fields") ;;
    prs-merged)
      args=(pr list --repo "$repo" --state merged --limit "$limit" --json "$fields")
      [[ -z "$merged" ]] || args+=(--search "merged:$merged") ;;
  esac
  rc=0
  ghr "${args[@]}" 2>"$work/err" || rc=$?
  if ((rc == 0)); then exit 0; fi
  if ! orch_gh_refused "$rc" "$(cat "$work/err")"; then
    cat "$work/err" >&2
    exit "$rc"
  fi
fi

# --- REST ---------------------------------------------------------------------------------------
cap=$(((limit + 99) / 100 * 2))
((cap >= 2)) || cap=2
((cap <= 20)) || cap=20
uri() { jq -rn --arg s "$1" '$s | @uri'; }

# pages BASE_PATH JQ_ITEMS -> every page's items (JQ_ITEMS selects them from one page), one JSON
# array, at most $limit kept items, read until a short page, the limit or the page cap.
pages() {
  local base=$1 sel=$2 page=1 got raw n total=0
  echo '[]' >"$work/acc"
  while :; do
    got=$(ghr api "$base&per_page=100&page=$page") || return
    raw=$(jq "$sel | length" <<<"$got")
    jq -c "$sel" <<<"$got" >"$work/page"
    jq -c --slurpfile p "$work/page" --argjson lim "$limit" --argjson keep_prs "$keep_prs" \
      '(. + ($p[0] | map(select(.pull_request == null or $keep_prs))))[0:$lim]' "$work/acc" >"$work/acc.new"
    mv "$work/acc.new" "$work/acc"
    n=$(jq length "$work/acc")
    total=$((total + raw))
    if ((n >= limit || raw < 100)); then break; fi
    if ((page >= cap)); then
      echo "gh-issues.sh: stopped at the page cap ($cap pages, $total items read); the list may be incomplete" >&2
      break
    fi
    page=$((page + 1))
  done
  cat "$work/acc"
}

closes='[scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s*:?\\s+#(\\d+)") | {number: (.[0] | tonumber)}] | unique_by(.number)'
common='{number, title, body: (.body // ""), state: (.state // "open" | ascii_upcase), url: .html_url,
  author: {login: .user.login}, assignees: [(.assignees // [])[] | {login}],
  labels: [(.labels // [])[] | {name, color, description}], createdAt: .created_at, updatedAt: .updated_at}'
case "$cmd" in
  issues)
    keep_prs=false
    base="repos/$repo/issues?state=open"
    [[ -z "$label" ]] || base+="&labels=$(uri "$label")"
    [[ -z "$since" ]] || base+="&since=$(uri "$since")&sort=updated&direction=desc"
    items=$(pages "$base" '.')
    rows=$(jq -c "map($common)" <<<"$items")
    if [[ ",$fields," == *",comments,"* ]]; then
      # gh issue list reads comments in the same query; REST needs one read per issue.
      echo '{}' >"$work/comments"
      for n in $(jq -r '.[].number' <<<"$rows"); do
        c=$(ghr api "repos/$repo/issues/$n/comments?per_page=100") || exit
        jq -c --arg n "$n" --argjson c "$c" \
          '.[$n] = [$c[] | {author: {login: .user.login}, body, createdAt: .created_at}]' "$work/comments" >"$work/c.new"
        mv "$work/c.new" "$work/comments"
      done
      rows=$(jq -c --slurpfile c "$work/comments" 'map(.comments = $c[0][.number | tostring])' <<<"$rows")
    fi ;;
  prs-open)
    keep_prs=true
    items=$(pages "repos/$repo/pulls?state=open" '.')
    rows=$(jq -c "map($common + {headRefName: .head.ref, isDraft: .draft, mergedAt: .merged_at,
      closingIssuesReferences: ((.body // \"\") | $closes)})" <<<"$items") ;;
  prs-merged)
    keep_prs=true
    q="repo:$repo is:pr is:merged"
    [[ -z "$merged" ]] || q+=" merged:$merged"
    ((cap <= 10)) || cap=10   # search returns at most 1000 results
    items=$(pages "search/issues?q=$(uri "$q")&sort=updated&order=desc" '.items')
    rows=$(jq -c "map($common + {mergedAt: .pull_request.merged_at, closingIssuesReferences: []})" <<<"$items") ;;
esac
jq -c --arg f "$fields" '($f | split(",")) as $k | map(. as $r | reduce $k[] as $x ({}; .[$x] = $r[$x]))' <<<"$rows"
