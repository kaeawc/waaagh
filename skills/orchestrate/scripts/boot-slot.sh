#!/usr/bin/env bash
# Run one device boot (a simulator or emulator start) through a host-wide gate (#314): one boot at
# a time, started only once the 1-minute load is below a threshold, and the slot kept for a settle
# time afterwards. Three lanes once booted simulators within the same minute and the load on a
# 16-CPU host went from 25 to 235: each boot starts many runtime processes, and most of them start
# after the boot command has returned. The device-lane count does not bound that; boots per minute
# and the load at each boot do.
#
# Usage: boot-slot.sh [--load-factor F] [--max-booted N] [--max-boots N] [--settle SECONDS]
#                     [--wait SECONDS] [--label TEXT] -- CMD...
#   --load-factor  start CMD only while the 1-min load is below F x CPUs (default
#                  $ORCHESTRATE_BOOT_LOAD_FACTOR or 3: 48 on 16 CPUs), as host-load.sh reads them
#   --max-booted   also wait while the host has N or more devices booted (simulators and emulators;
#                  default $ORCHESTRATE_BOOT_MAX_BOOTED or 4)
#   --max-boots    also wait while N or more devices booted in spectra's boot window (5 minutes;
#                  default $ORCHESTRATE_BOOT_MAX_RECENT or 3): boots per minute drive the load (#334)
#   Device counts come from host-load.sh's devices rows (spectra, kaeawc/spectra#602); a spectra too
#   old to count devices is named once and the gate falls back to the load alone. When this lane's
#   worktree already has a device booted, a line says so (one booted device per lane); it does not
#   wait for that.
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

factor=${ORCHESTRATE_BOOT_LOAD_FACTOR:-3} max_booted=${ORCHESTRATE_BOOT_MAX_BOOTED:-4} max_boots=${ORCHESTRATE_BOOT_MAX_RECENT:-3} settle=${ORCHESTRATE_BOOT_SETTLE:-30} wait_s=${ORCHESTRATE_BOOT_WAIT:-900} label=boot
while (($#)); do
  case "$1" in
    --load-factor) factor=${2:-}; shift 2 ;;
    --max-booted) max_booted=${2:-}; shift 2 ;;
    --max-boots) max_boots=${2:-}; shift 2 ;;
    --settle) settle=${2:-}; shift 2 ;;
    --wait) wait_s=${2:-}; shift 2 ;;
    --label) label=${2:-}; shift 2 ;;
    --) shift; break ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "boot-slot.sh: unknown argument: $1 (put the command after --)" >&2; exit 2 ;;
  esac
done
(($#)) || { orch_usage >&2; exit 2; }
[[ "$factor" =~ ^[0-9]+([.][0-9]+)?$ && "$settle" =~ ^[0-9]+$ && "$wait_s" =~ ^[0-9]+$ &&
  "$max_booted" =~ ^[1-9][0-9]*$ && "$max_boots" =~ ^[1-9][0-9]*$ ]] ||
  { echo "boot-slot.sh: bad --load-factor, --max-booted, --max-boots, --settle or --wait" >&2; exit 2; }

# Nested: the marker counts only while that PID still holds that slot.
held=${ORCHESTRATE_BOOT_SLOT_HELD:-}
if [[ -n "$held" && "$held" == "$(slot_root)"/boot/slot-* && -f "$held/holder" ]] &&
  [[ "$(sed -n 1p "$held/holder" 2>/dev/null || true)" == "${ORCHESTRATE_BOOT_SLOT_HOLDER:-}" ]] && slot_live "$held"; then
  echo "boot-slot: already inside a boot slot; running in it" >&2
  exec "$@"
fi

# This lane's worktree, so host-load.sh's devices-root row counts the devices it started.
lane_wt=$(git rev-parse --show-toplevel 2>/dev/null) || lane_wt=""
said_old=no said_own=no
# over_limit: host-load.sh's load and devices rows. Prints why the boot must wait and returns 0
# while it must, 1 when it may go, 3 when there is no load reading.
over_limit() {
  local rows load cpus booted recent window own
  rows=$(orch_run host-load.sh --top 0 ${lane_wt:+--worktree-root "$lane_wt"} 2>/dev/null || true)
  read -r load cpus < <(awk -F'\t' '$1 == "load" { print $2, $3 + 0 }' <<<"$rows") || true
  [[ "${load:-}" =~ ^[0-9]+([.][0-9]+)?$ && "${cpus:-}" =~ ^[1-9][0-9]*$ ]] || return 3
  read -r booted recent window < <(awk -F'\t' '$1 == "devices" { print $2, $3, $4 }' <<<"$rows") || true
  own=$(awk -F'\t' '$1 == "devices-root" { n += $3 } END { print n + 0 }' <<<"$rows")
  if [[ -z "${booted:-}" && $said_old == no ]]; then
    echo "boot-slot: spectra reports no device counts (update it for kaeawc/spectra#602); gating on the load alone" >&2; said_old=yes
  fi
  if ((own > 0)) && [[ $said_own == no ]]; then
    echo "boot-slot: this lane already has $own device(s) booted: keep one booted device per lane; shut it down before booting another" >&2; said_own=yes
  fi
  if awk -v l="$load" -v c="$cpus" -v f="$factor" 'BEGIN { exit !(l + 0 >= f * c) }'; then
    awk -v l="$load" -v c="$cpus" -v f="$factor" 'BEGIN { printf "the load to fall (%s, limit %.1f)\n", l, f * c }'; return 0
  fi
  if [[ -n "${booted:-}" ]] && ((booted >= max_booted)); then echo "a device to shut down ($booted booted, max $max_booted)"; return 0; fi
  if [[ -n "${recent:-}" ]] && ((recent >= max_boots)); then echo "recent boots to settle ($recent in ${window}s, max $max_boots)"; return 0; fi
  return 1
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
  (($(date +%s) < deadline)) || { echo "boot-slot: still waiting for $reading after ${wait_s}s" >&2; exit 75; }
  [[ "$said" == "$reading" ]] || { echo "boot-slot: waiting for $reading" >&2; said=$reading; }
  slot_sleep
done

export ORCHESTRATE_BOOT_SLOT_HELD="$slot" ORCHESTRATE_BOOT_SLOT_HOLDER=$$
rc=0
"$@" || rc=$?
# A failed boot started nothing worth waiting for.
((rc != 0 || settle == 0)) || sleep "$settle"
exit "$rc"
