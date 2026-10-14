#!/usr/bin/env bash
# Exclusive lock on the host's test devices (emulators, simulators, attached hardware), shared by
# verification batches, discovery routines and anything else that drives a device.
#
# Usage: device-lock.sh <claim|release|status> --name WHO [--pid PID | --no-pid] [--token T]
#                       [--path FILE | --state-dir DIR | --repo OWNER/REPO] [--stale-hours N]
#   claim    exit 0 when WHO now holds the lock (prints "claimed", then "token <T>"); 3 when a live
#            holder has it
#   release  removes the lock when --token matches the holder's token, or when WHO is the holder's
#            name (a wrong --token is always refused); otherwise prints "not held by WHO", exit 0
#   status   free | held name=<who> pid=<pid> age=<seconds> live=<yes|no>
# Lock file: line 1 "<pid> <ISO-8601 UTC timestamp> <name>" (an epoch timestamp is also read; this
# is the original format); line 2 "token=<T> start=<process start time>" (absent in old locks).
# A lock is stale (reclaimable by anyone) when its PID is dead, the PID now belongs to a different
# process (start time differs: PID reuse), or it is older than --stale-hours (default 9).
# --pid should be a durable process (the session's long-lived shell), not a command substitution;
# it defaults to this script's parent. --no-pid records no holder PID, so liveness is decided by
# age alone (use it when the claiming shell is short-lived, e.g. a subshell); release such a lock
# with its token or name.
# Lock path, first match: --path; --state-dir DIR or $ORCHESTRATE_DEVICE_LOCK_DIR (DIR/device.lock);
# --repo, or the current checkout's repo (<state dir>/<owner>__<repo>/device.lock); outside any repo,
# <$ORCHESTRATE_STATE_DIR or ~/.claude/orchestrate>/device.lock. Never kills any process.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
name="" pid=$PPID path="" repo="" stale=9 token="" sdir=""
while (($#)); do
  case "$1" in
    --name) name=$2; shift 2 ;;
    --pid) pid=$2; shift 2 ;;
    --no-pid) pid=0; shift ;;
    --token) token=$2; shift 2 ;;
    --path) path=$2; shift 2 ;;
    --state-dir) sdir=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --stale-hours) stale=$2; shift 2 ;;
    *) echo "device-lock.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in claim | release | status) ;; *) sed -n '2,20p' "$0" >&2; exit 2 ;; esac
[[ "$cmd" != claim || -n "$name" ]] || { echo "device-lock.sh: --name is required" >&2; exit 2; }
[[ "$cmd" != release || -n "$name" || -n "$token" ]] || { echo "device-lock.sh: --name or --token is required" >&2; exit 2; }
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "device-lock.sh: --pid must be a number" >&2; exit 2; }

if [[ -z "$path" ]]; then
  [[ -n "$sdir" ]] || sdir=${ORCHESTRATE_DEVICE_LOCK_DIR:-}
  if [[ -n "$sdir" ]]; then
    mkdir -p "$sdir"
    path="$sdir/device.lock"
  elif r=$(orch_repo "$repo" 2>/dev/null) && [[ -n "$r" ]]; then
    path="$(orch_state_dir "$r")/device.lock"
  else
    d=${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}
    mkdir -p "$d"
    path="$d/device.lock"
  fi
fi

# Process start time, or empty when the process does not exist.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//; s/  */ /g' || true; }

# Sets h_pid h_at h_name h_token h_start age live from the lock file; returns 1 when there is no lock.
read_lock() {
  [[ -f "$path" ]] || return 1
  h_pid="" h_at="" h_name="" h_token="" h_start=""
  { read -r h_pid h_at h_name || true; read -r extra || true; } <"$path"
  if [[ "${extra:-}" == token=* ]]; then
    h_token=${extra#token=}
    h_token=${h_token%% *}
    [[ "$extra" == *" start="* ]] && h_start=${extra#* start=}
  fi
  local at=${h_at:-0}
  [[ "$at" =~ ^[0-9]+$ ]] || at=$(jq -rn --arg t "$at" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null || echo 0)
  age=$(($(orch_now) - at))
  live=yes
  if ((age > stale * 3600)); then
    live=no
  elif [[ "${h_pid:-0}" =~ ^[0-9]+$ ]] && ((h_pid > 0)); then
    if ! kill -0 "$h_pid" 2>/dev/null; then
      live=no
    elif [[ -n "$h_start" && "$(proc_start "$h_pid")" != "$h_start" ]]; then
      live=no # PID was reused by an unrelated process
    fi
  fi
}

# Serialize read-modify-write sections with a mkdir mutex; a guard whose owner died is broken.
guard="$path.guard"
take_guard() {
  local owner
  for _ in $(seq 1 100); do
    if mkdir "$guard" 2>/dev/null; then echo $$ >"$guard/pid"; return 0; fi
    owner=$(cat "$guard/pid" 2>/dev/null || echo "")
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$guard"; continue; fi
    sleep 0.05
  done
  echo "device-lock.sh: could not take $guard" >&2
  return 1
}
drop_guard() { rm -rf "$guard"; }

case "$cmd" in
  status)
    if read_lock; then echo "held name=$h_name pid=$h_pid age=$age live=$live"; else echo free; fi
    ;;
  claim)
    take_guard || exit 3
    trap drop_guard EXIT
    if read_lock; then
      if [[ "$live" == yes && "$h_name" != "$name" ]]; then echo "held by $h_name (pid $h_pid, ${age}s)"; exit 3; fi
      rm -f "$path"
    fi
    new_token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    start=""
    ((pid == 0)) || start=$(proc_start "$pid")
    if (set -o noclobber; printf '%s %s %s\ntoken=%s start=%s\n' "$pid" "$(orch_iso "$(orch_now)")" "$name" "$new_token" "$start" >"$path") 2>/dev/null &&
      read_lock && [[ "$h_name" == "$name" && "$h_pid" == "$pid" ]]; then
      echo "claimed"
      echo "token $new_token"
    else
      echo "lost the race for $path"; exit 3
    fi
    ;;
  release)
    take_guard || exit 3
    trap drop_guard EXIT
    if ! read_lock; then echo "not held by ${name:-token}"; exit 0; fi
    if [[ -n "$token" && "$h_token" != "$token" ]]; then echo "token does not match the holder"; exit 0; fi
    if [[ -n "$token" || "$h_name" == "$name" ]]; then rm -f "$path"; echo "released"; else echo "not held by $name"; fi
    ;;
esac
