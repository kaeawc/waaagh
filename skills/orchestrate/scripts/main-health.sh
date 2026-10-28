#!/usr/bin/env bash
# Is the default branch green? Reads the newest completed push run of each workflow on it and
# sets or clears <state dir>/MAIN_RED, which pr-merge.sh honours as a merge hold.
#
# Usage: main-health.sh [--repo OWNER/REPO] [--branch B] [--workflow NAME]...
#                       [--ignore-workflow NAME]... [--limit N]
#   --workflow         judge only these workflows, and require completed evidence for EVERY one
#                      (default: every workflow with a push run in the window)
#   --ignore-workflow  advisory workflows that never turn the branch red
#   --limit            how many recent push runs to read (default 60)
# Policy: each workflow is judged by its newest COMPLETED run (cancelled and skipped runs aside),
# not by a run on the current head; the output names the SHA each verdict comes from.
# Output: "green <newest sha> <workflow>@<sha>,... [mixed-heads]"
#       | "red <sha> <workflow>=<conclusion>(<run id>) ..."
#       | "unknown <reason>": no completed run yet, the run list could not be read, or a selected
#         workflow has no completed evidence: missing=<name>(pending|not-in-window|no-run),...
# Exit: 0 green (MAIN_RED cleared) | 1 red (MAIN_RED written) | 2 unknown (MAIN_RED left as it was)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" branch="" limit=60
only=() ignore=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --workflow) only+=("$2"); shift 2 ;;
    --ignore-workflow) ignore+=("$2"); shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "main-health.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")
[[ -n "$branch" ]] || branch=$(orch_default_branch "$repo")
state=$(orch_state_dir "$repo")
json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }

if ! runs=$("$here/gh-read.sh" --json -- run list --repo "$repo" --branch "$branch" --event push --limit "$limit" \
  --json workflowName,status,conclusion,headSha,databaseId,createdAt 2>&1) ||
  ! jq -e 'type == "array"' <<<"$runs" >/dev/null 2>&1; then
  echo "unknown run list unreadable: ${runs:0:200}"
  exit 2
fi

verdict=$(jq -r --argjson only "$(json_list ${only[@]+"${only[@]}"})" \
    --argjson ignore "$(json_list ${ignore[@]+"${ignore[@]}"})" --argjson limit "$limit" '
    (length >= $limit) as $full
    | [.[] | select(.workflowName as $w | ($ignore | index($w) | not) and (($only | length) == 0 or ($only | index($w))))] as $sel
    | [$sel[] | select(.status == "completed") | select(.conclusion != "cancelled" and .conclusion != "skipped")]
    | group_by(.workflowName) | map(sort_by(.createdAt) | last) as $latest
    | [$latest[] | select(.conclusion != "success" and .conclusion != "neutral")] as $bad
    | ($only - ($ignore) - [$latest[].workflowName]) as $missing
    | if ($bad | length) > 0 then
        "red \($bad | sort_by(.createdAt) | last | .headSha[0:9]) "
        + ($bad | map("\(.workflowName)=\(.conclusion)(\(.databaseId))") | join(" "))
      elif ($missing | length) > 0 then
        "unknown missing=" + ($missing | map(. as $m | "\($m)("
          + (if any($sel[]; .workflowName == $m) then "pending" elif $full then "not-in-window" else "no-run" end)
          + ")") | join(","))
      elif ($latest | length) == 0 then
        "unknown no completed run" + (if $full then " in the last \($limit) push runs" else "" end)
      else
        ($latest | map(.headSha[0:9]) | unique) as $shas
        | "green \($latest | sort_by(.createdAt) | last | .headSha[0:9]) "
          + ($latest | map("\(.workflowName)@\(.headSha[0:9])") | join(","))
          + (if ($shas | length) > 1 then " mixed-heads" else "" end)
      end' <<<"$runs")

echo "$verdict"
case "$verdict" in
  green*) rm -f "$state/MAIN_RED"; exit 0 ;;
  red*) printf '%s\n%s\n' "$verdict" "$(orch_iso "$(orch_now)")" >"$state/MAIN_RED"; exit 1 ;;
  *) exit 2 ;;
esac
