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
# A command whose words include gradle, gradlew, xcodebuild or fastlane goes to heavy-build-slot.sh.
# While a heavy build holds its slot, no new gate starts: a Node gate and a Gradle/Xcode build never
# run at once. A slot whose holder died (or whose PID was reused) is reclaimed; nothing is killed.
# Exit: CMD's exit code | 75 no slot within --wait | 2 usage
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_slots.sh
source "$here/_slots.sh"

slots=${ORCHESTRATE_GATE_SLOTS:-3} wait_s=${ORCHESTRATE_GATE_WAIT:-1800} label=gate env_file=${ORCHESTRATE_GATE_ENV:-}
pass=()
while (($#)); do
  case "$1" in
    --slots) slots=$2; shift 2 ;;
    --wait) wait_s=$2; pass+=(--wait "$2"); shift 2 ;;
    --label) label=$2; pass+=(--label "$2"); shift 2 ;;
    --env-file) env_file=$2; pass+=(--env-file "$2"); shift 2 ;;
    --) shift; break ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "gate-slot.sh: unknown argument: $1 (put the command after --)" >&2; exit 2 ;;
  esac
done
(($#)) || { sed -n '2,17p' "$0" >&2; exit 2; }
[[ "$slots" =~ ^[1-9][0-9]*$ && "$wait_s" =~ ^[0-9]+$ ]] || { echo "gate-slot.sh: bad --slots or --wait" >&2; exit 2; }

for word in "$@"; do
  case "$(basename -- "${word%% *}")" in
    gradle | gradlew | xcodebuild | fastlane) exec "$here/heavy-build-slot.sh" ${pass[@]+"${pass[@]}"} -- "$@" ;;
  esac
done

# The per-repo gate environment, found without any network call.
if [[ -z "$env_file" ]] && url=$(git remote get-url origin 2>/dev/null); then
  slug=$(sed -E 's#^.*github\.com[:/]##; s#\.git$##' <<<"$url")
  [[ "$slug" == */* ]] && env_file="${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/${slug//\//__}/gate-env.sh"
fi
[[ -z "$env_file" || -f "$env_file" ]] || env_file=""

deadline=$(($(date +%s) + wait_s)) slot="" said=no
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
export GATE_SLOT_KIND=gate
rc=0
if [[ -n "$env_file" ]]; then
  # shellcheck disable=SC2016  # expanded by the inner bash
  bash -c 'source "$1"; shift; "$@"' gate-env "$env_file" "$@" || rc=$?
else
  "$@" || rc=$?
fi
exit "$rc"
