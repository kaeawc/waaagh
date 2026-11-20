#!/usr/bin/env bash
# Build once per commit for lanes that verify the same tree (#215). The first lane of a sharing class
# builds into a shared directory keyed by tree fingerprint (fingerprint.sh) under a lock, and marks
# it complete; other lanes on the same fingerprint wait for the marker and use those artifacts
# instead of building them again. Lanes of other classes build privately, as #213 does.
#
# Usage: shared-build.sh [--class CLASS] [--name NAME] [--artifact PATH]... [--copy DEST]
#                        [--wait SECONDS] [--dir PATH] [--status] -- CMD...
#   --class     the lane's command class (default $ORCHESTRATE_LANE_CLASS, else impl). Classes in
#               $ORCHESTRATE_BUILD_SHARE (default "verify device"; off disables) share builds; any
#               other class runs CMD itself into its lane build dir (_build_dirs.sh)
#   --name      what CMD builds (e.g. android-debug); default a hash of CMD and the --artifact paths.
#               Lanes share a build only when fingerprint and name match
#   --artifact  a worktree-relative path CMD produces, copied into the artifacts dir after CMD
#               succeeds (repeatable). CMD may also write into $ORCHESTRATE_SHARED_BUILD_OUT itself
#   --copy      also copy the artifacts into DEST (writable), for a tool that writes next to them
#   --wait      longest wait for another lane's build of the same key (default
#               $ORCHESTRATE_SHARED_WAIT or 3600); then exit 75
#   --dir       the worktree (default .)
#   --status    build nothing: print the row (ready | missing | private) and exit 0 if ready, else 1
# Output: CMD's output, then one TSV row on stdout:  shared-build  built|reused|private  DIR
#   DIR holds the artifacts at their worktree-relative paths (DEST with --copy). A shared DIR is
#   read-only: point the test at it (an APK path, a prebuilt runner), never build into it.
# Layout: <build root>/shared/<fingerprint>--<name>, with a .done marker (fingerprint, name, built_at,
# lane). It is built in <key>.tmp-<PID> and renamed into place after .done is written, so a failed
# or partial build leaves no marker and the next lane rebuilds. Lock: <key>.lock (PID and start;
# broken when the PID is gone or older than $ORCHESTRATE_SHARED_BUILD_MAX_AGE, default 7200 s).
# After a build, shared builds past $ORCHESTRATE_SHARED_BUILD_KEEP (default 3) or
# $ORCHESTRATE_SHARED_BUILD_MAX_MB (default 20480) are pruned; wt-cleanup.sh lists them as build rows.
# Run CMD through gate-slot.sh (shared-build.sh -- gate-slot.sh -- ./gradlew ...) to keep host load
# bounded; the wait here holds no gate slot.
# Env (tests): ORCHESTRATE_NOW starts a fake clock that advances SHARED_BUILD_POLL (default 5) s per
# wait; SHARED_BUILD_SLEEP is the real sleep per wait (default the poll).
# Exit: CMD's exit code | 75 another lane's build not done within --wait | 1 an --artifact missing
#       | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_slots.sh
source "$here/_slots.sh"
# shellcheck source=_build_dirs.sh
source "$here/_build_dirs.sh"

usage() { echo "usage: shared-build.sh [--class C] [--name N] [--artifact P]... [--copy D] [--wait S] [--dir P] [--status] -- CMD..." >&2; exit 2; }
class=${ORCHESTRATE_LANE_CLASS:-impl} name="" copy="" wait_s=${ORCHESTRATE_SHARED_WAIT:-3600} dir=. status=no
artifacts=()
while (($#)); do
  case "$1" in
    --class | --name | --artifact | --copy | --wait | --dir) [[ $# -ge 2 ]] || usage ;;
  esac
  case "$1" in
    --class) class=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --artifact)
      case "$2" in /* | .. | ../* | */.. | */../* | "") echo "shared-build.sh: --artifact must be a path inside the worktree: $2" >&2; exit 2 ;; esac
      artifacts+=("$2"); shift 2 ;;
    --copy) copy=$2; shift 2 ;;
    --wait) wait_s=$2; shift 2 ;;
    --dir) dir=$2; shift 2 ;;
    --status) status=yes; shift ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    --) shift; break ;;
    *) echo "shared-build.sh: unknown argument: $1" >&2; usage ;;
  esac
done
[[ "$wait_s" =~ ^[0-9]+$ ]] || { echo "shared-build.sh: --wait needs seconds: $wait_s" >&2; exit 2; }
[[ $# -gt 0 || "$status" == yes ]] || usage
[[ -n "$name" || $# -gt 0 ]] || { echo "shared-build.sh: --status without CMD needs --name" >&2; exit 2; }
[[ -d "$dir" ]] || { echo "shared-build.sh: no such directory: $dir" >&2; exit 2; }

wt=$(cd "$dir" && lane_build_worktree)
if [[ -z "$name" ]]; then
  name=$(printf '%s\0' "$@" -- ${artifacts[@]+"${artifacts[@]}"} | git hash-object --stdin)
  name=${name:0:12}
fi
name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
lane=${ORCHESTRATE_LANE_ID:-${wt##*/}}
poll=${SHARED_BUILD_POLL:-5} max_age=${ORCHESTRATE_SHARED_BUILD_MAX_AGE:-7200} virt=0

# The clock: real time, or with ORCHESTRATE_NOW a fake one that each wait moves on by the poll.
now() { if [[ -n "${ORCHESTRATE_NOW:-}" ]]; then echo $((ORCHESTRATE_NOW + virt)); else date +%s; fi; }
nap() { sleep "${SHARED_BUILD_SLEEP:-$poll}"; virt=$((virt + poll)); }

# copy_into SRC DEST: the artifacts of SRC (without its markers) into DEST, writable.
copy_into() {
  mkdir -p "$2"
  cp -R "$1/." "$2/"
  rm -f "$2/.done" "$2/.used"
  chmod -R u+w "$2"
}

# finish VERDICT DIR: print the result row (after the --copy, which it names instead).
finish() {
  local d=$2
  if [[ -n "$copy" ]]; then copy_into "$d" "$copy"; d=$(cd "$copy" && pwd -P); fi
  printf 'shared-build\t%s\t%s\n' "$1" "$d"
}

# collect DEST: copy each --artifact from the worktree into DEST; 1 when one is missing.
collect() {
  local a
  for a in ${artifacts[@]+"${artifacts[@]}"}; do
    [[ -e "$wt/$a" ]] || { echo "shared-build.sh: CMD succeeded but --artifact $a is missing in $wt" >&2; return 1; }
    mkdir -p "$1/$(dirname -- "$a")"
    cp -R "$wt/$a" "$1/$a"
  done
}

# A tree with no fingerprint (not a checkout) cannot be shared: build privately.
fp=""
if shared_build_shares "$class"; then
  fp=$("$here/fingerprint.sh" --dir "$wt" --fingerprint-only 2>/dev/null || true)
  [[ -n "$fp" ]] || echo "shared-build.sh: no tree fingerprint for $wt; building privately" >&2
fi

if [[ -z "$fp" ]]; then
  out="$(lane_build_dir "$wt")/artifacts/$name"
  if [[ "$status" == yes ]]; then printf 'shared-build\tprivate\t%s\n' "$out"; exit 1; fi
  rm -rf "$out"
  mkdir -p "$out"
  rc=0
  (cd "$wt" && ORCHESTRATE_SHARED_BUILD_OUT="$out" "$@") || rc=$?
  ((rc == 0)) || exit "$rc"
  collect "$out" || exit 1
  finish private "$out"
  exit 0
fi

root=$(shared_build_root) key="$fp--$name"
final="$root/$key" lock="$root/$key.lock"
if [[ "$status" == yes ]]; then
  if shared_build_complete "$final" "$fp"; then printf 'shared-build\tready\t%s\n' "$final"; exit 0; fi
  printf 'shared-build\tmissing\t%s\n' "$final"
  exit 1
fi
mkdir -p "$root"

# lock_take: take the build lock for this key, breaking one whose holder died or ran too long.
lock_take() {
  local pid at
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n%s\n%s\n' "$$" "$(now)" "$lane" >"$lock/owner"
    return 0
  fi
  pid=$(sed -n 1p "$lock/owner" 2>/dev/null || true)
  at=$(sed -n 2p "$lock/owner" 2>/dev/null || true)
  if { [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; } ||
    { [[ "$at" =~ ^[0-9]+$ ]] && (($(now) - at > max_age)); } ||
    { [[ -z "$pid" ]] && [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; }; then
    echo "shared-build.sh: breaking the stale build lock of $key (holder ${pid:-unknown})" >&2
    local tomb="$lock.stale-$$-$RANDOM"
    if mv "$lock" "$tomb" 2>/dev/null; then rm -rf "$tomb"; fi
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n%s\n%s\n' "$$" "$(now)" "$lane" >"$lock/owner"
      return 0
    fi
  fi
  return 1
}
lock_release() {
  [[ "$(sed -n 1p "$lock/owner" 2>/dev/null || true)" == "$$" ]] && rm -rf "$lock"
  return 0
}

reuse() {
  printf '%s\n' "$(now)" >"$final/.used" 2>/dev/null || true
  finish reused "$final"
  exit 0
}

deadline=$(($(now) + wait_s)) said=no
while :; do
  shared_build_complete "$final" "$fp" && reuse
  if lock_take; then break; fi
  if (($(now) >= deadline)); then
    echo "shared-build.sh: $key is still being built by $(sed -n 3p "$lock/owner" 2>/dev/null || echo another lane) after ${wait_s}s; not building it a second time" >&2
    exit 75
  fi
  if [[ "$said" == no ]]; then
    echo "shared-build.sh: waiting for $(sed -n 3p "$lock/owner" 2>/dev/null || echo another lane) to finish building $key" >&2
    said=yes
  fi
  nap
done

stage="$root/$key.tmp-$$"
trap 'lock_release; [[ -e "$stage" ]] && shared_build_remove "$stage"; true' EXIT
# Finished while this lane waited for the lock.
if shared_build_complete "$final" "$fp"; then lock_release; reuse; fi
if [[ -e "$final" ]]; then shared_build_remove "$final" || true; fi
mkdir -p "$stage"
rc=0
(cd "$wt" && ORCHESTRATE_SHARED_BUILD_OUT="$stage" "$@") || rc=$?
if ((rc != 0)); then
  echo "shared-build.sh: build of $key failed (exit $rc); no completion marker, the next lane rebuilds" >&2
  exit "$rc"
fi
collect "$stage" || exit 1
printf 'fingerprint\t%s\nname\t%s\nbuilt_at\t%s\nlane\t%s\n' "$fp" "$name" "$(now)" "$lane" >"$stage/.done"
printf '%s\n' "$(now)" >"$stage/.used"
find "$stage" -mindepth 1 ! -name .used -exec chmod a-w {} + 2>/dev/null || true
mv "$stage" "$final"
lock_release
# Keep shared builds within the cap; the build just made is the newest and always stays.
if cwds=$(proc_cwds | cut -f2-); then shared_builds_sweep yes "$cwds" "$final" >&2; fi
finish built "$final"
