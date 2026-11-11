#!/usr/bin/env bash
# Release freeze: stop every merge source, not only the merge loop this session owns (#208). While
# <state dir>/FREEZE exists, every merge path treats every PR as held (orch_hold_of: pr-merge.sh
# exit 14, merge-queue.sh outcome `held`), and auto-merges armed on GitHub, by any account, are
# disarmed and logged so they can be re-armed with their own merge method when the freeze ends.
#
# Usage: freeze.sh start  [--reason TEXT] [--repo OWNER/REPO]
#        freeze.sh sweep  [--repo OWNER/REPO]
#        freeze.sh end    [--no-rearm] [--repo OWNER/REPO]
#        freeze.sh status [--repo OWNER/REPO]
#   start   write FREEZE (kept, with its first time and reason, when already frozen), then sweep.
#   sweep   list the open PRs over REST (`auto_merge` on GET pulls), disarm each one whose auto-merge
#           is armed (`gh pr merge N --disable-auto`), record it, and read it back over REST: a PR
#           still armed afterwards is an error. Run it again right before dispatching the release
#           and at every check while the release runs: it catches PRs armed since the freeze began.
#   end     re-arm each recorded PR that is still open and not armed (`gh pr merge N --auto
#           --<its method>`), then remove FREEZE. A PR merged or closed meanwhile is skipped; one
#           already armed again counts as re-armed. When a re-arm fails the freeze stays, with the
#           rest still recorded. --no-rearm lifts the freeze without re-arming and prints the list.
#   status  `frozen since:<iso> reason=<text>` and one line per recorded PR, or `not frozen`.
# GitHub has no REST call that disables or enables auto-merge: both are GraphQL mutations
# (disablePullRequestAutoMerge, enablePullRequestAutoMerge), which cloud sessions are refused (403).
# A refused call is exit 6 with the owner action: disarm (or re-arm) the listed PRs elsewhere, e.g.
# with the GitHub MCP tools (disable_pr_auto_merge / enable_pr_auto_merge) or from a local session,
# then run the same command again; it reads each PR back and finds the work done.
# A re-arm runs as this session's account, whoever armed the PR first (the record keeps the login).
# Not covered: a PR already in a branch-protection merge queue (not visible over REST; pause the
# queue in the ruleset or dequeue it), and a bot or session that merges directly: tell those
# sessions, and keep sweeping.
# Records: <state dir>/FREEZE (`<iso>\t<reason>`), <state dir>/freeze-disarmed
# (`pr\tmethod\thead\tarmed_by\tdisarmed_at`, one row per PR, the first disarm wins), and one line
# per action in <state dir>/freeze.log.
# Exit: 0 ok | 2 usage | 3 not frozen (sweep, end, status) | 5 a GitHub read or write failed, or a
#       PR is still armed after its disarm | 6 GitHub refused the auto-merge mutation (GraphQL):
#       the owner action is printed
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  start | sweep | end | status) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" reason="" rearm=yes
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --no-rearm) rearm=no; shift ;;
    *) echo "freeze.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
flag="$state/FREEZE" rec="$state/freeze-disarmed" logf="$state/freeze.log"
now_iso=$(orch_iso "$(orch_now)")
log() { printf '%s\t%s\n' "$now_iso" "$*" >>"$logf"; }
frozen_or_exit() { [[ -f "$flag" ]] || { echo "not frozen: no $flag"; exit 3; }; }

# refused STDERR: GitHub refusing the mutation (GraphQL refused, or forbidden), not a passing failure.
# gh's "(https://api.github.com/graphql)" suffix alone does not count: it ends every GraphQL error.
refused() { [[ "$1" == *GraphQL* || "$1" == *"HTTP 403"* || "$1" == *[Ff]orbidden* ]]; }

# pull N -> `state\tmerged\tarmed\tmethod` for PR N, read over REST.
pull() {
  local j
  j=$(orch_read_retry 3 gh api "repos/$repo/pulls/$1" </dev/null) || return 1
  jq -r '[.state, (.merged_at != null | tostring), (.auto_merge != null | tostring), (.auto_merge.merge_method // "-")] | @tsv' <<<"$j"
}

owner_action() { # VERB LIST HINT
  echo "owner action: GitHub refused the $1 here (GraphQL-only on GitHub). $1 PRs$2 elsewhere" \
    "(GitHub MCP $3, or a local session), then run freeze.sh ${cmd} again to verify."
}

sweep() {
  local list n method head by out rc=0 err bad="" fail=0 row armed count=0
  if ! list=$(orch_read_retry 3 gh api --paginate "repos/$repo/pulls?state=open&per_page=100" </dev/null) ||
    ! list=$(jq -r '.[] | select(.auto_merge != null) |
        [.number, (.auto_merge.merge_method // "merge"), .head.sha, (.auto_merge.enabled_by.login // "-")] | @tsv' <<<"$list"); then
    echo "error: could not list the open PRs of $repo over REST"; exit 5
  fi
  while IFS=$'\t' read -r n method head by; do
    [[ -n "$n" ]] || continue
    count=$((count + 1))
    if ! awk -F'\t' -v n="$n" '$1 == n { f = 1 } END { exit !f }' "$rec" 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$method" "$head" "$by" "$now_iso" >>"$rec"
    fi
    rc=0
    out=$(gh pr merge "$n" --repo "$repo" --disable-auto </dev/null 2>&1) || rc=$?
    if ((rc != 0)); then
      err=$(printf '%s' "$out" | tr '\n' ' ')
      if refused "$err"; then bad+=" #$n"; log "pr=$n disarm refused: $err"
      else fail=1; log "pr=$n disarm failed: $err"; echo "error: disarming PR $n failed: $err"; fi
      continue
    fi
    if ! row=$(pull "$n"); then fail=1; echo "error: PR $n could not be read back"; continue; fi
    IFS=$'\t' read -r _ _ armed _ <<<"$row"
    if [[ "$armed" == true ]]; then fail=1; echo "error: PR $n is still armed after --disable-auto"; continue; fi
    log "pr=$n disarmed method=$method head=$head armed_by=$by"
    echo "disarmed: #$n (method $method, armed by $by)"
  done <<<"$list"
  ((count > 0)) || echo "swept: no open PR has auto-merge armed"
  if [[ -n "$bad" ]]; then
    echo "refused: still armed:$bad"
    owner_action "auto-merge disable" "$bad" "disable_pr_auto_merge"
    exit 6
  fi
  ((fail == 0)) || exit 5
}

case "$cmd" in
  start)
    if [[ -f "$flag" ]]; then
      echo "already frozen since:$(cut -f1 "$flag")"
    else
      printf '%s\t%s\n' "$now_iso" "${reason:--}" >"$flag" || { echo "error: could not write $flag"; exit 5; }
      log "freeze started reason=${reason:--}"
      echo "frozen: every merge path holds every PR until freeze.sh end"
    fi
    sweep
    ;;
  sweep) frozen_or_exit; sweep ;;
  status)
    frozen_or_exit
    IFS=$'\t' read -r since why <"$flag"
    echo "frozen since:$since reason=${why:--}"
    if [[ -f "$rec" ]]; then
      while IFS=$'\t' read -r n method _ by at; do echo "#$n disarmed:$at method:$method armed_by:$by"; done <"$rec"
    fi
    ;;
  end)
    frozen_or_exit
    keep="" bad="" fail=0
    if [[ -f "$rec" && "$rearm" == no ]]; then
      while IFS=$'\t' read -r n method _ _ _; do echo "not re-armed: #$n (method $method)"; done <"$rec"
      log "re-arm skipped (--no-rearm): $(cut -f1 "$rec" | tr '\n' ' ')"
    elif [[ -f "$rec" ]]; then
      while IFS=$'\t' read -r n method head by at; do
        [[ -n "$n" ]] || continue
        line=$(printf '%s\t%s\t%s\t%s\t%s' "$n" "$method" "$head" "$by" "$at")
        if ! row=$(pull "$n"); then fail=1 keep+="$line"$'\n'; echo "error: PR $n could not be read"; continue; fi
        IFS=$'\t' read -r st merged armed _ <<<"$row"
        if [[ "$merged" == true || "$st" != open ]]; then echo "skipped: #$n is $([[ "$merged" == true ]] && echo merged || echo "$st")"; log "pr=$n not re-armed: $st"; continue; fi
        if [[ "$armed" == true ]]; then echo "re-armed: #$n (already armed)"; log "pr=$n already armed"; continue; fi
        case "$method" in merge | squash | rebase) ;; *) method=merge ;; esac
        rc=0
        out=$(gh pr merge "$n" --repo "$repo" --auto "--$method" </dev/null 2>&1) || rc=$?
        if ((rc != 0)); then
          err=$(printf '%s' "$out" | tr '\n' ' ')
          keep+="$line"$'\n'
          if refused "$err"; then bad+=" #$n(--$method)"; log "pr=$n re-arm refused: $err"
          else fail=1; log "pr=$n re-arm failed: $err"; echo "error: re-arming PR $n failed: $err"; fi
          continue
        fi
        log "pr=$n re-armed method=$method"
        echo "re-armed: #$n (method $method; was armed by $by)"
      done <"$rec"
      if [[ -n "$keep" ]]; then
        printf '%s' "$keep" >"$rec.tmp.$$" && mv "$rec.tmp.$$" "$rec"
        echo "still frozen: $(printf '%s' "$keep" | cut -f1 | tr '\n' ' ')not re-armed"
        if [[ -n "$bad" ]]; then owner_action "auto-merge enable" "$bad" "enable_pr_auto_merge"; exit 6; fi
        exit 5
      fi
    fi
    rm -f "$rec" "$flag"
    log "freeze ended"
    echo "unfrozen: merges resume"
    ;;
esac
