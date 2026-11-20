#!/usr/bin/env bash
# Run one device boot (a simulator or emulator start) through a host-wide gate (#314): one boot at
# a time, started only once the 1-minute load is below a threshold, and the slot kept for a settle
# time afterwards. Three lanes once booted simulators within the same minute and the load on a
# 16-CPU host went from 25 to 235: each boot starts many runtime processes, and most of them start
# after the boot command has returned. The device-lane count does not bound that; boots per minute
# and the load at each boot do.
#
# Usage: boot-slot.sh [--load-factor F] [--settle SECONDS] [--wait SECONDS] [--label TEXT] -- CMD...
#   --load-factor  start CMD only while the 1-min load is below F x CPUs (default
#                  $ORCHESTRATE_BOOT_LOAD_FACTOR or 3: 48 on 16 CPUs), as host-load.sh reads them
#   --settle       keep the slot this many seconds after CMD succeeds, so the next boot does not
#                  start on top of this one's runtime processes (default $ORCHESTRATE_BOOT_SETTLE or 30)
#   --wait         longest wait for the slot and for the load to fall (default $ORCHESTRATE_BOOT_WAIT
#                  or 900); then exit 75 and the slot is released
# CMD is the boot itself (`xcrun simctl boot <udid>`, an emulator start script), not the test run
# that follows. Called from inside a command boot-slot.sh is already running (a matrix script
# wrapped whole, wrapping each boot again), it runs CMD in the slot already held, with no wait.
# A slot whose holder died is reclaimed; nothing is killed, and no device is shut down here.
# Exit: CMD's exit code | 75 not started within --wait | 3 the load could not be read | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
# shellcheck source=_slots.sh
source "$here/_slots.sh"

factor=${ORCHESTRATE_BOOT_LOAD_FACTOR:-3} settle=${ORCHESTRATE_BOOT_SETTLE:-30} wait_s=${ORCHESTRATE_BOOT_WAIT:-900} label=boot
while (($#)); do
  case "$1" in
    --load-factor) factor=${2:-}; shift 2 ;;
    --settle) settle=${2:-}; shift 2 ;;
    --wait) wait_s=${2:-}; shift 2 ;;
    --label) label=${2:-}; shift 2 ;;
    --) shift; break ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "boot-slot.sh: unknown argument: $1 (put the command after --)" >&2; exit 2 ;;
  esac
done
(($#)) || { orch_usage >&2; exit 2; }
[[ "$factor" =~ ^[0-9]+([.][0-9]+)?$ && "$settle" =~ ^[0-9]+$ && "$wait_s" =~ ^[0-9]+$ ]] ||
  { echo "boot-slot.sh: bad --load-factor, --settle or --wait" >&2; exit 2; }

# Nested: the marker counts only while that PID still holds that slot.
held=${ORCHESTRATE_BOOT_SLOT_HELD:-}
if [[ -n "$held" && "$held" == "$(slot_root)"/boot/slot-* && -f "$held/holder" ]] &&
  [[ "$(sed -n 1p "$held/holder" 2>/dev/null || true)" == "${ORCHESTRATE_BOOT_SLOT_HOLDER:-}" ]] && slot_live "$held"; then
  echo "boot-slot: already inside a boot slot; running in it" >&2
  exec "$@"
fi

# over_limit: the load row of host-load.sh (1-min load, CPUs); prints "<load> <limit>" and returns 0
# while the load is at or above F x CPUs, 1 below it, 3 when there is no reading.
over_limit() {
  local row load cpus
  row=$(orch_run host-load.sh --top 0 2>/dev/null | awk -F'\t' '$1 == "load" { print $2, $3 + 0 }' || true)
  load=${row%% *} cpus=${row##* }
  [[ "$load" =~ ^[0-9]+([.][0-9]+)?$ && "$cpus" =~ ^[1-9][0-9]*$ ]] || return 3
  awk -v l="$load" -v c="$cpus" -v f="$factor" 'BEGIN { printf "%s %.1f\n", l, f * c; exit !(l + 0 >= f * c) }'
}

deadline=$(($(date +%s) + wait_s)) slot="" said=no
trap 'slot_release "$slot" $$' EXIT
until slot=$(slot_try boot 1 $$ "$label"); do
  (($(date +%s) < deadline)) || { echo "boot-slot: another boot holds the slot after ${wait_s}s" >&2; exit 75; }
  [[ "$said" == yes ]] || { echo "boot-slot: waiting for another lane's boot to settle" >&2; said=yes; }
  slot_sleep
done
said=no
while :; do
  rc=0
  reading=$(over_limit) || rc=$?
  ((rc != 1)) || break
  ((rc != 3)) || { echo "boot-slot: the host load could not be read (host-load.sh); not booting blind" >&2; exit 3; }
  (($(date +%s) < deadline)) || { echo "boot-slot: load ${reading% *} still at or above ${reading#* } after ${wait_s}s" >&2; exit 75; }
  [[ "$said" == yes ]] || { echo "boot-slot: waiting for the load to fall (${reading% *}, limit ${reading#* })" >&2; said=yes; }
  slot_sleep
done

export ORCHESTRATE_BOOT_SLOT_HELD="$slot" ORCHESTRATE_BOOT_SLOT_HOLDER=$$
rc=0
"$@" || rc=$?
# A failed boot started nothing worth waiting for.
((rc != 0 || settle == 0)) || sleep "$settle"
exit "$rc"
