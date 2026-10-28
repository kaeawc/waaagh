#!/usr/bin/env bash
# Host-wide counting semaphores for gate-slot.sh and heavy-build-slot.sh. Source, do not execute.
# A slot is a directory (mkdir is atomic) holding "holder": three lines, PID, process start time, label.
# A holder whose PID is gone, or whose PID now belongs to a different process (start time differs),
# is stale: its slot is renamed away atomically (mv) and taken, so two reclaimers cannot both win.
# Nothing here kills a process.

slot_root() { echo "${ORCHESTRATE_SLOT_DIR:-${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/slots}"; }

proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//; s/  */ /g' || true; }

# slot_live DIR: the slot's holder is a running process (the same one that claimed it).
slot_live() {
  local pid start
  [[ -f "$1/holder" ]] || return 1
  pid=$(sed -n 1p "$1/holder")
  start=$(sed -n 2p "$1/holder")
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  [[ "$(proc_start "$pid")" == "$start" ]]
}

# slot_try POOL N PID LABEL: take a free (or stale) slot of POOL for PID; prints the slot dir.
slot_try() {
  local pool n=$2 pid=$3 label=$4 i d
  pool="$(slot_root)/$1"
  mkdir -p "$pool"
  for ((i = 1; i <= n; i++)); do
    d="$pool/slot-$i"
    if [[ -d "$d" ]] && ! slot_live "$d"; then
      # Created this instant and not yet written? Leave it to its owner.
      if [[ -f "$d/holder" ]] || [[ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
        local tomb="$pool/.stale-$i-$$-$RANDOM"
        if mv "$d" "$tomb" 2>/dev/null; then rm -rf "$tomb"; fi
      fi
    fi
    if mkdir "$d" 2>/dev/null; then
      # Written aside and renamed in, so no reader ever sees a half-written holder.
      printf '%s\n%s\n%s\n' "$pid" "$(proc_start "$pid")" "$label" >"$d/.holder" && mv "$d/.holder" "$d/holder"
      echo "$d"
      return 0
    fi
  done
  return 1
}

# slot_busy POOL N: how many slots of POOL a live process holds.
slot_busy() {
  local pool n=$2 i c=0
  pool="$(slot_root)/$1"
  for ((i = 1; i <= n; i++)); do slot_live "$pool/slot-$i" && c=$((c + 1)); done
  echo "$c"
}

# slot_release DIR PID: free the slot if PID still holds it.
slot_release() {
  local pid
  [[ -n "${1:-}" && -f "$1/holder" ]] || return 0
  pid=$(sed -n 1p "$1/holder")
  [[ "$pid" == "$2" ]] && rm -rf "$1"
  return 0
}

# Waits poll every SLOT_POLL seconds (default 2) up to a deadline; nothing waits unbounded.
slot_sleep() { sleep "${SLOT_POLL:-2}"; }
