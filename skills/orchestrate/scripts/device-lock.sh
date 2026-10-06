#!/usr/bin/env bash
# Exclusive lock on the host's test devices (emulators, simulators, attached hardware), shared by
# verification batches, discovery routines and anything else that drives a device.
#
# Usage: device-lock.sh <claim|release|status> --name WHO [--pid PID] [--path FILE | --repo OWNER/REPO]
#                       [--stale-hours N]
#   claim    exit 0 when WHO now holds the lock; 3 when a live holder has it
#   release  removes the lock only when WHO holds it
#   status   free | held name=<who> pid=<pid> age=<seconds> live=<yes|no>
# Lock content: "<pid> <ISO-8601 UTC timestamp> <name>" (an epoch timestamp is also read). A lock is stale when its PID is dead or it is older than
# --stale-hours (default 9). --pid must be a durable process (the session's long-lived shell), not a
# command substitution; it defaults to this script's parent. Default path: <state dir>/device.lock.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
name="" pid=$PPID path="" repo="" stale=9
while (($#)); do
  case "$1" in
    --name) name=$2; shift 2 ;;
    --pid) pid=$2; shift 2 ;;
    --path) path=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --stale-hours) stale=$2; shift 2 ;;
    *) echo "device-lock.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in claim | release | status) ;; *) sed -n '2,13p' "$0" >&2; exit 2 ;; esac
[[ -n "$name" || "$cmd" == status ]] || { echo "device-lock.sh: --name is required" >&2; exit 2; }
[[ -n "$path" ]] || path="$(orch_state_dir "$(orch_repo "$repo")")/device.lock"

# Sets h_pid h_at h_name age live from the lock file; returns 1 when there is no lock.
read_lock() {
  [[ -f "$path" ]] || return 1
  read -r h_pid h_at h_name <"$path" || true
  local at=${h_at:-0}
  [[ "$at" =~ ^[0-9]+$ ]] || at=$(jq -rn --arg t "$at" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null || echo 0)
  age=$(($(orch_now) - at))
  live=yes
  if ! kill -0 "${h_pid:-0}" 2>/dev/null || ((age > stale * 3600)); then live=no; fi
}

case "$cmd" in
  status)
    if read_lock; then echo "held name=$h_name pid=$h_pid age=$age live=$live"; else echo free; fi
    ;;
  claim)
    if read_lock; then
      if [[ "$live" == yes && "$h_name" != "$name" ]]; then echo "held by $h_name (pid $h_pid, ${age}s)"; exit 3; fi
      rm -f "$path"
    fi
    if (set -o noclobber; printf '%s %s %s\n' "$pid" "$(orch_iso "$(orch_now)")" "$name" >"$path") 2>/dev/null &&
      read_lock && [[ "$h_name" == "$name" && "$h_pid" == "$pid" ]]; then
      echo "claimed"
    else
      echo "lost the race for $path"; exit 3
    fi
    ;;
  release)
    if read_lock && [[ "$h_name" == "$name" ]]; then rm -f "$path"; echo "released"; else echo "not held by $name"; fi
    ;;
esac
