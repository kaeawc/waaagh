#!/usr/bin/env bash
# Run one gate (tests, lint, typecheck, a prepush hook) through a host-wide semaphore, so many lanes
# on one machine cannot stack their gates until everything times out. Heavy native builds (Gradle,
# Xcode) are routed to heavy-build-slot.sh, which runs them alone.
#
# Usage: gate-slot.sh [--slots N] [--wait SECONDS] [--label TEXT] [--env-file FILE] -- CMD...
#   --slots     concurrent gates on this host (default $ORCHESTRATE_GATE_SLOTS or 3)
#   --wait      longest wait for a slot (default $ORCHESTRATE_GATE_WAIT or 1800); then exit 75
#   --env-file  sourced before CMD runs, for worker/timeout/retry caps every gate should carry even
#               when a lane forgot them (default $ORCHESTRATE_GATE_ENV, else
#               <state dir>/<owner>__<repo>/gate-env.sh for this checkout's origin, if present)
# A command whose words include gradle, gradlew, xcodebuild or fastlane goes to heavy-build-slot.sh,
# with the same gate environment passed as --env-file.
# While a heavy build holds its slot, no new gate starts: a Node gate and a Gradle/Xcode build never
# run at once. A slot whose holder died (or whose PID was reused) is reclaimed; nothing is killed.
# Re-entrant (#313): called from inside a command that gate-slot.sh or heavy-build-slot.sh is already
# running, it takes no second slot and runs CMD inside the one its ancestor holds.
# Every gate runs with lane-private build output (#213): ORCHESTRATE_LANE_BUILD_DIR, and TMPDIR,
# XDG_CACHE_HOME and per-tool flags pointed into it from the build-dirs table (_build_dirs.sh;
# ORCHESTRATE_BUILD_DIRS=off disables), exported before the gate environment is sourced.
# Exit: CMD's exit code | 75 no slot within --wait | 2 usage
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_slots.sh
source "$here/_slots.sh"
# shellcheck source=_build_dirs.sh
source "$here/_build_dirs.sh"

slots=${ORCHESTRATE_GATE_SLOTS:-3} wait_s=${ORCHESTRATE_GATE_WAIT:-1800} label=gate env_file=${ORCHESTRATE_GATE_ENV:-}
pass=()
while (($#)); do
  case "$1" in
    --slots) slots=$2; shift 2 ;;
    --wait) wait_s=$2; pass+=(--wait "$2"); shift 2 ;;
    --label) label=$2; pass+=(--label "$2"); shift 2 ;;
    --env-file) env_file=$2; pass+=(--env-file "$2"); shift 2 ;;
    --) shift; break ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "gate-slot.sh: unknown argument: $1 (put the command after --)" >&2; exit 2 ;;
  esac
done
(($#)) || { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" >&2; exit 2; }
[[ "$slots" =~ ^[1-9][0-9]*$ && "$wait_s" =~ ^[0-9]+$ ]] || { echo "gate-slot.sh: bad --slots or --wait" >&2; exit 2; }

# The per-repo gate environment, found without any network call. Resolved before routing, so heavy
# builds (which most need the repo JDK/SDK settings) get it too (#288).
if [[ -z "$env_file" ]] && sd=$(repo_state_dir); then env_file="$sd/gate-env.sh"; fi
[[ -z "$env_file" || -f "$env_file" ]] || env_file=""

for word in "$@"; do
  case "$(basename -- "${word%% *}")" in
    gradle | gradlew | xcodebuild | fastlane) exec "$here/heavy-build-slot.sh" ${pass[@]+"${pass[@]}"} ${env_file:+--env-file "$env_file"} -- "$@" ;;
  esac
done

deadline=$(($(date +%s) + wait_s)) slot="" said=no
if held=$(slot_held); then
  # Nested: waiting for a slot would wait on this process's own ancestor (a gate inside a heavy
  # build never starts; a gate inside a gate can use up every slot).
  echo "gate-slot: already inside a $held slot; running in it" >&2
else
  while :; do
    if [[ "$(slot_busy heavy 1)" == 0 ]] && slot=$(slot_try gate "$slots" $$ "$label"); then break; fi
    if (($(date +%s) >= deadline)); then
      echo "gate-slot: no gate slot within ${wait_s}s ($(slot_busy gate "$slots")/$slots gates, $(slot_busy heavy 1) heavy build busy)" >&2
      exit 75
    fi
    [[ "$said" == yes ]] || { echo "gate-slot: waiting ($(slot_busy gate "$slots")/$slots gates busy, $(slot_busy heavy 1) heavy build)" >&2; said=yes; }
    slot_sleep
  done
  trap 'slot_release "$slot" $$' EXIT
  export GATE_SLOT_KIND=gate ORCHESTRATE_SLOT_HELD="$slot" ORCHESTRATE_SLOT_HOLDER=$$
fi
build_dirs_apply "$@"
rc=0
if [[ -n "$env_file" ]]; then
  # shellcheck disable=SC2016  # expanded by the inner bash
  bash -c 'source "$1"; shift; "$@"' gate-env "$env_file" "${BUILD_ARGV[@]}" || rc=$?
else
  "${BUILD_ARGV[@]}" || rc=$?
fi
exit "$rc"
