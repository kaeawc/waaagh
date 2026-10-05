#!/usr/bin/env bash
# Campaign ledger and the numbers the orchestrator steers by. One durable directory per repo
# (<state dir> = ~/.claude/orchestrate/<owner>__<repo>/) holds campaign.json, MAIN_RED,
# merges.log, filled briefs and role reports.
#
# Usage: campaign.sh <path|status|lanes|verified> [--repo OWNER/REPO] [options]
#   path      print the state directory
#   status    [--bots idle|working] [--verify idle|running]  one key=value per line:
#             paused, open_prs, merge_mode (conservative|fast), main (ok|red, as last written by main-health.sh),
#             merged_since_verification, verification_due (yes|no), lanes
#   lanes     --bots idle|working --verify idle|running      print the implementation-lane cap
#   verified  [--sha SHA]   record that a verification batch covered the branch up to now
# Defaults (override per repo from memory, via flag or env):
#   --lanes A,B,C        ORCHESTRATE_LANES=16,12,4    bots idle, a bot working, verification running
#   --verify-every N     ORCHESTRATE_VERIFY_EVERY=16  merged PRs between verification batches
#   --fast-path-over N   ORCHESTRATE_FAST_PATH_OVER=20  open PRs above which merge_mode is fast
#   --pause-label L      ORCHESTRATE_PAUSE_LABELS="orchestrate-pause fleet-pause" (open issue = stop)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

cmd=${1:-}
[[ -n "$cmd" ]] && shift || true
repo="" bots=working verify=idle sha=""
lanes=${ORCHESTRATE_LANES:-16,12,4}
every=${ORCHESTRATE_VERIFY_EVERY:-16}
over=${ORCHESTRATE_FAST_PATH_OVER:-20}
read -r -a pause_labels <<<"${ORCHESTRATE_PAUSE_LABELS:-orchestrate-pause fleet-pause}"
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --bots) bots=$2; shift 2 ;;
    --verify) verify=$2; shift 2 ;;
    --sha) sha=$2; shift 2 ;;
    --lanes) lanes=$2; shift 2 ;;
    --verify-every) every=$2; shift 2 ;;
    --fast-path-over) over=$2; shift 2 ;;
    --pause-label) pause_labels=("$2"); shift 2 ;;
    *) echo "campaign.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

lane_cap() {
  local idle working verifying
  IFS=, read -r idle working verifying <<<"$lanes"
  if [[ "$verify" == running ]]; then echo "$verifying"
  elif [[ "$bots" == idle ]]; then echo "$idle"
  else echo "$working"; fi
}

case "$cmd" in
  lanes) lane_cap; exit 0 ;;
  path | status | verified) ;;
  *) sed -n '2,17p' "$0" >&2; exit 2 ;;
esac

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
ledger="$state/campaign.json"
# The first run starts the count: merges before the campaign began are not this campaign's.
[[ -f "$ledger" ]] || jq -n --arg at "$(orch_iso "$(orch_now)")" \
  '{started_at: $at, last_verification_at: $at, last_verification_sha: null}' >"$ledger"

case "$cmd" in
  path) echo "$state" ;;
  verified)
    tmp=$(mktemp "$ledger.XXXXXX")
    jq --arg at "$(orch_iso "$(orch_now)")" --arg sha "$sha" \
      '.last_verification_at = $at | .last_verification_sha = (if $sha == "" then null else $sha end)' \
      "$ledger" >"$tmp" && mv "$tmp" "$ledger"
    echo "verified at $(jq -r .last_verification_at "$ledger")"
    ;;
  status)
    paused=no
    for label in "${pause_labels[@]}"; do
      n=$(gh issue list --repo "$repo" --state open --label "$label" --limit 1 --json number | jq length)
      [[ "$n" == 0 ]] || paused="yes($label)"
    done
    open=$(gh pr list --repo "$repo" --state open --limit 300 --json number | jq length)
    since=$(jq -r .last_verification_at "$ledger")
    merged=$(gh pr list --repo "$repo" --state merged --limit 300 --search "merged:>$since" --json number | jq length)
    main=ok
    [[ -f "$state/MAIN_RED" ]] && main=red
    echo "paused=$paused"
    echo "open_prs=$open"
    echo "merge_mode=$( ((open > over)) && echo fast || echo conservative)"
    echo "main=$main"
    echo "merged_since_verification=$merged"
    echo "verification_due=$( ((merged >= every)) && echo yes || echo no)"
    echo "lanes=$(lane_cap)"
    ;;
esac
