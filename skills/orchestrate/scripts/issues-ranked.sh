#!/usr/bin/env bash
# Ranked work list: open issues updated recently, bugs first. Read-only; one page of gh calls, so
# the orchestrator and the hygiene bot plan from the same compact list instead of reading issues.
#
# Usage: issues-ranked.sh [--repo OWNER/REPO] [--since-days N] [--limit N]
#                         [--priority-label L]... [--bug-label L]... [--exclude-label L]...
#                         [--skip-in-pr]
# Order: priority-labelled bugs, priority-labelled others, bugs, everything else; newest update
# first within a tier. Defaults: --since-days 7, --limit 60, bug label "bug", exclude "blocked".
# Output (TSV): rank  number  tier  in_pr  updated  labels  title
#   tier:  P-bug | P | bug | other      in_pr: open PR that will close it, or "-"
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" days=7 limit=60 skip_in_pr=no
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
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "issues-ranked.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")
((${#bug[@]})) || bug=(bug)
((${#exclude[@]})) || exclude=(blocked)
json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }
since=$(jq -rn --argjson now "$(orch_now)" --argjson d "$days" '$now - $d * 86400 | strftime("%Y-%m-%d")')

prs=$(gh pr list --repo "$repo" --state open --limit 300 --json number,closingIssuesReferences)
gh issue list --repo "$repo" --state open --limit 500 --search "updated:>=$since sort:updated-desc" \
  --json number,title,labels,updatedAt |
  jq -r --argjson prs "$prs" --argjson priority "$(json_list ${priority[@]+"${priority[@]}"})" \
    --argjson bug "$(json_list "${bug[@]}")" --argjson exclude "$(json_list "${exclude[@]}")" \
    --argjson limit "$limit" --arg skip "$skip_in_pr" '
    def has_any($set): any(.[]; . as $l | $set | index($l));
    ([$prs[] | .number as $p | (.closingIssuesReferences // [])[] | {key: (.number | tostring), value: $p}]
      | from_entries) as $closing
    | [.[] | ([.labels[].name]) as $l | select($l | has_any($exclude) | not)
       | {number, title, updated: .updatedAt, labels: $l, in_pr: ($closing[.number | tostring] // null),
          p: ($l | has_any($priority)), b: ($l | has_any($bug))}
       | select($skip == "no" or .in_pr == null)
       | .tier = (if .p and .b then 0 elif .p then 1 elif .b then 2 else 3 end)]
    | sort_by(.tier, (.updated | fromdateiso8601 | -.)) | .[0:$limit] | to_entries[]
    | [.key + 1, .value.number, (["P-bug", "P", "bug", "other"][.value.tier]),
       (.value.in_pr // "-"), .value.updated, (.value.labels | join(",") | if . == "" then "-" else . end),
       .value.title] | @tsv'
