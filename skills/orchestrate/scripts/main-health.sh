#!/usr/bin/env bash
# Is the default branch green? Reads the newest completed push run of each workflow on it and
# sets or clears <state dir>/MAIN_RED, which pr-merge.sh honours as a merge hold.
#
# Usage: main-health.sh [--repo OWNER/REPO] [--branch B] [--workflow NAME]...
#                       [--ignore-workflow NAME]... [--limit N] [--auto-rerun [--classifier CMD]]
#   --workflow         judge only these workflows, and require completed evidence for EVERY one
#                      (default: every workflow with a push run in the window)
#   --ignore-workflow  advisory workflows that never turn the branch red
#   --limit            how many recent push runs to read (default 60, at most 100: one page)
#   --auto-rerun       on red, classify each red run (`CMD --repo R --run ID`, first word of its
#                      first line; CMD from --classifier, else ORCHESTRATE_CLASSIFIER_CMD; with
#                      neither, every run is unclassified). When every one is rerunnable (flake,
#                      known-flake, infra, rerun or rerun-dont-fix; any case, `_` = `-`), each is
#                      re-run once through `triage-tick.sh rerun` (failed jobs, or the whole run
#                      when its log shows a needs dependency that did not succeed), logged to
#                      reruns.log. A run already in reruns.log, or already past its first attempt,
#                      is never re-run here: it failed again (#270). A run with no usable verdict
#                      (unknown or unclassified) is also rerunnable when the log tail of each of its
#                      failed jobs shows a package-mirror fetch failure (#297). Also on with
#                      ORCHESTRATE_MAIN_AUTO_RERUN=1.
# Policy: each workflow is judged by its newest COMPLETED run (cancelled and skipped runs aside),
# not by a run on the current head; the output names the SHA each verdict comes from. A run is
# judged by its newest attempt. A rerun still going (run_attempt > 1, queued or in progress) that
# is newer than a workflow's newest completed run makes that workflow pending: no older run of it
# is evidence, so it can neither turn the branch red nor clear the hold (#115).
# Output: "green <newest sha> <workflow>@<sha>,... [mixed-heads]"
#       | "red <sha> <workflow>=<conclusion>(<run id>) ... [auto-rerun=<state> runs=<id>:<what>,...]"
#         with --auto-rerun: requested (<what> failed-jobs or full: merges stay held until the rerun
#         is green), held (<what> the verdict that is not rerunnable: investigate, unclassified,
#         rerun-failed after a rerun failed again, rerun-pending while the requested rerun has not
#         started; surface it, a fix lane takes it) or error (<what> requested, full, refused,
#         failed or unverified per run: `triage-tick.sh rerun`'s answer)
#       | "unknown <reason>": no completed run yet, the run list could not be read, or a workflow
#         has no usable evidence: missing=<name>(pending|rerun-in-progress|not-in-window|no-run),...
# Exit: 0 green (MAIN_RED cleared) | 1 red (MAIN_RED written) | 2 unknown (MAIN_RED left as it was)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

repo="" branch="" limit=60 auto=no classifier=${ORCHESTRATE_CLASSIFIER_CMD:-}
[[ "${ORCHESTRATE_MAIN_AUTO_RERUN:-0}" != 1 ]] || auto=yes
only=() ignore=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --workflow) only+=("$2"); shift 2 ;;
    --ignore-workflow) ignore+=("$2"); shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --auto-rerun) auto=yes; shift ;;
    --classifier) classifier=$2; shift 2 ;;
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

# Auto-rerun (#270): a red main whose every red run the classifier calls rerunnable is re-run
# once per run id through triage-tick.sh rerun (same reruns.log, same needs rule), and stays held.
# run_mirror_outage ID: exit 0 when the run has failed jobs and the bounded log tail (job-log.sh,
# last 400 lines) of every one of them shows the package-mirror signature (orch_mirror_sig, shared
# with failure-triage.sh). Any unreadable log or non-mirror failure is a no.
run_mirror_outage() {
  local jid out path n=0 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/main-health-log.XXXXXX")
  for jid in $("$here/gh-read.sh" -- api "repos/$repo/actions/runs/$1/jobs?filter=latest&per_page=100" \
    --jq '.jobs[] | select(.conclusion == "failure") | .id' 2>/dev/null </dev/null || true); do
    out=$("$here/job-log.sh" --repo "$repo" --job "$jid" 2>/dev/null </dev/null) || { rm -f "$tmp"; return 1; }
    path=$(awk 'NR == 1 && $1 == "available" { print $2 }' <<<"$out")
    [[ -n "$path" && -f "$path" ]] || { rm -f "$tmp"; return 1; }
    tail -n 400 "$path" >"$tmp"
    orch_mirror_sig "$tmp" >/dev/null || { rm -f "$tmp"; return 1; }
    n=$((n + 1))
  done
  rm -f "$tmp"
  ((n > 0))
}

if [[ "$auto" == yes && "$verdict" == red* ]]; then
  export reruns="$state/reruns.log" # read by orch_rerun_seen (_lib.sh)
  held="" ok=""
  for id in $(grep -oE '=[a-z_]+\([0-9]+\)' <<<"$verdict" | tr -dc '0-9\n'); do
    attempt=$(jq -r --argjson id "$id" '[.[] | select(.databaseId == $id) | .runAttempt] | max // 1' <<<"$runs")
    if ((attempt > 1)); then cls=rerun-failed
    elif orch_rerun_seen "$id"; then cls=rerun-pending
    elif [[ -n "$classifier" ]]; then
      cls=$(bash -c "$classifier"' "$@"' _ --repo "$repo" --run "$id" 2>/dev/null </dev/null |
        awk 'NR == 1 { v = tolower($1); gsub(/_/, "-", v); gsub(/[^a-z-]/, "", v); print v }') || cls=""
      [[ -n "$cls" ]] || cls=unclassified
    else cls=unclassified; fi
    # No usable verdict: read the failed jobs' log tails; a package-mirror fetch failure in every
    # one is infrastructure, so it counts as rerunnable (#297).
    case "$cls" in unknown | unclassified | "") run_mirror_outage "$id" && cls=infra ;; esac
    if orch_verdict_rerunnable "$cls"; then ok="$ok $id"; else held="${held:+$held,}$id:$cls"; fi
  done
  if [[ -n "$held" ]]; then
    verdict="$verdict auto-rerun=held runs=$held"
  elif [[ -n "$ok" ]]; then
    done_csv="" word=requested
    for id in $ok; do
      rc=0
      out=$("$here/triage-tick.sh" rerun --repo "$repo" --run "$id" 2>/dev/null </dev/null) || rc=$?
      case "$rc:$out" in
        "0:rerun requested (full)"*) what=full ;;
        0:*) what=failed-jobs ;;
        3:*) what=refused word=error ;;
        9:*) what=unverified word=error ;;
        *) what=failed word=error ;;
      esac
      done_csv="${done_csv:+$done_csv,}$id:$what"
    done
    verdict="$verdict auto-rerun=$word runs=$done_csv"
  fi
fi

echo "$verdict"
case "$verdict" in
  green*) rm -f "$state/MAIN_RED"; exit 0 ;;
  red*) printf '%s\n%s\n' "$verdict" "$(orch_iso "$(orch_now)")" >"$state/MAIN_RED"; exit 1 ;;
  *) exit 2 ;;
esac
