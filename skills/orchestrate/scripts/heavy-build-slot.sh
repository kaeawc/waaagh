#!/usr/bin/env bash
# Run one heavy native build (Gradle, Xcode) alone on this host: one heavy build at a time, and only
# once running gates have drained; gate-slot.sh starts no new gate meanwhile. Caps Gradle workers.
#
# Usage: heavy-build-slot.sh [--wait SECONDS] [--workers N] [--label TEXT] [--env-file FILE] -- CMD...
#   --wait     longest wait for the slot and for gates to drain (default $ORCHESTRATE_HEAVY_WAIT or
#              3600); then exit 75 and the slot is released
#   --workers  org.gradle.workers.max, added to GRADLE_OPTS (default $HEAVY_BUILD_WORKERS or 2)
#   --env-file sourced before CMD, as in gate-slot.sh
# Do not call it from inside a gate slot: it waits for every gate to finish, its caller included.
# Exit: CMD's exit code | 75 not started within --wait | 2 usage
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_slots.sh
source "$here/_slots.sh"

wait_s=${ORCHESTRATE_HEAVY_WAIT:-3600} workers=${HEAVY_BUILD_WORKERS:-2} label=heavy-build env_file=""
gate_slots=${ORCHESTRATE_GATE_SLOTS:-3}
while (($#)); do
  case "$1" in
    --wait) wait_s=$2; shift 2 ;;
    --workers) workers=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --env-file) env_file=$2; shift 2 ;;
    --) shift; break ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "heavy-build-slot.sh: unknown argument: $1 (put the command after --)" >&2; exit 2 ;;
  esac
done
(($#)) || { sed -n '2,12p' "$0" >&2; exit 2; }
[[ "$wait_s" =~ ^[0-9]+$ && "$workers" =~ ^[1-9][0-9]*$ ]] || { echo "heavy-build-slot.sh: bad --wait or --workers" >&2; exit 2; }

deadline=$(($(date +%s) + wait_s)) slot=""
trap 'slot_release "$slot" $$' EXIT
until slot=$(slot_try heavy 1 $$ "$label"); do
  (($(date +%s) < deadline)) || { echo "heavy-build-slot: another heavy build holds the slot after ${wait_s}s" >&2; exit 75; }
  slot_sleep
done
# Holding the slot stops new gates; wait for the running ones to finish.
while [[ "$(slot_busy gate "$gate_slots")" != 0 ]]; do
  (($(date +%s) < deadline)) || { echo "heavy-build-slot: gates still running after ${wait_s}s" >&2; exit 75; }
  slot_sleep
done
export GATE_SLOT_KIND=heavy GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-Dorg.gradle.workers.max=$workers"
rc=0
if [[ -n "$env_file" && -f "$env_file" ]]; then
  # shellcheck disable=SC2016  # expanded by the inner bash
  bash -c 'source "$1"; shift; "$@"' gate-env "$env_file" "$@" || rc=$?
else
  "$@" || rc=$?
fi
exit "$rc"
