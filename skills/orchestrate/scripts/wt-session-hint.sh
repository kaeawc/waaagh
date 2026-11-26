#!/usr/bin/env bash
# SessionStart hook (#395): tell the session, in one line, when its repository has merged worktrees
# to clean up. Reads a cached wt-cleanup.sh report for the repository (keyed by its git common
# dir) and, when the report is younger than the TTL, prints:
#   waaagh: N merged, M likely merged worktrees in <repo> - review with wt-cleanup.sh --repo-dir <main>
# and nothing when both are 0. A missing or stale report is refreshed in a detached background
# process (`git fetch origin`, then a wt-cleanup.sh dry run), so the hook itself costs one git
# rev-parse and a file read: it never waits on gh or git fetch. Nothing is ever removed; removal
# stays with `wt-cleanup.sh --apply` after the owner agrees.
#
# Usage: wt-session-hint.sh                 (the hook: the repository of the working directory)
#        wt-session-hint.sh --refresh DIR   (what the hook starts: write DIR's report now)
#   N counts dry-run `remove` rows proven merged (`merged (<proof>)`, wt-cleanup.sh #393), plus
#   pushed ones when the report was made with --pr-closed (every PR for the branch merged or
#   closed); M counts `likely merged` rows. A repository with no linked worktrees is skipped.
# Report: <state root>/wt-reports/<repo dir name>-<cksum of the common dir>.tsv, first line
#   "# wt-cleanup report at=<epoch> pr-closed=yes|no repo-dir=<dir>", then wt-cleanup.sh's rows.
#   <state root> is ORCHESTRATE_STATE_DIR, else ~/.claude/orchestrate. One refresh at a time per
#   report (a mkdir lock, taken over after an hour).
# Env: ORCHESTRATE_WT_REPORT_TTL (seconds, default 43200 = 12h), ORCHESTRATE_WT_REPORT_FETCH=0
#   (refresh without fetching), ORCHESTRATE_NOW (clock, tests).
# Exit: always 0 (a hook must never block a session start), 2 an unknown argument or bad --refresh.
set -uo pipefail
# This script's directory with no subshell or dirname process: every hook start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
case "${1:-}" in -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;; esac
ttl=${ORCHESTRATE_WT_REPORT_TTL:-43200}
[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=43200
root=${ORCHESTRATE_STATE_DIR:-${HOME:-/nonexistent}/.claude/orchestrate}/wt-reports
now=${ORCHESTRATE_NOW:-${EPOCHSECONDS:-}}
[[ -n "$now" ]] || now=$(date +%s)

# report_path COMMON_DIR: the report file of the repository whose git common dir is COMMON_DIR.
report_path() {
  local c=$1 name sum
  name=${c%/.git}; name=${name%/}; name=${name##*/}; name=${name//[^A-Za-z0-9._-]/_}
  sum=$(cksum <<<"$c"); sum=${sum%% *}
  printf '%s/%s-%s.tsv\n' "$root" "${name:-repo}" "$sum"
}

if [[ "${1:-}" == --refresh ]]; then
  dir=${2:-}
  [[ -n "$dir" && -d "$dir" ]] || { echo "wt-session-hint.sh: --refresh needs a checkout directory" >&2; exit 2; }
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
  report=$(report_path "$common") lock=$(report_path "$common").lock
  tmp="$report.tmp.$$"
  mkdir -p "$root" 2>/dev/null || exit 0
  # The hook hands its lock over; run by hand, take it (and leave a refresh in flight alone).
  if [[ "${WT_SESSION_HINT_LOCK:-}" != "$lock" ]]; then
    mkdir "$lock" 2>/dev/null || exit 0
    echo "$now" >"$lock/at"
  fi
  trap 'rm -f "$tmp" "$tmp.rows"; rm -rf "$lock"' EXIT
  # Out of every worktree first: a refresh working inside one would keep that tree "busy".
  cd "$common" || exit 0
  if [[ "${ORCHESTRATE_WT_REPORT_FETCH:-1}" != 0 ]]; then
    GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch -q origin </dev/null >/dev/null 2>&1 || true
  fi
  # --pr-closed when the repository can be told (one gh read per otherwise-removable tree), else
  # the local proofs only. Through orch_run, so a test can stub wt-cleanup.sh (#233).
  # shellcheck source=_lib.sh
  source "$here/_lib.sh" || exit 0
  # Exit codes are taken with && / ||, so an inherited errexit (SHELLOPTS) cannot end the refresh
  # before its fallback.
  pr=yes
  orch_run wt-cleanup.sh --repo-dir "$dir" --pr-closed >"$tmp.rows" 2>/dev/null && rc=0 || rc=$?
  if ((rc == 2)); then
    pr=no
    orch_run wt-cleanup.sh --repo-dir "$dir" >"$tmp.rows" 2>/dev/null && rc=0 || rc=$?
  fi
  if ((rc == 0 || rc == 3)); then
    { printf '# wt-cleanup report at=%s pr-closed=%s repo-dir=%s\n' "$now" "$pr" "$dir"; cat "$tmp.rows"; } >"$tmp" && mv -f "$tmp" "$report"
  fi
  rm -f "$tmp.rows"
  exit 0
fi
(($# == 0)) || { echo "wt-session-hint.sh: unknown argument: $1" >&2; exit 2; }

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
[[ -d "$common/worktrees" ]] || exit 0   # no linked worktree: nothing to clean up, nothing to refresh
report=$(report_path "$common")

# Fresh: print the summary. Missing or stale: refresh in the background, say nothing now.
fresh=no at="" pr=no merged=0 likely=0 main_dir=""
if [[ -f "$report" ]]; then
  while IFS=$'\t' read -r verdict _ reason; do
    case "$verdict" in
      "# wt-cleanup report "*)
        at=${verdict#* at=}; at=${at%% *}
        pr=${verdict#* pr-closed=}; pr=${pr%% *}
        main_dir=${verdict#* repo-dir=} ;;   # last: it may hold spaces
      remove)
        case "$reason" in
          *", merged ("*) merged=$((merged + 1)) ;;
          *", pushed"*) [[ "$pr" != yes ]] || merged=$((merged + 1)) ;;
        esac ;;
      keep) case "$reason" in "likely merged "*) likely=$((likely + 1)) ;; esac ;;
    esac
  done <"$report"
  [[ "$at" =~ ^[0-9]+$ ]] && ((now - at < ttl)) && fresh=yes
fi

if [[ "$fresh" == yes ]]; then
  if ((merged + likely > 0)); then
    repo_name=${common%/.git}; repo_name=${repo_name##*/}
    printf 'waaagh: %s merged, %s likely merged worktrees in %s - review with %s/wt-cleanup.sh --repo-dir %s (dry run; removing needs --apply after the owner agrees)\n' \
      "$merged" "$likely" "$repo_name" "$here" "${main_dir:-.}"
  fi
  exit 0
fi

# One refresh at a time; a lock left by a refresh that died is taken over after an hour.
mkdir -p "$root" 2>/dev/null || exit 0
lock="$report.lock"
if ! mkdir "$lock" 2>/dev/null; then
  held=""
  [[ ! -f "$lock/at" ]] || read -r held <"$lock/at" || true
  [[ "$held" =~ ^[0-9]+$ ]] && ((now - held < 3600)) && exit 0
  rm -rf "$lock"; mkdir "$lock" 2>/dev/null || exit 0
fi
echo "$now" >"$lock/at"
# Detached: its own stdio (a hook whose child holds stdout is waited on), immune to the session's
# hangup, started from outside every worktree, and with none of the launcher's shell options or
# startup file (SHELLOPTS, BASH_ENV): no inherited errexit or xtrace. Under bashcov an inherited
# xtrace made it a concurrent traced process in another directory, which slows bashcov for the
# rest of its run (its working-directory stack grows with every switch).
# The main checkout when there is one (the common dir is its .git), else this checkout.
dir=$PWD
[[ "$common" != */.git || ! -d "${common%/.git}" ]] || dir=${common%/.git}
(cd "$common" && WT_SESSION_HINT_LOCK=$lock exec env -u SHELLOPTS -u BASH_ENV nohup "$here/wt-session-hint.sh" --refresh "$dir" </dev/null >/dev/null 2>&1) </dev/null >/dev/null 2>&1 &
exit 0
