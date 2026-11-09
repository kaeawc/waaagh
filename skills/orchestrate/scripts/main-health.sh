#!/usr/bin/env bash
# Is the default branch green? Reads the newest completed push run of each workflow on it and
# sets or clears <state dir>/MAIN_RED, which pr-merge.sh honours as a merge hold.
#
# Usage: main-health.sh [--repo OWNER/REPO] [--branch B] [--workflow NAME]...
#                       [--ignore-workflow NAME]... [--limit N]
#   --workflow         judge only these workflows, and require completed evidence for EVERY one
#                      (default: every workflow with a push run in the window)
#   --ignore-workflow  advisory workflows that never turn the branch red
#   --limit            how many recent push runs to read (default 60, at most 100: one page)
# Policy: each workflow is judged by its newest COMPLETED run (cancelled and skipped runs aside),
# not by a run on the current head; the output names the SHA each verdict comes from. A run is
# judged by its newest attempt. A rerun still going (run_attempt > 1, queued or in progress) that
# is newer than a workflow's newest completed run makes that workflow pending: no older run of it
# is evidence, so it can neither turn the branch red nor clear the hold (#115).
# Output: "green <newest sha> <workflow>@<sha>,... [mixed-heads]"
#       | "red <sha> <workflow>=<conclusion>(<run id>) ..."
#       | "unknown <reason>": no completed run yet, the run list could not be read, or a workflow
#         has no usable evidence: missing=<name>(pending|rerun-in-progress|not-in-window|no-run),...
# Exit: 0 green (MAIN_RED cleared) | 1 red (MAIN_RED written) | 2 unknown (MAIN_RED left as it was)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

repo="" branch="" limit=60
only=() ignore=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --workflow) only+=("$2"); shift 2 ;;
    --ignore-workflow) ignore+=("$2"); shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "main-health.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")
[[ -n "$branch" ]] || branch=$(orch_default_branch "$repo")
state=$(orch_state_dir "$repo")
json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }

# actions/runs directly, one page: `gh run list` also calls actions/workflows to resolve names,
# and that endpoint can be rate limited on its own while runs still read (#71).
((limit <= 100)) || limit=100
if ! raw=$("$here/gh-read.sh" --json -- api "repos/$repo/actions/runs?branch=$(jq -rn --arg b "$branch" '$b | @uri')&event=push&per_page=$limit" 2>&1) ||
  ! runs=$(jq -ce '.workflow_runs | select(type == "array")
      | map({workflowName: .name, status, conclusion, headSha: .head_sha, databaseId: .id, createdAt: .created_at,
        runAttempt: (.run_attempt // 1)})' \
      <<<"$raw" 2>/dev/null); then
  echo "unknown run list unreadable: ${raw:0:200}"
  exit 2
fi

verdict=$(jq -r --argjson only "$(json_list ${only[@]+"${only[@]}"})" \
    --argjson ignore "$(json_list ${ignore[@]+"${ignore[@]}"})" --argjson limit "$limit" '
    (length >= $limit) as $full
    | [.[] | select(.workflowName as $w | ($ignore | index($w) | not) and (($only | length) == 0 or ($only | index($w))))] as $sel
    | ($sel | group_by(.databaseId) | map(max_by(.runAttempt))) as $sel
    | [$sel[] | select(.status == "completed") | select(.conclusion != "cancelled" and .conclusion != "skipped")]
    | group_by(.workflowName) | map(sort_by(.createdAt, .databaseId) | last) as $done
    # a rerun still going, newer than the newest completed run of its workflow: that is no evidence
    | [$sel[] | select(.status != "completed" and .runAttempt > 1) | . as $r
        | select(all($done[]; .workflowName != $r.workflowName or [.createdAt, .databaseId] < [$r.createdAt, $r.databaseId]))
        | .workflowName] as $rerun
    | [$done[] | select(.workflowName as $w | $rerun | index($w) | not)] as $latest
    | [$latest[] | select(.conclusion != "success" and .conclusion != "neutral")] as $bad
    | (($only - ($ignore) - [$latest[].workflowName]) + (($rerun | unique) - $only)) as $missing
    | if ($bad | length) > 0 then
        "red \($bad | sort_by(.createdAt) | last | .headSha[0:9]) "
        + ($bad | map("\(.workflowName)=\(.conclusion)(\(.databaseId))") | join(" "))
      elif ($missing | length) > 0 then
        "unknown missing=" + ($missing | map(. as $m | "\($m)("
          + (if ($rerun | index($m)) then "rerun-in-progress"
             elif any($sel[]; .workflowName == $m) then "pending" elif $full then "not-in-window" else "no-run" end)
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
