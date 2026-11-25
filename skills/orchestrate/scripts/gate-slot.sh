#!/usr/bin/env bash
# Run one gate (tests, lint, typecheck, a prepush hook) through a host-wide semaphore, so many lanes
# on one machine cannot stack their gates until everything times out. Heavy native builds (Gradle,
# Xcode) are routed to heavy-build-slot.sh, which runs them alone.
#
# Usage: gate-slot.sh [--slots N] [--wait SECONDS] [--label TEXT] [--env-file FILE] [--class NAME]... -- CMD...
#   --slots     concurrent gates on this host (default $ORCHESTRATE_GATE_SLOTS or 3)
#   --wait      longest wait for a slot (default $ORCHESTRATE_GATE_WAIT or 1800); then exit 75
#   --class     an exclusive class (#396; lower-case letters, digits, . _ -; repeatable): CMD also
#               holds that class's one slot, so no two commands of one class run at once on this
#               host (DB-backed suites, migrations, generators sharing a database or port)
#   --env-file  sourced before CMD runs, for worker/timeout/retry caps every gate should carry even
#               when a lane forgot them (default $ORCHESTRATE_GATE_ENV, else
#               <state dir>/<owner>__<repo>/gate-env.sh for this checkout's origin, if present)
# A command whose words include gradle, gradlew, xcodebuild or fastlane goes to heavy-build-slot.sh,
# with the same gate environment passed as --env-file.
# While a heavy build holds its slot, no new gate starts: a Node gate and a Gradle/Xcode build never
# run at once. A slot whose holder died (or whose PID was reused) is reclaimed; nothing is killed.
# Re-entrant (#313): called from inside a command that gate-slot.sh or heavy-build-slot.sh is already
# running, it takes no second slot and runs CMD inside the one its ancestor holds.
# Classes come from --class and from the gate environment: a gate-env.sh that defines
# gate_class() is asked once per gate (called with CMD's words, it prints class names). A class an
# ancestor holds is not taken again. Outside any slot, the classes and a gate slot are taken
# together or not at all, so a waiting gate holds nothing; nested in a slot, a missing class is
# taken with the same bounded wait (so name the class on the outermost gate). A Gradle or Xcode
# command takes its classes here, then runs heavy-build-slot.sh inside them.
# Every gate runs with lane-private build output (#213): ORCHESTRATE_LANE_BUILD_DIR, and TMPDIR,
# XDG_CACHE_HOME and per-tool flags pointed into it from the build-dirs table (_build_dirs.sh;
# ORCHESTRATE_BUILD_DIRS=off disables), exported before the gate environment is sourced.
# Exit: CMD's exit code | 75 no slot within --wait | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_slots.sh
source "$here/_slots.sh"
# shellcheck source=_build_dirs.sh
source "$here/_build_dirs.sh"

slots=${ORCHESTRATE_GATE_SLOTS:-3} wait_s=${ORCHESTRATE_GATE_WAIT:-1800} label=gate env_file=${ORCHESTRATE_GATE_ENV:-}
pass=() classes=""
while (($#)); do
  case "$1" in
    --slots) slots=$2; shift 2 ;;
    --class) [[ -n "${2:-}" ]] || { echo "gate-slot.sh: --class needs a name" >&2; exit 2; }; classes+=" $2"; shift 2 ;;
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
# The gate environment's classes for this command: one bash, only when it defines gate_class.
if [[ -n "$env_file" ]] && grep -q 'gate_class' "$env_file" 2>/dev/null; then
  # shellcheck disable=SC2016  # expanded by the inner bash
  classes+=" $(bash -c 'source "$1" >/dev/null; shift; if declare -F gate_class >/dev/null; then gate_class "$@"; fi' gate-env "$env_file" "$@" | tr '\n' ' ')" ||
    { echo "gate-slot.sh: gate_class in $env_file failed" >&2; exit 2; }
fi
take=() taken=()
set -f   # class names are words, never globs
for c in $(printf '%s\n' $classes | LC_ALL=C sort -u); do
  slot_class_ok "$c" || { echo "gate-slot.sh: bad class name: $c (lower-case letters, digits, . _ -)" >&2; exit 2; }
  slot_class_held "$c" || take+=("$c")
done
set +f

# classes_try: take every class in take (sorted, so two gates never cross); on a miss, release the
# ones taken and say which class is busy in $busy.
classes_try() {
  local c d
  for c in ${take[@]+"${take[@]}"}; do
    if d=$(slot_try "class-$c" 1 $$ "$label"); then taken+=("$d"); continue; fi
    busy="class $c held by $(slot_holder_desc "$(slot_root)/class-$c/slot-1")"
    classes_release
    return 1
  done
}
classes_release() {
  local d
  for d in ${taken[@]+"${taken[@]}"}; do slot_release "$d" $$; done
  taken=()
}
# classes_wait: take every class, waiting (bounded) for the busy ones; exit 75 at the deadline.
classes_wait() {
  local said=no
  until classes_try; do
    if (($(date +%s) >= deadline)); then echo "gate-slot: no class slot within ${wait_s}s ($busy)" >&2; exit 75; fi
    [[ "$said" == yes ]] || { echo "gate-slot: waiting ($busy)" >&2; said=yes; }
    slot_sleep
  done
}
classes_export() {
  local c
  for c in ${take[@]+"${take[@]}"}; do ORCHESTRATE_CLASS_HELD="${ORCHESTRATE_CLASS_HELD:+$ORCHESTRATE_CLASS_HELD }$c=$$"; done
  export ORCHESTRATE_CLASS_HELD
}
deadline=$(($(date +%s) + wait_s)) slot="" said=no busy=""
trap 'classes_release; slot_release "$slot" $$' EXIT

for word in "$@"; do
  case "$(basename -- "${word%% *}")" in
    gradle | gradlew | xcodebuild | fastlane)
      ((${#take[@]})) || exec "$here/heavy-build-slot.sh" ${pass[@]+"${pass[@]}"} ${env_file:+--env-file "$env_file"} -- "$@"
      # Its classes first, held while heavy-build-slot.sh waits for and runs in the heavy slot.
      classes_wait; classes_export
      rc=0
      "$here/heavy-build-slot.sh" ${pass[@]+"${pass[@]}"} ${env_file:+--env-file "$env_file"} -- "$@" || rc=$?
      exit "$rc" ;;
  esac
done

if held=$(slot_held); then
  # Nested: waiting for a slot would wait on this process's own ancestor (a gate inside a heavy
  # build never starts; a gate inside a gate can use up every slot).
  echo "gate-slot: already inside a $held slot; running in it" >&2
  classes_wait
else
  while :; do
    busy=""
    if classes_try; then
      [[ "$(slot_busy heavy 1)" == 0 ]] && slot=$(slot_try gate "$slots" $$ "$label") && break
      classes_release   # nothing is held while waiting
    fi
    if (($(date +%s) >= deadline)); then
      echo "gate-slot: no gate slot within ${wait_s}s ($(slot_busy gate "$slots")/$slots gates, $(slot_busy heavy 1) heavy build busy${busy:+, $busy})" >&2
      exit 75
    fi
    [[ "$said" == yes ]] || { echo "gate-slot: waiting ($(slot_busy gate "$slots")/$slots gates busy, $(slot_busy heavy 1) heavy build${busy:+, $busy})" >&2; said=yes; }
    slot_sleep
  done
  export GATE_SLOT_KIND=gate ORCHESTRATE_SLOT_HELD="$slot" ORCHESTRATE_SLOT_HOLDER=$$
fi
classes_export
build_dirs_apply "$@"
rc=0
if [[ -n "$env_file" ]]; then
  # shellcheck disable=SC2016  # expanded by the inner bash
  bash -c 'source "$1"; shift; "$@"' gate-env "$env_file" "${BUILD_ARGV[@]}" || rc=$?
else
  "${BUILD_ARGV[@]}" || rc=$?
fi
exit "$rc"
