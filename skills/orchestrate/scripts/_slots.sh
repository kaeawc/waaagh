#!/usr/bin/env bash
# Host-wide counting semaphores for gate-slot.sh and heavy-build-slot.sh, and the process-cwd
# listing host-load.sh and wt-cleanup.sh share. Source, do not execute.
# A slot is a directory (mkdir is atomic) holding "holder": three lines, PID, process start time, label.
# A holder whose PID is gone, or whose PID now belongs to a different process (start time differs),
# is stale: its slot is renamed away atomically (mv) and taken. A live PID whose start time cannot be
# read (ps failed under load, now or at claim time) is live: nothing sweeps a slot it cannot disprove.
# Sweeping and claiming run under a per-pool lock (POOL/.lock, a mkdir lock holding the claimer's
# PID), so a sweeper never acts on a verdict about a slot that was claimed since (#236). A lock whose
# PID is dead, or that is over a minute old, is broken. The holder is hard-linked into place (ln
# fails if one exists), and a claim whose slot vanished mid-write retries instead of running unslotted.
# Nothing here kills a process.

slot_root() { echo "${ORCHESTRATE_SLOT_DIR:-${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/slots}"; }

proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//; s/  */ /g' || true; }

# slot_live DIR: the slot's holder is a running process (the same one that claimed it, as far as
# can be told: a start time that cannot be read, then or now, does not make a live PID stale).
slot_live() {
  local pid start now
  [[ -f "$1/holder" ]] || return 1
  pid=$(sed -n 1p "$1/holder" 2>/dev/null || true)
  start=$(sed -n 2p "$1/holder" 2>/dev/null || true)
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  [[ -n "$start" ]] || return 0
  now=$(proc_start "$pid")
  [[ -z "$now" || "$now" == "$start" ]]
}

# slot_lock POOLDIR PID: take the pool's sweep/claim lock (about 1 s of tries); 1 if still busy.
slot_lock() {
  local lock="$1/.lock" owner tomb _ said=no
  for _ in $(seq 1 20); do
    if mkdir "$lock" 2>/dev/null; then
      echo "$2" >"$lock/pid"
      return 0
    fi
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if { [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; } ||
      [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      tomb="$1/.stale-lock-$$-$RANDOM"
      if mv "$lock" "$tomb" 2>/dev/null; then rm -rf "$tomb"; fi
      continue
    fi
    [[ "$said" == yes ]] || { slot_pause lockwait nowait; said=yes; }
    sleep 0.05
  done
  return 1
}

# slot_unlock POOLDIR PID: drop the pool lock if PID holds it.
slot_unlock() {
  [[ "$(cat "$1/.lock/pid" 2>/dev/null || true)" == "$2" ]] && rm -rf "$1/.lock"
  return 0
}

# slot_try POOL N PID LABEL: take a free (or stale) slot of POOL for PID; prints the slot dir.
slot_try() {
  local pool n=$2 pid=$3 label=$4 i d tomb _ lost rc=1
  pool="$(slot_root)/$1"
  mkdir -p "$pool"
  slot_lock "$pool" "$pid" || return 1
  for _ in 1 2 3; do
    lost=no
    for ((i = 1; i <= n; i++)); do
      d="$pool/slot-$i"
      if [[ -d "$d" ]] && ! slot_live "$d"; then
        # Holder-less and young: a claim still being written by someone who broke the lock. Leave it.
        if [[ -f "$d/holder" ]] || [[ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
          tomb="$pool/.stale-$i-$$-$RANDOM"
          slot_pause sweep
          if mv "$d" "$tomb" 2>/dev/null; then rm -rf "$tomb"; fi
        fi
      fi
      if mkdir "$d" 2>/dev/null; then
        slot_pause claim
        # Written aside and hard-linked in (ln fails if a holder exists), so no reader ever sees a
        # half-written holder and no claim overwrites another's.
        if { printf '%s\n%s\n%s\n' "$pid" "$(proc_start "$pid")" "$label" >"$d/.holder-$pid"; } 2>/dev/null &&
          ln "$d/.holder-$pid" "$d/holder" 2>/dev/null; then
          rm -f "$d/.holder-$pid"
          echo "$d"
          rc=0
          break 2
        fi
        rm -f "$d/.holder-$pid" 2>/dev/null || true
        lost=yes # the slot was swept out from under this claim: scan again
      fi
    done
    [[ "$lost" == yes ]] || break
  done
  slot_unlock "$pool" "$pid"
  return "$rc"
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
  pid=$(sed -n 1p "$1/holder" 2>/dev/null || true)
  [[ "$pid" == "$2" ]] && rm -rf "$1"
  return 0
}

# proc_cwds: one "PID<TAB>cwd" line per process this user can see (resolved paths). lsof first; a
# listing that lacks this shell's own cwd is not trusted (lsof can fail or time out silently), and
# /proc (ORCHESTRATE_PROC_DIR) is read instead. Returns 1 when neither gives an answer.
proc_cwds() {
  local out="" self proc=${ORCHESTRATE_PROC_DIR:-/proc} p d
  self=$(pwd -P)
  if command -v lsof >/dev/null 2>&1; then
    out=$(lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }' || true)
    if printf '%s\n' "$out" | awk -F'\t' -v s="$self" '$2 == s { f = 1 } END { exit !f }'; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  [[ -d "$proc/self" ]] || return 1
  for p in "$proc"/[0-9]*; do
    d=$(readlink "$p/cwd" 2>/dev/null) || continue
    printf '%s\t%s\n' "${p##*/}" "$d"
  done
  return 0
}

# slot_pause POINT [nowait]: test-only. With SLOT_TEST_PAUSE=POINT[,POINT...]:DIR naming POINT, mark
# DIR/POINT.reached and, unless nowait, wait (bounded, 10 s) for DIR/POINT.go.
# Points: sweep (stale verdict made, before the move), claim (slot dir made, before the holder),
# lockwait (pool lock found busy; never waits).
slot_pause() {
  local spec=${SLOT_TEST_PAUSE:-} _
  [[ "$spec" == *:* && ",${spec%%:*}," == *",$1,"* ]] || return 0
  touch "${spec#*:}/$1.reached"
  [[ "${2:-}" != nowait ]] || return 0
  for _ in $(seq 1 200); do [[ -e "${spec#*:}/$1.go" ]] && return 0; sleep 0.05; done
}

# Waits poll every SLOT_POLL seconds (default 2) up to a deadline; nothing waits unbounded.
slot_sleep() { sleep "${SLOT_POLL:-2}"; }
