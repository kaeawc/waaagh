#!/usr/bin/env bash
# The host's traveling-mode toggle (traveling-mode.md, "Toggle on the host"): hand a campaign to
# the cloud orchestrator before the host goes offline, and take it back on return. Run it on the
# host, as the owner. A dry run by default: --apply does it. Never force-pushes.
#
# Usage: travel.sh <enter|exit|status> --repo OWNER/REPO [--repo ...] --store DIR [--app-id N]
#                  [--runner-var NAME] [--files LIST] [--apply]
#   enter   for each repository, in order: refuse while its merge loop beat in the last 15 minutes
#           or a live device lock is held; copy the campaign ledgers (--files) from the host's
#           state dir into the store; refuse if anything there resembles a credential; set
#           MODE=traveling with a free lease and push; set the --runner-var repository variable to
#           false (its old value is kept in the store, runner-var); turn the travel guard on
#           (travel-guard.sh on, needs --app-id or WAAAGH_APP_ID); write the host's TRAVELING
#           marker. Then the owner enables the routines.
#   exit    the owner disables the routines first. Then for each repository: refuse while a cloud
#           run holds an unexpired lease; take the lease as the host, set MODE=local and push; back
#           up the host's ledgers to travel-backup-<time>/ and copy the store's back; turn the
#           travel guard off; restore --runner-var; remove the marker; release the lease. Then the
#           owner restarts the host loops.
#   status  the marker, the merge loop's heartbeat age, the device lock, the store's MODE and
#           LEASE, the runner variable and the travel guard, one line each per repository
#   --store  a checkout of the state store (kaeawc/orchestrate-state)
#   --files  space-separated names in the state dir that travel (default: the ledgers waaagh's
#            scripts read: reviews.tsv holds holds.log decisions.md campaign.json
#            cloud-sessions.tsv check-domains failure-signatures.tsv learnings)
# The host's state dir is <ORCHESTRATE_STATE_DIR or ~/.claude/orchestrate>/<owner>__<repo>.
# Repository variables and rulesets need admin, so gh runs as the owner (WAAAGH_GH_SHIM=off).
# Exit: 0 done (or the dry run printed) | 3 refused (a loop, a device, a cloud lease, a secret) or
#   a step failed | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high
export WAAAGH_GH_SHIM=off

op=${1:-}
case "$op" in enter | exit | status) shift ;; -h | --help) orch_usage; exit 0 ;; *) orch_usage >&2; exit 2 ;; esac
repos=() store="" app=${WAAAGH_APP_ID:-} runner_var="" apply=no
files="reviews.tsv holds holds.log decisions.md campaign.json cloud-sessions.tsv check-domains failure-signatures.tsv learnings"
while (($#)); do
  case "$1" in
    --repo) repos+=("${2:-}"); shift 2 ;;
    --store) store=${2:-}; shift 2 ;;
    --app-id) app=${2:-}; shift 2 ;;
    --runner-var) runner_var=${2:-}; shift 2 ;;
    --files) files=${2:-}; shift 2 ;;
    --apply) apply=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "travel.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
((${#repos[@]})) || { echo "travel.sh: at least one --repo" >&2; exit 2; }
for r in "${repos[@]}"; do [[ "$r" == */* ]] || { echo "travel.sh: --repo OWNER/REPO: $r" >&2; exit 2; }; done
[[ -n "$store" && -d "$store/.git" ]] || { echo "travel.sh: --store must be a checkout of the state store" >&2; exit 2; }
[[ "$op" != enter || "$app" =~ ^[1-9][0-9]*$ ]] || { echo "travel.sh: enter needs --app-id (or WAAAGH_APP_ID) for the travel guard" >&2; exit 2; }
[[ -z "$runner_var" || "$runner_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "travel.sh: bad --runner-var" >&2; exit 2; }

root=$(orch_state_root)
now=$(orch_now)
stamp=$(orch_iso "$now" | tr -d ':-')
ts() { orch_run travel-store.sh "$@" --store "$store" --repo "$r"; }
step() { if [[ "$apply" == yes ]]; then echo "$r: $1"; else echo "$r: would $1"; fi; }
refuse() { echo "$r: refused: $1" >&2; exit 3; }
# beat_age SD: seconds since the freshest merge-loop heartbeat in SD, or empty when none.
beat_age() {
  local f t best=""
  for f in "$1"/loops/*.heartbeat "$1/merge-loop.heartbeat" "$1/merge-loop.beat"; do
    [[ -f "$f" ]] || continue
    t=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
    [[ -z "$best" || "$t" -gt "$best" ]] && best=$t
  done
  [[ -z "$best" ]] || echo $(( $(date +%s) - best ))
}
lock_state() { orch_run device-lock.sh status --name travel --state-dir "$1" 2>/dev/null | head -1 || echo unknown; }
var_value() { gh variable get "$runner_var" --repo "$r" 2>/dev/null || echo "(unset)"; }

for r in "${repos[@]}"; do
  ns=${r//\//__} sd="$root/$ns" sto="$store/$ns"
  case "$op" in
    status)
      m=$([[ -f "$sd/TRAVELING" ]] && echo "TRAVELING since $(cat "$sd/TRAVELING")" || echo "no marker")
      age=$(beat_age "$sd"); age=${age:+${age}s ago}
      echo "$r: $m; merge loop beat ${age:-never}; device lock $(lock_state "$sd")"
      echo "$r: store MODE=$(ts mode 2>/dev/null || echo unreadable) $(ts lease show 2>/dev/null || echo 'LEASE unreadable')"
      [[ -z "$runner_var" ]] || echo "$r: $runner_var=$(var_value)"
      echo "$r: travel guard $(orch_run travel-guard.sh status --repo "$r" 2>/dev/null || echo unreadable)" ;;
    enter)
      age=$(beat_age "$sd")
      [[ -z "$age" || "$age" -ge 900 ]] || refuse "the merge loop beat ${age}s ago: stop the host loops first"
      [[ "$(lock_state "$sd")" != *live=yes* ]] || refuse "a live device lock is held ($(lock_state "$sd"))"
      [[ "$(ts mode)" != traveling ]] || refuse "the store already says MODE=traveling"
      # Copy the ledgers into the store, then scan them before anything is pushed.
      mkdir -p "$sto"
      copied=""
      for f in $files; do
        [[ -e "$sd/$f" ]] || continue
        copied="$copied $f"
        [[ "$apply" == no ]] || cp -R "$sd/$f" "$sto/"
      done
      step "copy${copied:- nothing} into the store"
      if [[ "$apply" == yes ]]; then
        ts scan >/dev/null || { ts scan || true; git -C "$store" checkout -q -- "$ns" 2>/dev/null || true; git -C "$store" clean -fdq -- "$ns" 2>/dev/null || true; refuse "something in the state resembles a credential; nothing was pushed"; }
        ts lease take --holder host --ttl 600 >/dev/null || refuse "the store's lease is held"
        ts push >/dev/null
        ts set-mode traveling >/dev/null
        ts lease release --holder host >/dev/null
      fi
      step "set MODE=traveling with a free lease, and push"
      if [[ -n "$runner_var" ]]; then
        old=$(var_value)
        step "set $runner_var=false (was $old)"
        if [[ "$apply" == yes ]]; then
          echo "$runner_var=$old" >"$sto/runner-var"; ts push >/dev/null
          gh variable set "$runner_var" --body false --repo "$r" >/dev/null || refuse "could not set $runner_var"
        fi
      fi
      step "turn the travel guard on"
      [[ "$apply" == no ]] || orch_run travel-guard.sh on --repo "$r" --app-id "$app" || refuse "travel-guard.sh on failed"
      step "write the TRAVELING marker"
      [[ "$apply" == no ]] || { mkdir -p "$sd"; orch_iso "$now" >"$sd/TRAVELING"; } ;;
    exit)
      lease=$(ts lease show)
      holder=$(sed -nE 's/.*holder=([^ ]*).*/\1/p' <<<"$lease") expires=$(sed -nE 's/.*expires=([0-9]+).*/\1/p' <<<"$lease")
      [[ "$holder" != cloud-run:* ]] || ((${expires:-0} <= now)) || refuse "a cloud run holds the lease until $(orch_iso "$expires"): disable the routines and wait"
      if [[ "$apply" == yes ]]; then
        ts lease take --holder host --ttl 3600 >/dev/null || refuse "could not take the store's lease"
        ts set-mode local >/dev/null
      fi
      step "take the lease as the host and set MODE=local"
      step "back up the host's ledgers to travel-backup-$stamp/ and copy the store's back"
      if [[ "$apply" == yes ]]; then
        mkdir -p "$sd/travel-backup-$stamp"
        for f in $files; do
          [[ ! -e "$sd/$f" ]] || cp -R "$sd/$f" "$sd/travel-backup-$stamp/"
          [[ ! -e "$sto/$f" ]] || cp -R "$sto/$f" "$sd/"
        done
      fi
      step "turn the travel guard off"
      [[ "$apply" == no ]] || orch_run travel-guard.sh off --repo "$r" || refuse "travel-guard.sh off failed"
      if [[ -n "$runner_var" ]]; then
        old=$(sed -nE "s/^$runner_var=//p" "$sto/runner-var" 2>/dev/null || true)
        if [[ -z "$old" || "$old" == "(unset)" ]]; then
          step "delete $runner_var (it was unset before the trip)"
          [[ "$apply" == no ]] || gh variable delete "$runner_var" --repo "$r" >/dev/null 2>&1 || true
        else
          step "set $runner_var=$old again"
          [[ "$apply" == no ]] || gh variable set "$runner_var" --body "$old" --repo "$r" >/dev/null || refuse "could not restore $runner_var"
        fi
      fi
      step "remove the TRAVELING marker and release the lease"
      if [[ "$apply" == yes ]]; then rm -f "$sd/TRAVELING"; ts lease release --holder host >/dev/null; fi ;;
  esac
done
dry=""; [[ "$apply" == yes ]] || dry="; this was a dry run: --apply does it"
case "$op" in
  enter) echo "next: enable the orchestrator and worker routines (roles/cloud-orchestrator.md)$dry" ;;
  exit) echo "next: restart the host loops (loops.sh status)$dry" ;;
esac
