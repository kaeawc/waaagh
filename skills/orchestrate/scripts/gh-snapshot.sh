#!/usr/bin/env bash
# One GraphQL snapshot per pass of every open PR, instead of per-PR `gh pr view` / compare /
# reviews calls: head SHA, draft, the head commit's check roll-up, and the last review's state and
# commit. One call per 100 PRs. Each row is cached per head SHA, so a consumer can skip per-PR work
# for a PR whose head, roll-up and review are unchanged since the previous snapshot.
#
# Usage: gh-snapshot.sh [--repo OWNER/REPO] [--limit N] [--json]
#   --limit  open PRs to read at most (default 300, oldest first)
#   --json   print the rows as one JSON array instead of lines
# Output, one line per open PR:
#   pr <n> head=<sha> draft=<yes|no> rollup=<SUCCESS|FAILURE|PENDING|ERROR|EXPECTED|NONE>
#     review=<APPROVED|CHANGES_REQUESTED|COMMENTED|DISMISSED|NONE> review-commit=<sha|->
#     reviewed=<head|stale|none> cache=<new|changed|same>
#   cache=same: the cached row for this head SHA matches (nothing to re-read for this PR);
#   changed: same head, new roll-up or review; new: a head this cache has not seen.
# Cache: <state dir>/pr-snapshot/<head sha>.json, pruned to the heads that are still open.
# GraphQL refused (Claude Code cloud sessions answer it with HTTP 403): ORCHESTRATE_GH_API=auto
# (default) falls back to REST on a 403 that names GraphQL, =rest skips the GraphQL attempt,
# =graphql never falls back. Over REST (gh-rest-pr.sh) the rows are the same but cost per PR: the
# open list in pages of 100 (oldest first), then for every PR its head's check-runs and status
# (plus actions/runs when a check names an Actions run) and its reviews. The roll-up state is
# derived from those: any failed check FAILURE, else ERROR, else pending PENDING, else EXPECTED,
# else SUCCESS, NONE without checks.
# Exit: 0 complete | 1 truncated (more open PRs than --limit; the rows printed are valid) |
#   3 unreadable (the gh-read.sh line is on stderr; no rows) | 2 usage
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

repo="" limit=300 json=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --json) json=yes; shift ;;
    -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "gh-snapshot.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "gh-snapshot.sh: --limit must be a positive number" >&2; exit 2; }
api=${ORCHESTRATE_GH_API:-auto}
case "$api" in auto | rest | graphql) ;; *) echo "gh-snapshot.sh: ORCHESTRATE_GH_API must be auto, rest or graphql" >&2; exit 2 ;; esac
repo=$(orch_repo "$repo")
cache="$(orch_state_dir "$repo")/pr-snapshot"
mkdir -p "$cache"

query='query($owner: String!, $name: String!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: $first, after: $after, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number headRefOid isDraft
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        reviews(last: 1) { nodes { state commit { oid } } }
      }
    }
  }
}'

rows='[]' after="" truncated=no
err=$(mktemp)
trap 'rm -f "$err"' EXIT
while [[ "$api" != rest ]]; do
  want=$((limit - $(jq length <<<"$rows")))
  ((want > 100)) && want=100
  args=(api graphql -f "query=$query" -F "owner=${repo%%/*}" -F "name=${repo#*/}" -F "first=$want")
  [[ -z "$after" ]] || args+=(-f "after=$after")
  rc=0
  page=$("$here/gh-read.sh" --json -- "${args[@]}" 2>"$err") || rc=$?
  if ((rc == 5)) && [[ "$api" == auto && -z "$after" ]] && grep -q GraphQL "$err"; then api=rest; break; fi
  ((rc == 0)) || { cat "$err" >&2; exit 3; }
  conn=$(jq -c '.data.repository.pullRequests // empty' <<<"$page")
  [[ -n "$conn" ]] || { echo "gh-snapshot: no pullRequests in the response" >&2; exit 3; }
  rows=$(jq -c --argjson rows "$rows" '$rows + [.nodes[] | {
      number, head: .headRefOid, draft: .isDraft,
      rollup: (.commits.nodes[0].commit.statusCheckRollup.state // "NONE"),
      review: (.reviews.nodes[0].state // "NONE"),
      review_commit: (.reviews.nodes[0].commit.oid // null)}
    | .reviewed = (if .review_commit == null then "none" elif .review_commit == .head then "head" else "stale" end)]' <<<"$conn")
  [[ "$(jq -r .pageInfo.hasNextPage <<<"$conn")" == true ]] || break
  if (($(jq length <<<"$rows") >= limit)); then truncated=yes; break; fi
  after=$(jq -r .pageInfo.endCursor <<<"$conn")
done

# REST: the list, then per PR its head's roll-up and its last review.
if [[ "$api" == rest ]]; then
  rest="$here/gh-rest-pr.sh"
  list=$("$rest" list --repo "$repo" --limit $((limit + 1)) --asc) || exit 3
  (($(jq length <<<"$list") <= limit)) || truncated=yes
  rows='[]'
  while IFS=$'\t' read -r n head draft; do
    [[ -n "$n" ]] || continue
    roll=$("$rest" rollup --repo "$repo" --sha "$head") || exit 3
    rev=$("$rest" review --repo "$repo" --pr "$n") || exit 3
    rows=$(jq -c --argjson rows "$rows" --argjson n "$n" --arg head "$head" --argjson draft "$draft" --argjson rev "$rev" '
      [.[] | ((.conclusion // "") | if . == "" then null else . end) // .state // .status // "" | ascii_upcase] as $s
      | (if ($s | length) == 0 then "NONE"
         elif any($s[]; IN("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE")) then "FAILURE"
         elif any($s[]; . == "ERROR") then "ERROR"
         elif any($s[]; IN("SUCCESS", "SKIPPED", "NEUTRAL", "EXPECTED") | not) then "PENDING"
         elif any($s[]; . == "EXPECTED") then "EXPECTED"
         else "SUCCESS" end) as $roll
      | $rows + [{number: $n, head: $head, draft: $draft, rollup: $roll, review: ($rev.state // "NONE"),
                  review_commit: $rev.commit}
                 | .reviewed = (if .review_commit == null then "none" elif .review_commit == .head then "head" else "stale" end)]' <<<"$roll")
  done < <(jq -r --argjson lim "$limit" '.[:$lim][] | [.number, .headRefOid, .isDraft] | @tsv' <<<"$list")
fi

# Compare each row with the cached one for its head SHA, then keep only the open heads.
out='[]'
for i in $(seq 0 $(($(jq length <<<"$rows") - 1))); do
  row=$(jq -c ".[$i]" <<<"$rows")
  head=$(jq -r .head <<<"$row")
  [[ "$head" =~ ^[0-9a-f]+$ ]] || continue
  f="$cache/$head.json"
  if [[ ! -f "$f" ]]; then state=new
  elif [[ "$(jq -c 'del(.cache)' "$f" 2>/dev/null)" == "$row" ]]; then state=same
  else state=changed
  fi
  printf '%s\n' "$row" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"
  out=$(jq -c --argjson r "$row" --arg c "$state" '. + [$r + {cache: $c}]' <<<"$out")
done
for f in "$cache"/*.json; do
  [[ -f "$f" ]] || continue
  h=$(basename "$f" .json)
  jq -e --arg h "$h" 'any(.[]; .head == $h)' <<<"$out" >/dev/null || rm -f "$f"
done

if [[ "$json" == yes ]]; then
  printf '%s\n' "$out"
else
  jq -r '.[] | "pr \(.number) head=\(.head) draft=\(if .draft then "yes" else "no" end) rollup=\(.rollup)"
    + " review=\(.review) review-commit=\(.review_commit // "-") reviewed=\(.reviewed) cache=\(.cache)"' <<<"$out"
fi
[[ "$truncated" == no ]] || { echo "gh-snapshot: truncated at --limit $limit" >&2; exit 1; }
exit 0
