#!/usr/bin/env bash
# Read githubstatus.com and say whether GitHub itself is degraded. Used after a 5xx from a GitHub
# write (a merge returning 502) to tell an outage from a one-off error, and to pause the merge
# loop while Pull Requests is down instead of logging a failure every pass.
#
# Usage: gh-status.sh [--component NAME]...
#   --component  a component whose non-operational status decides the exit code (repeatable;
#                default "Pull Requests"). Other non-operational components are printed too.
# Output: one line, `operational` or `degraded <name>=<status>[,<name>=<status>...]` listing every
# non-operational component (names with spaces keep them).
# Exit: 0 every named component operational | 4 a named component is non-operational (outage)
#       | 9 the status page could not be read or parsed | 2 usage
# Env: GITHUB_STATUS_URL (default https://www.githubstatus.com/api/v2/summary.json; tests point it
#      at a file:// fixture so no test reaches the network), GITHUB_STATUS_TIMEOUT (default 10 s).
set -euo pipefail

components=()
while (($#)); do
  case "$1" in
    --component) components+=("$2"); shift 2 ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "gh-status.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
((${#components[@]})) || components=("Pull Requests")

url=${GITHUB_STATUS_URL:-https://www.githubstatus.com/api/v2/summary.json}
body=$(curl -fsS --max-time "${GITHUB_STATUS_TIMEOUT:-10}" "$url" 2>/dev/null) || {
  echo "unreadable: $url"; exit 9
}
bad=$(jq -r '[.components[]? | select(.status != "operational" and (.group | not)) | "\(.name)=\(.status)"] | join(",")' \
  <<<"$body" 2>/dev/null) || { echo "unreadable: $url (not a status summary)"; exit 9; }
jq -e '.components | type == "array"' <<<"$body" >/dev/null 2>&1 || { echo "unreadable: $url (not a status summary)"; exit 9; }

if [[ -z "$bad" ]]; then echo operational; exit 0; fi
echo "degraded $bad"
hit=$(jq -r --args '[.components[]? | select(.status != "operational") | .name] as $down
  | [$ARGS.positional[] | select(. as $c | $down | index($c) != null)] | length' "${components[@]}" <<<"$body")
if ((hit > 0)); then exit 4; fi
exit 0
