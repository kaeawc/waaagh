#!/usr/bin/env bash
# Run one heavy native build (Gradle, Xcode) alone on this host: one heavy build at a time, and only
# once running gates have drained; gate-slot.sh starts no new gate meanwhile. Caps Gradle workers.
#
# Usage: heavy-build-slot.sh [--wait SECONDS] [--workers N] [--label TEXT] [--env-file FILE] -- CMD...
#   --wait     longest wait for the slot and for gates to drain (default $ORCHESTRATE_HEAVY_WAIT or
#              3600); then exit 75 and the slot is released
#   --workers  org.gradle.workers.max, added to GRADLE_OPTS (default $HEAVY_BUILD_WORKERS or 2)
#   --env-file sourced before CMD, as in gate-slot.sh
# Re-entrant (#313): called from inside a command a heavy build is already running, it takes no slot
# and runs CMD in its ancestor's. Called from inside a gate's command, it marks that gate parked
# (the gate only waits on this build), so neither this build nor another gate's waits for it; work
# the gate runs beside this call is then not held back.
# The build gets lane-private output as every gate does (#213, _build_dirs.sh): Xcode derived data
# (-derivedDataPath), Gradle's --project-cache-dir, TMPDIR and XDG_CACHE_HOME under
# ORCHESTRATE_LANE_BUILD_DIR, from the build-dirs table, before --env-file is sourced.
# Gradle runs without a long-lived daemon (#318): -Dorg.gradle.daemon=false is added to GRADLE_OPTS
# unless GRADLE_OPTS already sets org.gradle.daemon or HEAVY_BUILD_GRADLE_DAEMON=1. A daemon outlives
# the command that started it and keeps that command's sandbox and JDK path; every later build from
# any lane reconnects to it.
# A Gradle command that fails (#335): spectra is asked (`spectra jvm --json`, required) for a
# Gradle or Kotlin daemon whose JDK is gone (java_home_missing or executable_deleted; the Kotlin
# daemon is reused even by a Gradle run with no daemon of its own), and each is named on stderr
# with its PID and missing java.home: such a daemon fails every build that reconnects to it, so the
# failure is likely the daemon, not the change. Nothing is stopped here.
# Exit: CMD's exit code | 75 not started within --wait | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
# shellcheck source=_slots.sh
source "$here/_slots.sh"
# shellcheck source=_build_dirs.sh
source "$here/_build_dirs.sh"

wait_s=${ORCHESTRATE_HEAVY_WAIT:-3600} workers=${HEAVY_BUILD_WORKERS:-2} label=heavy-build env_file=""
gate_slots=${ORCHESTRATE_GATE_SLOTS:-3}
while (($#)); do
  case "$1" in
    --wait) wait_s=$2; shift 2 ;;
    --workers) workers=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --env-file) env_file=$2; shift 2 ;;
    --) shift; break ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "heavy-build-slot.sh: unknown argument: $1 (put the command after --)" >&2; exit 2 ;;
  esac
done
(($#)) || { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" >&2; exit 2; }
[[ "$wait_s" =~ ^[0-9]+$ && "$workers" =~ ^[1-9][0-9]*$ ]] || { echo "heavy-build-slot.sh: bad --wait or --workers" >&2; exit 2; }

deadline=$(($(date +%s) + wait_s)) slot="" parked=""
held=$(slot_held) || held=""
if [[ "$held" == heavy ]]; then
  # Nested in a heavy build: its slot, its worker cap. Waiting here would wait on this process's
  # own ancestor until --wait ran out, with every other lane's build queued behind it.
  echo "heavy-build-slot: already inside a heavy slot; running in it" >&2
else
  trap 'slot_release "$slot" $$; [[ -z "$parked" || "$(cat "$parked" 2>/dev/null || true)" != $$ ]] || rm -f "$parked"' EXIT
  if [[ "$held" == gate ]]; then
    parked="$ORCHESTRATE_SLOT_HELD/parked"
    echo $$ >"$parked" 2>/dev/null || parked=""
  fi
  until slot=$(slot_try heavy 1 $$ "$label"); do
    (($(date +%s) < deadline)) || { echo "heavy-build-slot: another heavy build holds the slot after ${wait_s}s" >&2; exit 75; }
    slot_sleep
  done
  # Holding the slot stops new gates; wait for the running ones to finish (not the parked ones:
  # each only waits on a heavy build of its own).
  while [[ "$(slot_busy_unparked gate "$gate_slots")" != 0 ]]; do
    (($(date +%s) < deadline)) || { echo "heavy-build-slot: gates still running after ${wait_s}s" >&2; exit 75; }
    slot_sleep
  done
  export GATE_SLOT_KIND=heavy GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-Dorg.gradle.workers.max=$workers"
  export ORCHESTRATE_SLOT_HELD="$slot" ORCHESTRATE_SLOT_HOLDER=$$
fi
build_dirs_apply "$@"
if [[ "${HEAVY_BUILD_GRADLE_DAEMON:-0}" != 1 && "${GRADLE_OPTS:-}" != *org.gradle.daemon=* ]]; then
  export GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-Dorg.gradle.daemon=false"
fi
rc=0
if [[ -n "$env_file" && -f "$env_file" ]]; then
  # shellcheck disable=SC2016  # expanded by the inner bash
  bash -c 'source "$1"; shift; "$@"' gate-env "$env_file" "${BUILD_ARGV[@]}" || rc=$?
else
  "${BUILD_ARGV[@]}" || rc=$?
fi
# stale_daemons: the Gradle and Kotlin daemons whose JDK spectra says is gone, one line each.
stale_daemons() {
  orch_spectra_require jvm 2>/dev/null || { echo "heavy-build-slot: spectra unavailable; could not check for a Gradle or Kotlin daemon on a missing JDK" >&2; return 0; }
  orch_spectra jvm --json 2>/dev/null | jq -r '.[]? | select((.main_class // "") | test("(GradleDaemon|KotlinCompileDaemon)$"))
    | select(.java_home_missing == true or .executable_deleted == true)
    | "heavy-build-slot: \(if (.main_class | test("Kotlin")) then "Kotlin" else "Gradle" end) daemon \(.pid) runs on a JDK that is gone (java.home \(.java_home // "?")\(if .executable_deleted then ", executable deleted" else "" end)): builds that reconnect to it fail, so this failure is likely the daemon. Let it idle out or stop PID \(.pid); never gradle --stop" ' >&2 2>/dev/null || true
}
if ((rc != 0)); then
  for w in "$@"; do
    case "$(basename -- "${w%% *}")" in gradle | gradlew) slot_release "$slot" $$; stale_daemons; break ;; esac
  done
fi
exit "$rc"
