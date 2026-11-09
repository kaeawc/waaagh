#!/usr/bin/env bash
# Exclusive lock on the host's test devices (emulators, simulators, attached hardware), shared by
# verification batches, discovery routines and anything else that drives a device.
#
# Usage: device-lock.sh <claim|release|status> --name WHO [--pid PID | --no-pid] [--token T]
#                       [--device ID]... [--path FILE | --state-dir DIR | --repo OWNER/REPO]
#                       [--stale-hours N]
#        device-lock.sh record --token T --device ID... [lock path flags]
#        device-lock.sh check (--name WHO | --token T) --device ID [--avd SUFFIX | --simulator]
#                             [lock path flags]
#   claim    exit 0 when WHO now holds the lock (prints "claimed", then "token <T>"); 3 when a live
#            holder has it. Each --device (an adb serial or a simulator UDID) is recorded as the
#            holder's device.
#   release  removes the lock when --token matches the holder's token, or when WHO is the holder's
#            name (a wrong --token is always refused); otherwise prints "not held by WHO", exit 0
#   status   free | held name=<who> pid=<pid> age=<seconds> live=<yes|no> [devices=<id,...>]
#   record   adds each --device to a live lock whose token is T (a simulator created after the
#            claim); prints "recorded <id,...>"; exit 4 when T does not hold a live lock
#   check    run before every adb or simctl command: exit 0 ("owned <ID> by <who>") only when a
#            live lock is held by WHO (or token T) and lists ID as its device; with --avd,
#            `adb -s ID emu avd name` must also end with SUFFIX; with --simulator, `xcrun simctl
#            list devices` must list ID. Otherwise prints "not owned: <reason>", exit 4
# Exit codes: 0 ok, 2 usage, 3 held by another agent (claim) or guard busy, 4 not the holder or
# not owned (record, check).
# Lock file: line 1 "<pid> <ISO-8601 UTC timestamp> <name>" (an epoch timestamp is also read; this
# is the original format); line 2 "token=<T> start=<process start time>" (absent in old locks);
# line 3 "devices=<id,...>" (only when devices are recorded).
# A lock is stale (reclaimable by anyone) when its PID is dead, the PID now belongs to a different
# process (start time differs: PID reuse), or it is older than --stale-hours (default 9).
# --pid should be a durable process (the session's long-lived shell), not a command substitution;
# it defaults to this script's parent. --no-pid records no holder PID, so liveness is decided by
# age alone (use it when the claiming shell is short-lived, e.g. a subshell); release such a lock
# with its token or name. A host whose lanes each own a device gives each device its own lock file
# (--path or --state-dir per device), named in the lane's brief.
# Lock path, first match: --path; --state-dir DIR or $ORCHESTRATE_DEVICE_LOCK_DIR (DIR/device.lock);
# --repo, or the current checkout's repo (<state dir>/<owner>__<repo>/device.lock); outside any repo,
# <$ORCHESTRATE_STATE_DIR or ~/.claude/orchestrate>/device.lock. Never kills any process.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

case "${1:-}" in -h | --help) orch_usage; exit 0 ;; -*) echo "device-lock.sh: unknown argument: $1" >&2; exit 2 ;; esac
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
name="" pid=$PPID path="" repo="" stale=9 token="" sdir="" devs="" avd="" sim=0
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
    --device)
      [[ "${2:-}" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "device-lock.sh: bad --device: ${2:-}" >&2; exit 2; }
      devs=${devs:+$devs,}$2; shift 2 ;;
    --avd) avd=$2; shift 2 ;;
    --simulator) sim=1; shift ;;
    *) echo "device-lock.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in claim | release | status | record | check) ;; *) orch_usage >&2; exit 2 ;; esac
[[ "$cmd" != claim || -n "$name" ]] || { echo "device-lock.sh: --name is required" >&2; exit 2; }
[[ "$cmd" != release || -n "$name" || -n "$token" ]] || { echo "device-lock.sh: --name or --token is required" >&2; exit 2; }
[[ "$cmd" != record || ( -n "$token" && -n "$devs" ) ]] || { echo "device-lock.sh: record needs --token and --device" >&2; exit 2; }
[[ "$cmd" != check || ( ( -n "$name" || -n "$token" ) && -n "$devs" && "$devs" != *,* ) ]] ||
  { echo "device-lock.sh: check needs --name or --token, and one --device" >&2; exit 2; }
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

# Sets h_pid h_at h_name h_token h_start h_devs age live from the lock file; returns 1 when there
# is no lock.
read_lock() {
  [[ -f "$path" ]] || return 1
  h_pid="" h_at="" h_name="" h_token="" h_start="" h_devs="" extra="" third=""
  { read -r h_pid h_at h_name || true; read -r extra || true; read -r third || true; } <"$path"
  if [[ "$third" == devices=* ]]; then h_devs=${third#devices=}; fi
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
    if read_lock; then echo "held name=$h_name pid=$h_pid age=$age live=$live${h_devs:+ devices=$h_devs}"; else echo free; fi
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
    fmt='%s %s %s\ntoken=%s start=%s\n'
    [[ -z "$devs" ]] || fmt="${fmt}devices=%s\\n"
    # shellcheck disable=SC2059 # the format is built above from fixed pieces
    if (set -o noclobber; printf "$fmt" "$pid" "$(orch_iso "$(orch_now)")" "$name" "$new_token" "$start" ${devs:+"$devs"} >"$path") 2>/dev/null &&
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
  record)
    take_guard || exit 3
    trap drop_guard EXIT
    if ! read_lock || [[ "$live" != yes || "$h_token" != "$token" ]]; then
      echo "not the holder: no live lock with that token"; exit 4
    fi
    all=$h_devs
    for d in ${devs//,/ }; do
      [[ ",$all," == *",$d,"* ]] || all=${all:+$all,}$d
    done
    { sed -n '1,2p' "$path"; echo "devices=$all"; } >"$path.tmp.$$" && mv "$path.tmp.$$" "$path"
    echo "recorded $all"
    ;;
  check)
    dev=$devs
    if ! read_lock || [[ "$live" != yes ]]; then echo "not owned: no live device lock at $path"; exit 4; fi
    if [[ -n "$token" && "$h_token" != "$token" ]] || [[ -z "$token" && "$h_name" != "$name" ]]; then
      echo "not owned: the lock is held by $h_name"; exit 4
    fi
    if [[ ",$h_devs," != *",$dev,"* ]]; then
      echo "not owned: $dev is not a device of $h_name (recorded: ${h_devs:-none})"; exit 4
    fi
    if [[ -n "$avd" ]]; then
      got=$(adb -s "$dev" emu avd name 2>/dev/null | sed -n '1{s/\r$//;p;}' || true)
      [[ -n "$got" ]] || { echo "not owned: adb could not read the AVD name of $dev"; exit 4; }
      [[ "$got" == *"$avd" ]] || { echo "not owned: $dev runs AVD $got, not *$avd"; exit 4; }
    fi
    if ((sim)); then
      list=$(xcrun simctl list devices 2>/dev/null || true)
      [[ "$list" == *"$dev"* ]] || { echo "not owned: simctl lists no simulator $dev"; exit 4; }
    fi
    echo "owned $dev by $h_name"
    ;;
esac
