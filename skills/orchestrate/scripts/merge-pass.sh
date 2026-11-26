#!/usr/bin/env bash
# One merge pass over the open PRs (#411): the merge bot's steps 2-3 (roles/merge-bot.md) as one
# script, so a campaign's merge loop is `merge-pass.sh` plus a sleep instead of its own copy of
# pr-ready.sh and pr-merge.sh logic.
#
# Usage: merge-pass.sh [--repo OWNER/REPO] [--author LOGIN]... [--ignore-check NAME]...
#                      [--exclude-label LABEL]... [--cap N] [--max-untested N --workflow NAME]
#                      [--every SECONDS] [--dry-run]
#   --cap           merge at most N PRs this pass (default 8)
#   --max-untested  merge only while fewer than N commits on the default branch are past the
#                   newest one whose --workflow push run finished green; the cap this pass is
#                   N minus that count (auto-mobile's "at most 3 merges on top of a green main")
#   --every         the loop's sleep, recorded with the heartbeat (loops.sh heartbeat merge-pass)
#   --dry-run       print what it would merge; merge nothing
# A pass:
#   1. main-health.sh (with --workflow when given): red or unknown holds the whole pass.
#   2. pr-ready.sh with --author, --ignore-check and --exclude-label (needs-device-recheck always).
#   3. READY rows in order: the PR numbers in <state dir>/merge-priority first (one per line, in
#      file order), then the rest oldest first. Before each: device-recheck.sh check (held: skip).
#      Then pr-merge.sh --pr N --head H. After a merge the rows are read again (mergeability of
#      the others changes); `outage:` from pr-merge.sh ends the pass.
# Output, one line each: `merged <n>` | `hold <n> <reason>` | `would merge <n>` (--dry-run)
#   | `hold main <main-health line>` | `hold untested=<k> since=<sha>` | `stop outage <line>`,
#   then `pass merged=<n> held=<n> ready=<n> cap=<n> untested=<k|->`.
# Env: ORCHESTRATE_SCRIPTS_DIR (tests stub the scripts it runs).
# Exit: 0 the pass ran (even with nothing to merge) | 2 usage | 3 pr-ready.sh failed
#       | 4 held: main is red or unknown, or the untested cap is used up | 5 Pull Requests outage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

repo="" cap=8 untested_max="" workflow="" every="" dry=no
authors=() ignores=() excludes=(needs-device-recheck)
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --author) authors+=("${2:-}"); shift $(($# > 1 ? 2 : 1)) ;;
    --ignore-check) ignores+=("${2:-}"); shift $(($# > 1 ? 2 : 1)) ;;
    --exclude-label) excludes+=("${2:-}"); shift $(($# > 1 ? 2 : 1)) ;;
    --cap) cap=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --max-untested) untested_max=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --workflow) workflow=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --every) every=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "merge-pass.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$cap" =~ ^[0-9]+$ ]] || { echo "merge-pass.sh: --cap needs a number" >&2; exit 2; }
[[ -z "$untested_max" || "$untested_max" =~ ^[0-9]+$ ]] || { echo "merge-pass.sh: --max-untested needs a number" >&2; exit 2; }
[[ -z "$untested_max" || -n "$workflow" ]] || { echo "merge-pass.sh: --max-untested needs --workflow" >&2; exit 2; }
[[ -z "$every" || "$every" =~ ^[0-9]+$ ]] || { echo "merge-pass.sh: --every needs seconds" >&2; exit 2; }
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")

beat() {
  local a=(heartbeat merge-pass --repo "$repo")
  [[ -z "$every" ]] || a+=(--every "$every")
  orch_run loops.sh "${a[@]}" >/dev/null 2>&1 || true
}
merged=0 held=0 ready=0 untested=-
summary() { echo "pass merged=$merged held=$held ready=$ready cap=$cap untested=$untested"; }

# 1. Main must be green.
mh_args=(--repo "$repo"); [[ -z "$workflow" ]] || mh_args+=(--workflow "$workflow")
mrc=0; mline=$(orch_run main-health.sh "${mh_args[@]}" 2>/dev/null | tail -1) || mrc=$?
if ((mrc != 0)); then echo "hold main ${mline:-unreadable}"; beat; summary; exit 4; fi

# The untested cap: commits on the default branch past the newest green run of --workflow.
if [[ -n "$untested_max" ]]; then
  default=$(orch_default_branch "$repo")
  green=$("$here/gh-read.sh" --tries 3 -- api "repos/$repo/actions/runs?branch=$default&event=push&status=success&per_page=50" \
    --jq "[.workflow_runs[] | select(.name == \"$workflow\")][0].head_sha // empty" 2>/dev/null) || green=""
  if [[ -z "$green" ]]; then echo "hold untested=unknown since=- (no green $workflow run on $default)"; beat; summary; exit 4; fi
  untested=$("$here/gh-read.sh" --tries 3 -- api "repos/$repo/compare/$green...$default" --jq .ahead_by 2>/dev/null) || untested=""
  [[ "$untested" =~ ^[0-9]+$ ]] || { echo "hold untested=unknown since=${green:0:9}"; untested=-; beat; summary; exit 4; }
  room=$((untested_max - untested))
  if ((room < cap)); then cap=$((room > 0 ? room : 0)); fi
  if ((cap == 0)); then echo "hold untested=$untested since=${green:0:9}"; beat; summary; exit 4; fi
fi

# 2-3. READY rows, priority first, then oldest first.
ready_args=(--repo "$repo")
for a in ${authors[@]+"${authors[@]}"}; do ready_args+=(--author "$a"); done
for c in ${ignores[@]+"${ignores[@]}"}; do ready_args+=(--ignore-check "$c"); done
for l in "${excludes[@]}"; do ready_args+=(--exclude-label "$l"); done
merge_args=(--repo "$repo")
for a in ${authors[@]+"${authors[@]}"}; do merge_args+=(--author "$a"); done
for c in ${ignores[@]+"${ignores[@]}"}; do merge_args+=(--ignore-check "$c"); done

# rows: "<n> <head>" for every READY row, in merge order.
rows() {
  local out
  out=$(orch_run pr-ready.sh "${ready_args[@]}" 2>/dev/null) || return 1
  awk -F'\t' '$2 == "READY" { print $1, $3 }' <<<"$out" |
    awk -v pf="$state/merge-priority" 'BEGIN { while ((getline l < pf) > 0) if (l ~ /^[0-9]+/) { sub(/[^0-9].*/, "", l); if (!(l in rank)) rank[l] = ++r } }
      { k = ($1 in rank) ? rank[$1] : 1000000 + $1; print k, $0 }' | sort -n | cut -d' ' -f2-
}
done_prs=" "
if ! list=$(rows); then echo "merge-pass.sh: pr-ready.sh failed; nothing merged" >&2; beat; summary; exit 3; fi
ready=$(grep -c . <<<"$list" || true)
while ((merged < cap)); do
  next="" head=""
  while read -r n h; do
    [[ -n "$n" && "$done_prs" != *" $n "* ]] || continue
    next=$n head=$h; break
  done <<<"$list"
  [[ -n "$next" ]] || break
  done_prs+="$next "
  dl=$(orch_run device-recheck.sh check --repo "$repo" --pr "$next" 2>/dev/null) && drc=0 || drc=$?
  if ((drc == 3 || drc == 4)); then echo "hold $next ${dl:-device recheck}"; held=$((held + 1)); continue; fi
  if [[ "$dry" == yes ]]; then echo "would merge $next"; merged=$((merged + 1)); continue; fi
  out=$(orch_run pr-merge.sh "${merge_args[@]}" --pr "$next" --head "$head" 2>&1) && rc=0 || rc=$?
  first=$(head -n 1 <<<"$out")
  if ((rc == 0)); then
    echo "merged $next"; merged=$((merged + 1))
    list=$(rows) || { echo "merge-pass.sh: pr-ready.sh failed after a merge; pass ended" >&2; break; }
    continue
  fi
  echo "hold $next exit=$rc ${first:-}"; held=$((held + 1))
  if ((rc == 10)) && [[ "$out" == *outage:* ]]; then echo "stop outage $first"; beat; summary; exit 5; fi
done
beat
summary
