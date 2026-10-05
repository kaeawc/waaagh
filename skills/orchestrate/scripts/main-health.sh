#!/usr/bin/env bash
# Is the default branch green? Reads the newest completed push run of each workflow on it and
# sets or clears <state dir>/MAIN_RED, which pr-merge.sh honours as a merge hold.
#
# Usage: main-health.sh [--repo OWNER/REPO] [--branch B] [--workflow NAME]...
#                       [--ignore-workflow NAME]...
#   --workflow         judge only these workflows (default: every workflow with a push run)
#   --ignore-workflow  advisory workflows that never turn the branch red
# Output: "green <sha>" | "red <sha> <workflow>=<conclusion>(<run id>) ..." | "unknown"
# Exit: 0 green | 1 red | 2 unknown (no completed run yet; MAIN_RED left as it was)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" branch=""
only=() ignore=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --workflow) only+=("$2"); shift 2 ;;
    --ignore-workflow) ignore+=("$2"); shift 2 ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "main-health.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")
[[ -n "$branch" ]] || branch=$(orch_default_branch "$repo")
state=$(orch_state_dir "$repo")
json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }

verdict=$(gh run list --repo "$repo" --branch "$branch" --event push --limit 60 \
  --json workflowName,status,conclusion,headSha,databaseId,createdAt |
  jq -r --argjson only "$(json_list ${only[@]+"${only[@]}"})" \
    --argjson ignore "$(json_list ${ignore[@]+"${ignore[@]}"})" '
    [.[] | select(.status == "completed") | select(.conclusion != "cancelled" and .conclusion != "skipped")
     | select(.workflowName as $w | ($ignore | index($w) | not) and (($only | length) == 0 or ($only | index($w))))]
    | group_by(.workflowName) | map(sort_by(.createdAt) | last) as $latest
    | if ($latest | length) == 0 then "unknown"
      else ($latest | sort_by(.createdAt) | last | .headSha[0:9]) as $sha
        | [$latest[] | select(.conclusion != "success" and .conclusion != "neutral")] as $bad
        | if ($bad | length) == 0 then "green \($sha)"
          else "red \($sha) " + ($bad | map("\(.workflowName)=\(.conclusion)(\(.databaseId))") | join(" ")) end
      end')

echo "$verdict"
case "$verdict" in
  green*) rm -f "$state/MAIN_RED"; exit 0 ;;
  red*) printf '%s\n%s\n' "$verdict" "$(orch_iso "$(orch_now)")" >"$state/MAIN_RED"; exit 1 ;;
  *) exit 2 ;;
esac
