#!/usr/bin/env bash
# Device-recheck hold: a PR that fixes a device-found regression may merge only after a device run
# on its current head passes. Only a device run caught the bug, so only a device run confirms the fix.
#
# Usage: device-recheck.sh check --pr N [--repo OWNER/REPO] [--regression-label L]...
#        device-recheck.sh scan  --pr N [--repo OWNER/REPO] [--regression-label L]... [--dry-run]
#        device-recheck.sh hold  --pr N --reason TEXT [--issue M]... [--repo OWNER/REPO] [--dry-run]
#        device-recheck.sh pass|fail --pr N --head SHA --device TEXT --evidence TEXT
#                                    [--repo OWNER/REPO] [--regression-label L]... [--dry-run]
#        device-recheck.sh list [--repo OWNER/REPO]
#   check  read-only, one line. `held: ...` when the PR carries the needs-device-recheck label, has
#          a held or failed record, links ("Closes/Fixes/Resolves/Part of #M") an issue labelled as
#          a device regression with no passing recheck, or passed on an older head; else `clear: ...`.
#   scan   check, then set the hold it finds: add the label and write the record. Run it when a PR
#          opens or its body changes; the merge loop runs `check` before every merge.
#   hold   set the hold by hand (the issue lacks the label, or you know a device found it).
#   pass   the device recheck passed on --head, which must be the PR's current head: post the result
#          on the PR and on each linked regression issue, remove the label, record the head.
#   fail   post the failure the same way; the hold stays (the label is added if missing).
#   list   local only: held or failed records, one TSV row each: pr  state  issues  since
# Regression labels: --regression-label (repeatable), else ORCHESTRATE_DEVICE_REGRESSION_LABELS
# (comma-separated), else `manual-test-regression,device-regression`. The hold label is
# ORCHESTRATE_DEVICE_HOLD_LABEL (default needs-device-recheck). Records live in
# <state dir>/device-recheck/pr<N>.json; posted results are journaled there, so a rerun after a
# failed write posts only what is missing. Actions append to <state dir>/device-recheck.log.
# Exit: 0 clear (check, scan) or done | 2 usage | 3 held (check, scan) or refused (pass, fail: the
#       head moved, or the PR is not open) | 4 a read failed: treat as held | 5 a write failed
#       (rerun finishes it)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  check | scan | hold | pass | fail | list) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" pr="" head="" device="" evidence="" reason="" dry=no
rlabels=() extra=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --device) device=$2; shift 2 ;;
    --evidence) evidence=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --issue) extra+=("$2"); shift 2 ;;
    --regression-label) rlabels+=("$2"); shift 2 ;;
    --dry-run) dry=yes; shift ;;
    *) echo "device-recheck.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
dir="$state/device-recheck"
hold_label=${ORCHESTRATE_DEVICE_HOLD_LABEL:-needs-device-recheck}

if [[ "$cmd" == list ]]; then
  [[ -d "$dir" ]] || exit 0
  for f in "$dir"/pr*.json; do
    [[ -f "$f" ]] || continue
    jq -r 'select(.state == "held" or .state == "failed")
      | [.pr, .state, ((.issues // []) | map("#\(.)") | join(",") | if . == "" then "-" else . end), .since]
      | @tsv' "$f"
  done
  exit 0
fi

[[ "$pr" =~ ^[0-9]+$ ]] || usage
for m in ${extra[@]+"${extra[@]}"}; do [[ "$m" =~ ^[0-9]+$ ]] || usage; done
case "$cmd" in
  hold) [[ -n "$reason" ]] || usage ;;
  pass | fail) [[ ${#head} -ge 7 && -n "$device" && -n "$evidence" ]] || usage ;;
esac
if ((${#rlabels[@]} == 0)); then
  IFS=, read -r -a rlabels <<<"${ORCHESTRATE_DEVICE_REGRESSION_LABELS:-manual-test-regression,device-regression}"
fi
rec="$dir/pr$pr.json"
now=$(orch_iso "$(orch_now)")
log() { printf '%s\tpr=%s\t%s\n' "$now" "$pr" "$1" >>"$state/device-recheck.log"; }
record() { if [[ -f "$rec" ]]; then cat "$rec"; else echo '{}'; fi; }
save() { [[ "$dry" == yes ]] || orch_journal "$rec" "$1"; }

# --- reads ----------------------------------------------------------------------------------
prj=$(orch_read_retry 3 gh pr view "$pr" --repo "$repo" --json state,headRefOid,body,labels) &&
  jq -e .headRefOid <<<"$prj" >/dev/null 2>&1 ||
  { echo "unverified: PR $pr could not be read"; exit 4; }
cur=$(jq -r .headRefOid <<<"$prj")
prstate=$(jq -r .state <<<"$prj")
labelled=$(jq -r --arg l "$hold_label" '[.labels[]?.name] | index($l) != null' <<<"$prj")
r=${repo//./\\.}
refs=$(jq -r '.body // ""' <<<"$prj" |
  grep -oiE "(close[sd]?|fix(e[sd])?|resolve[sd]?|part of)[: ]+(#|$r#|https://github\.com/$r/issues/)[0-9]+" |
  grep -oE '[0-9]+$' | awk '!seen[$0]++' || true)
regress=()
for m in $refs; do
  il=$(orch_read_retry 3 gh api "repos/$repo/issues/$m") || { echo "unverified: issue $m could not be read"; exit 4; }
  names=$(jq -r '[.labels[]?.name] | join(",")' <<<"$il") || { echo "unverified: issue $m is unreadable"; exit 4; }
  for l in "${rlabels[@]}"; do
    if [[ ",$names," == *",$l,"* ]]; then regress+=("$m"); break; fi
  done
done
reglist=$(printf '%s\n' ${regress[@]+"${regress[@]}"} | awk 'NF' | sed 's/^/#/' | paste -sd, -)
rstate=$(record | jq -r '.state // ""')
rhead=$(record | jq -r '.head // ""')

# verdict -> sets `why` and returns 0 when held.
verdict() {
  if [[ "$labelled" == true ]]; then why="PR $pr carries $hold_label"; return 0; fi
  case "$rstate" in
    held) why="PR $pr is held for a device recheck ($(record | jq -r '.reason // "-"'))"; return 0 ;;
    failed) why="the device recheck of PR $pr failed on ${rhead:0:9}"; return 0 ;;
    passed)
      if [[ "$rhead" == "$cur" ]]; then why="device recheck of PR $pr passed on ${cur:0:9} ($(record | jq -r '.device // "-"'))"; return 1; fi
      why="device recheck of PR $pr passed on ${rhead:0:9}, but its head is now ${cur:0:9}; recheck the new head"; return 0 ;;
  esac
  if [[ -n "$reglist" ]]; then why="PR $pr fixes device-found regression(s) $reglist and no device recheck is recorded"; return 0; fi
  why="PR $pr fixes no device-found regression and has no device hold"; return 1
}

# add_label -> creates the label if missing (--force is idempotent) and puts it on the PR.
add_label() {
  [[ "$labelled" == true || "$dry" == yes ]] && return 0
  gh label create "$hold_label" --repo "$repo" --color B60205 --force \
    --description "Fixes a device-found regression: merge only after a passing device recheck" >/dev/null 2>&1 &&
    gh pr edit "$pr" --repo "$repo" --add-label "$hold_label" >/dev/null 2>&1 ||
    { echo "error: could not label PR $pr $hold_label; rerun"; exit 5; }
}

why=""
case "$cmd" in
  check)
    if verdict; then echo "held: $why"; exit 3; fi
    echo "clear: $why"; exit 0 ;;
  scan | hold)
    if [[ "$cmd" == scan ]]; then
      if ! verdict; then echo "clear: $why"; exit 0; fi
      if [[ "$rstate" == held || "$rstate" == failed ]]; then reason=$(record | jq -r '.reason // "-"'); else reason=$why; fi
    fi
    [[ "$prstate" == OPEN ]] || { echo "refused: PR $pr is $prstate"; exit 3; }
    add_label
    issues=$(printf '%s\n' ${regress[@]+"${regress[@]}"} ${extra[@]+"${extra[@]}"} | awk 'NF && !seen[$0]++' | jq -Rn '[inputs | tonumber]')
    save "$(record | jq -c --argjson pr "$pr" --argjson is "$issues" --arg r "$reason" --arg at "$now" \
      '.pr = $pr | .issues = ((.issues // []) + $is | unique) | .state = (if .state == "failed" then "failed" else "held" end)
       | .reason = $r | .since = (.since // $at)')"
    [[ "$dry" == yes ]] || log "hold $reason"
    echo "held: PR $pr needs a device recheck ($reason); $hold_label is on the PR$([[ "$dry" == no ]] || echo ' (dry run)')"
    [[ "$cmd" == hold ]] && exit 0
    exit 3 ;;
esac

# --- pass | fail ----------------------------------------------------------------------------
[[ "$prstate" == OPEN ]] || { echo "refused: PR $pr is $prstate"; exit 3; }
[[ "$cur" == "$head"* ]] ||
  { echo "refused: the recheck ran on ${head:0:9} but PR $pr's head is ${cur:0:9}; recheck the current head"; exit 3; }
targets=$( { echo "$pr"; record | jq -r '(.issues // [])[]'; printf '%s\n' ${regress[@]+"${regress[@]}"}; } | awk 'NF && !seen[$0]++')
if [[ "$cmd" == pass ]]; then word="passed"; else word="FAILED"; fi
body="**Device recheck $word** on \`${cur:0:12}\` (PR #$pr, $device): $evidence

<!-- waaagh:device-recheck verdict=$cmd head=$cur -->"
for t in $targets; do
  key="$cmd:$cur:$t"
  if record | jq -e --arg k "$key" '(.posted // []) | index($k) != null' >/dev/null; then continue; fi
  if [[ "$dry" == yes ]]; then echo "would post on #$t: device recheck $word"; continue; fi
  gh api -X POST "repos/$repo/issues/$t/comments" -f body="$body" >/dev/null 2>&1 ||
    { echo "error: could not post the result on #$t; rerun"; exit 5; }
  save "$(record | jq -c --argjson pr "$pr" --arg k "$key" '.pr = $pr | .posted = ((.posted // []) + [$k])')"
done
issues=$(printf '%s\n' $targets | awk -v p="$pr" 'NF && $0 != p' | jq -Rn '[inputs | tonumber]')
if [[ "$cmd" == pass ]]; then
  if [[ "$labelled" == true && "$dry" == no ]]; then
    gh pr edit "$pr" --repo "$repo" --remove-label "$hold_label" >/dev/null 2>&1 ||
      { echo "error: could not remove $hold_label from PR $pr; rerun"; exit 5; }
  fi
  newstate=passed
else
  add_label
  newstate=failed
fi
save "$(record | jq -c --argjson pr "$pr" --argjson is "$issues" --arg s "$newstate" --arg h "$cur" \
  --arg d "$device" --arg e "$evidence" --arg at "$now" \
  '.pr = $pr | .issues = $is | .state = $s | .head = $h | .device = $d | .evidence = $e | .checked_at = $at
   | .since = (.since // $at)')"
[[ "$dry" == yes ]] || log "$cmd head=$cur device=$device evidence=$evidence"
list=$(printf '%s\n' $targets | sed 's/^/#/' | paste -sd, -)
if [[ "$cmd" == pass ]]; then
  echo "lifted: device recheck passed on ${cur:0:9}; posted on $list$([[ "$dry" == no ]] || echo ' (dry run)')"
else
  echo "held: device recheck failed on ${cur:0:9}; posted on $list$([[ "$dry" == no ]] || echo ' (dry run)')"
fi
