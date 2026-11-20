#!/usr/bin/env bash
# Pace branch updates that start CI (GitHub update-branch, the merge queue's base-merge pushes), so
# a batch of them does not land at once on self-hosted runners that share this host with the lanes
# (#219: 27 update-branch calls in 30 minutes took the host load from 25 to 380 and broke device
# lanes). Nothing here sleeps: a paced update is deferred to the next pass, never waited for.
#
# Usage: update-pace.sh <gate|record|run|status> [--repo OWNER/REPO] [--cap N] [--gap SECONDS]
#                       [--host-gate|--no-host-gate]
#   gate    may one more update go now? `go` (exit 0) or `wait <reason>` (exit 3). --done N: updates
#           this pass already made, for the per-pass cap.
#   record  [--pr N] [--source TEXT]: log one update made now (the gap counts from the newest one);
#           a push with no PR yet is logged as PR `-`.
#   run     --pr N [--pr N]...: update those PRs, in the order given (put them in merge order), with
#           PUT repos/R/pulls/N/update-branch, gating before each. One line per PR:
#             updated <pr> | current <pr> (no new base commits: no CI started, not counted)
#             | failed <pr> <message> | deferred <pr> <reason> (this and every later PR wait for
#             the next pass; the first deferral stops the run, so the order is kept)
#   status  one line: last=<iso>|never pr=<n> cap=<n> gap=<s> host-gate=on|off next=<iso>|now
# Pacing (off unless configured: a repo whose CI runs on hosted runners loses nothing to a batch):
#   --cap N        at most N updates per pass (default $ORCHESTRATE_UPDATE_CAP, else 0 = no cap)
#   --gap SECONDS  at least this long between two updates, across passes and callers (default
#                  $ORCHESTRATE_UPDATE_GAP, else 0); with a gap, a pass makes at most one update
#   --host-gate    also wait while host-load.sh says HOLD or BACKOFF, or a heavy build holds its
#                  slot (heavy-build-slot.sh) (default on when ORCHESTRATE_UPDATE_HOST_GATE=1);
#                  ORCHESTRATE_UPDATE_HOST_ARGS adds host-load.sh flags (e.g. --load-factor 1)
# Set them for a repo whose CI runs on self-hosted runners on this host, e.g. in the campaign env:
#   ORCHESTRATE_UPDATE_CAP=3 ORCHESTRATE_UPDATE_GAP=600 ORCHESTRATE_UPDATE_HOST_GATE=1
# Log: <state dir>/branch-updates.log, TSV: epoch, pr, source (update-branch|merge-queue|...).
# Env: ORCHESTRATE_STATE_DIR, ORCHESTRATE_NOW (tests).
# Exit: 0 go / all done | 3 wait, or run deferred a PR | 5 run: an update failed (wins over 3)
#       | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
# shellcheck source=_slots.sh
source "$here/_slots.sh"
orch_gh_priority low

case "${1:-}" in -h | --help) orch_usage; exit 0 ;; -*) echo "update-pace.sh: unknown argument: $1" >&2; exit 2 ;; esac
cmd=${1:-}
case "$cmd" in
  gate | record | run | status) shift ;;
  *) orch_usage >&2; exit 2 ;;
esac

repo="" done_n=0 source_="" prs=()
cap=${ORCHESTRATE_UPDATE_CAP:-0} gap=${ORCHESTRATE_UPDATE_GAP:-0}
host_gate=off; [[ "${ORCHESTRATE_UPDATE_HOST_GATE:-0}" != 1 ]] || host_gate=on
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --cap) cap=$2; shift 2 ;;
    --gap) gap=$2; shift 2 ;;
    --host-gate) host_gate=on; shift ;;
    --no-host-gate) host_gate=off; shift ;;
    --done) done_n=$2; shift 2 ;;
    --pr) prs+=("$2"); shift 2 ;;
    --source) source_=$2; shift 2 ;;
    *) echo "update-pace.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in "$cap" "$gap" "$done_n"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "update-pace.sh: --cap, --gap and --done take a whole number: $v" >&2; exit 2; }
done
for p in ${prs[@]+"${prs[@]}"}; do
  [[ "$p" =~ ^[1-9][0-9]*$ ]] || { echo "update-pace.sh: bad --pr: $p" >&2; exit 2; }
done
case "$cmd" in
  record) ((${#prs[@]} <= 1)) || { echo "update-pace.sh: record takes at most one --pr" >&2; exit 2; } ;;
  run) ((${#prs[@]})) || { echo "update-pace.sh: run needs --pr" >&2; exit 2; } ;;
esac

repo=$(orch_repo "$repo")
log="$(orch_state_dir "$repo")/branch-updates.log"

# last_update -> "<epoch> <pr>" of the newest logged update, or nothing.
last_update() { [[ -f "$log" ]] && awk -F'\t' '$1 ~ /^[0-9]+$/ { t = $1; p = $2 } END { if (t != "") print t, p }' "$log" || true; }

# verdict DONE -> "go" or "wait <reason>" for one more update after DONE this pass.
verdict() {
  local now last lpr next hrc=0
  if ((cap > 0 && $1 >= cap)); then echo "wait cap: $1 of $cap updates made this pass"; return; fi
  now=$(orch_now)
  read -r last lpr <<<"$(last_update)"
  if ((gap > 0)) && [[ -n "${last:-}" ]] && ((now - last < gap)); then
    next=$((last + gap))
    echo "wait gap: last update (PR $lpr) $((now - last))s ago, gap ${gap}s, next=$(orch_iso "$next")"; return
  fi
  if [[ "$host_gate" == on ]]; then
    local -a hargs
    read -r -a hargs <<<"${ORCHESTRATE_UPDATE_HOST_ARGS:-}"
    orch_run host-load.sh --top 0 ${hargs[@]+"${hargs[@]}"} >/dev/null 2>&1 </dev/null || hrc=$?
    case "$hrc" in
      0) ;;
      3) echo "wait host: host-load.sh says HOLD"; return ;;
      4) echo "wait host: host-load.sh says BACKOFF"; return ;;
      *) echo "wait host: host-load.sh exit $hrc (unread, so held)"; return ;;
    esac
    if [[ "$(slot_busy heavy 1)" != 0 ]]; then echo "wait host: a heavy build holds its slot"; return; fi
  fi
  echo go
}

record() { printf '%s\t%s\t%s\n' "$(orch_now)" "$1" "$2" >>"$log"; }

case "$cmd" in
  gate)
    v=$(verdict "$done_n"); echo "$v"
    [[ "$v" == go ]] || exit 3 ;;
  record)
    p=${prs[0]:--}
    record "$p" "${source_:-update-branch}"; echo "recorded $p" ;;
  status)
    read -r last lpr <<<"$(last_update)"
    nxt=now
    if ((gap > 0)) && [[ -n "${last:-}" ]] && (($(orch_now) - last < gap)); then nxt=$(orch_iso "$((last + gap))"); fi
    printf 'last=%s pr=%s cap=%s gap=%s host-gate=%s next=%s\n' "$([[ -n "${last:-}" ]] && orch_iso "$last" || echo never)" \
      "${lpr:--}" "$cap" "$gap" "$host_gate" "$nxt" ;;
  run)
    n=0 failed=0 deferred=""
    for p in "${prs[@]}"; do
      if [[ -n "$deferred" ]]; then echo "deferred $p $deferred"; continue; fi
      v=$(verdict "$n")
      if [[ "$v" != go ]]; then deferred=${v#wait }; echo "deferred $p $deferred"; continue; fi
      # A write: gh-read.sh refuses it. No retry: a lost answer may have started the update anyway.
      rc=0
      out=$(gh api -X PUT "repos/$repo/pulls/$p/update-branch" 2>&1) || rc=$?
      if ((rc == 0)); then
        record "$p" "${source_:-update-branch}"; n=$((n + 1)); echo "updated $p"
      elif [[ "$out" == *"no new commits"* ]]; then
        echo "current $p"
      else
        failed=1; echo "failed $p $(awk 'NF { l = $0 } END { print l }' <<<"$out")"
      fi
    done
    ((failed == 0)) || exit 5
    [[ -z "$deferred" ]] || exit 3 ;;
esac
