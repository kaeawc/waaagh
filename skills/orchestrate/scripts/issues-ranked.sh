#!/usr/bin/env bash
# Ranked work list: open issues updated recently, bugs first. Read-only; one page of gh calls, so
# the orchestrator and the hygiene bot plan from the same compact list instead of reading issues.
#
# Usage: issues-ranked.sh [--repo OWNER/REPO] [--since-days N] [--limit N]
#                         [--priority-label L]... [--bug-label L]... [--exclude-label L]...
#                         [--skip-in-pr] [--route R] [--drop-blocked]
# --route keeps only issues carrying route label R (`cloud-ready`, or a prefix ending in `*` such
# as `needs-local:*`): cloud dispatch takes only cloud-ready, local lanes only needs-local:*.
# Order: priority-labelled bugs, priority-labelled others, bugs, everything else; newest update
# first within a tier. Defaults: --since-days 7, --limit 60, bug label "bug", exclude "blocked".
# Output (TSV): rank  number  tier  in_pr  updated  labels  title
#   tier:  P-bug | P | bug | other      in_pr: open PR that will close it, or "-"
# --drop-blocked runs open-blockers.sh on the top --limit rows before anyone ranks them: a row with
# an open blocker is dropped, and its blockers are ranked instead when routable (they pass this
# list's filters): a blocker anywhere in the list moves up to the place of the first issue it
# blocks, unless it is blocked itself. Rows that could not be checked stay. A last "# " line then
# names the dropped rows and their blockers, the promoted blockers, the blockers outside this list
# (route them first, or wait) and the unchecked rows. Costs two or three reads per row checked.
# Reads go through gh-issues.sh: GraphQL, or REST where GitHub refuses GraphQL (cloud sessions);
# over REST, "in an open PR" comes from closing keywords in the PR body, not sidebar links.
# Exit: 0 ok | 2 usage | 4 --drop-blocked: open-blockers.sh failed outright | 5 issues or open
#   PRs could not be read.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority low

usage_end=$(($(grep -n '^set -euo pipefail' "$0" | cut -d: -f1 | sed -n 1p) - 1))
repo="" days=7 limit=60 skip_in_pr=no route="" drop_blocked=no
priority=() bug=() exclude=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --since-days) days=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --priority-label) priority+=("$2"); shift 2 ;;
    --bug-label) bug+=("$2"); shift 2 ;;
    --exclude-label) exclude+=("$2"); shift 2 ;;
    --skip-in-pr) skip_in_pr=yes; shift ;;
    --route) route=$2; shift 2 ;;
    --drop-blocked) drop_blocked=yes; shift ;;
    -h | --help) sed -n "2,${usage_end}p" "$0"; exit 0 ;;
    *) echo "issues-ranked.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")
((${#bug[@]})) || bug=(bug)
((${#exclude[@]})) || exclude=(blocked)
json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }
since=$(jq -rn --argjson now "$(orch_now)" --argjson d "$days" '$now - $d * 86400 | strftime("%Y-%m-%d")')

# With --drop-blocked every row is ranked here, so blockers below the cut can be promoted.
jq_limit=$limit
[[ "$drop_blocked" == no ]] || jq_limit=1000000

# gh-issues.sh: GraphQL, or REST where GitHub refuses GraphQL (an open PR's closing references
# then come from its body's closing keywords).
read_fail() { echo "issues-ranked.sh: $1 could not be read" >&2; exit 5; }
prs=$("$here/gh-issues.sh" prs-open --repo "$repo" --limit 300 --fields number,closingIssuesReferences) ||
  read_fail "open pull requests"
issues=$("$here/gh-issues.sh" issues --repo "$repo" --limit 500 --since "$since" \
  --fields number,title,labels,updatedAt) || read_fail "open issues"
rows=$(jq -r --argjson prs "$prs" --argjson priority "$(json_list ${priority[@]+"${priority[@]}"})" \
    --argjson bug "$(json_list "${bug[@]}")" --argjson exclude "$(json_list "${exclude[@]}")" \
    --argjson limit "$jq_limit" --arg skip "$skip_in_pr" --arg route "$route" '
    def has_any($set): any(.[]; . as $l | $set | index($l));
    def routed: $route == "" or any(.[];
      if ($route | endswith("*")) then startswith($route | rtrimstr("*")) else . == $route end);
    ([$prs[] | .number as $p | (.closingIssuesReferences // [])[] | {key: (.number | tostring), value: $p}]
      | from_entries) as $closing
    | [.[] | ([.labels[].name]) as $l | select(($l | has_any($exclude) | not) and ($l | routed))
       | {number, title, updated: .updatedAt, labels: $l, in_pr: ($closing[.number | tostring] // null),
          p: ($l | has_any($priority)), b: ($l | has_any($bug))}
       | select($skip == "no" or .in_pr == null)
       | .tier = (if .p and .b then 0 elif .p then 1 elif .b then 2 else 3 end)]
    | sort_by(.tier, (.updated | fromdateiso8601 | -.)) | .[0:$limit] | to_entries[]
    | [.key + 1, .value.number, (["P-bug", "P", "bug", "other"][.value.tier]),
       (.value.in_pr // "-"), .value.updated, (.value.labels | join(",") | if . == "" then "-" else . end),
       .value.title] | @tsv' <<<"$issues")
if [[ "$drop_blocked" == no ]]; then
  [[ -z "$rows" ]] || printf '%s\n' "$rows"
  exit 0
fi

# --drop-blocked: check the top rows, then the blockers they name that sit lower in the list.
[[ -n "$rows" ]] || { echo "# drop-blocked: no rows"; exit 0; }
check() { # issue... -> open-blockers.sh lines; exit 4 when it fails outright
  local out rc=0
  out=$("$here/open-blockers.sh" --repo "$repo" "$@") || rc=$?
  case "$rc" in
    0 | 3 | 4) printf '%s\n' "$out" ;;
    *) echo "issues-ranked.sh: open-blockers.sh failed (exit $rc)" >&2; exit 4 ;;
  esac
}
# shellcheck disable=SC2046  # issue numbers, one word each
checked=$(check $(awk -F'\t' -v n="$limit" 'NR <= n { print $2 }' <<<"$rows"))
promote=$(jq -rn --arg rows "$rows" --arg ob "$checked" --argjson limit "$limit" '
  ($rows | split("\n") | map(select(length > 0) | split("\t")[1])) as $all
  | $all[0:$limit] as $top
  | [$ob | split("\n")[] | split(" ") | select(.[1] == "BLOCKED") | .[3:][]
     | select(startswith("#")) | ltrimstr("#")
     | select(. as $b | ($top | index($b)) == null and ($all | index($b)) != null)] | unique | .[]')
if [[ -n "$promote" ]]; then
  # shellcheck disable=SC2086  # issue numbers, one word each
  checked+=$'\n'$(check $promote)
fi
jq -rn --arg rows "$rows" --arg ob "$checked" --argjson limit "$limit" '
  [$rows | split("\n")[] | select(length > 0) | split("\t")] as $all
  | ($all | map({key: .[1], value: (.[0] | tonumber)}) | from_entries) as $rank
  | [$ob | split("\n")[] | select(length > 0) | split(" ")
     | {n: .[0], s: .[1], by: (if .[1] == "BLOCKED" then .[3:] else [] end)}] as $res
  | ($res | map({key: .n, value: .}) | from_entries) as $r
  | [$res[] | select(.s == "BLOCKED")] as $blocked
  # A clear blocker takes the place of the first issue it blocks.
  | (reduce $blocked[] as $b ({}; reduce ($b.by[] | select(startswith("#")) | ltrimstr("#")) as $x (.;
       .[$x] = ([.[$x] // 1e18, $rank[$b.n]] | min)))) as $lift
  | ([$all[] | select($r[.[1]] != null and $r[.[1]].s != "BLOCKED")
      | {row: ., key: ([$rank[.[1]], ($lift[.[1]] // 1e18)] | min), own: $rank[.[1]],
         promoted: (($lift[.[1]] // 1e18) < $rank[.[1]])}]
     | sort_by(.key, .own) | .[0:$limit]) as $kept
  | ([$blocked[].by[] | select((startswith("#") | not) or $rank[ltrimstr("#")] == null)] | unique) as $outside
  | def names: if length > 0 then join(" ") else "none" end;
    ($kept | to_entries[] | [(.key + 1 | tostring)] + .value.row[1:] | @tsv),
    ("# drop-blocked: dropped \($blocked | length)"
     + (if ($blocked | length) > 0 then " (" + ($blocked | map("#\(.n) by " + (.by | join(" "))) | join("; ")) + ")" else "" end)
     + "; promoted blockers: " + ([$kept[] | select(.promoted) | "#" + .row[1]] | names)
     + "; blockers outside this list: " + ($outside | names)
     + "; unchecked: " + ([$res[] | select(.s == "unreadable") | "#" + .n] | names))'
