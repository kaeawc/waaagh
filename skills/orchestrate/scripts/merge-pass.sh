#!/usr/bin/env bash
# One merge pass over the open PRs (#411): the merge bot's steps 2-3 (roles/merge-bot.md) as one
# script, so a campaign's merge loop is `merge-pass.sh` plus a sleep instead of its own copy of
# pr-ready.sh and pr-merge.sh logic.
#
# Usage: merge-pass.sh [--repo OWNER/REPO] [--author LOGIN]... [--ignore-check NAME]...
#                      [--exclude-label LABEL]... [--cap N] [--max-untested N --workflow NAME]
#                      [--every SECONDS] [--loop-pid PID] [--dry-run]
#   --cap           merge at most N PRs this pass (default 8)
#   --max-untested  merge only while fewer than N commits on the default branch are past the
#                   newest one whose --workflow push run finished green; the cap this pass is
#                   N minus that count (auto-mobile's "at most 3 merges on top of a green main")
#   --every         the loop's sleep, recorded with the heartbeat (loops.sh heartbeat merge-pass)
#   --loop-pid      the loop's PID for the heartbeat (default the parent process: the loop that
#                   runs this pass), so loops.sh status sees the loop alive between passes
#   --dry-run       print what it would merge; merge nothing
# A pass:
#   1. main-health.sh (with --workflow when given): red or unknown holds the whole pass.
#   2. hold.sh check --release (met holds are released: hold.sh's `released: PR N ...` lines), then pr-ready.sh
#      with --author, --ignore-check and --exclude-label (needs-device-recheck always), the
#      priority file's PRs in PR_READY_EXTRA; a short page is reported (`note pr-ready ...`), and
#      shipped-blocked.sh prints each approved PR that is not READY.
#   Serial groups: <state dir>/serial-groups, `NAME REGEX` per line; PRs whose title matches REGEX
#      (extended, any case) merge one per pass (`hold <n> serial:NAME (one merge per pass)`).
#   3. READY rows in order: the PR numbers in <state dir>/merge-priority first (one per line, in
#      file order), then the rest oldest first. Before each: device-recheck.sh check (anything
#      but exit 0 holds it).
#      Then pr-merge.sh --pr N --head H. After a merge the rows are read again (mergeability of
#      the others changes); `outage:` from pr-merge.sh ends the pass.
# Output, one line each: `merged <n>` | `hold <n> <reason>` | `would merge <n>` (--dry-run)
#   | `hold main <main-health line>` | `hold untested=<k> since=<sha>` | `stop outage <line>`,
#   then `pass merged=<n> held=<n> ready=<n> cap=<n> untested=<k|->`.
# Env: ORCHESTRATE_SCRIPTS_DIR (tests stub the scripts it runs).
# Exit: 0 the pass ran (even with nothing to merge) | 2 usage (also an invalid serial-groups REGEX)
#       | 3 pr-ready.sh failed, or the titles serial-groups needs could not be read
#       | 4 held: main is red or unknown, or the untested cap is used up | 5 Pull Requests outage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

repo="" cap=8 untested_max="" workflow="" every="" dry=no loop_pid=$PPID
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
    --loop-pid) loop_pid=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "merge-pass.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$cap" =~ ^[0-9]+$ ]] || { echo "merge-pass.sh: --cap needs a number" >&2; exit 2; }
[[ -z "$untested_max" || "$untested_max" =~ ^[0-9]+$ ]] || { echo "merge-pass.sh: --max-untested needs a number" >&2; exit 2; }
[[ -z "$untested_max" || -n "$workflow" ]] || { echo "merge-pass.sh: --max-untested needs --workflow" >&2; exit 2; }
[[ -z "$every" || "$every" =~ ^[0-9]+$ ]] || { echo "merge-pass.sh: --every needs seconds" >&2; exit 2; }
[[ "$loop_pid" =~ ^[0-9]+$ ]] || { echo "merge-pass.sh: --loop-pid needs a PID" >&2; exit 2; }
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")

beat() {
  # The loop's PID, not this pass's: the pass exits after each run, the loop lives on.
  local a=(heartbeat merge-pass --repo "$repo" --pid "$loop_pid")
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
  default=$(orch_default_branch "$repo" 2>/dev/null) || default=""
  [[ -n "$default" ]] || { echo "hold untested=unknown since=- (the default branch could not be read)"; beat; summary; exit 4; }
  green=$("$here/gh-read.sh" --tries 3 -- api "repos/$repo/actions/runs?branch=$default&event=push&status=success&per_page=100" 2>/dev/null |
    jq -r --arg w "$workflow" '[.workflow_runs[]? | select(.name == $w)] | sort_by(.created_at) | last | .head_sha // empty' 2>/dev/null) || green=""
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

# Holds whose release condition is met are released first (merge-bot step 2).
# hold.sh prints `released: PR N ...` only once the hold file is rewritten.
orch_run hold.sh check --repo "$repo" --release 2>/dev/null | grep -E '^released: PR [0-9]+' || true
# Priority PRs are classified even when a full page leaves them out (PR_READY_EXTRA).
extra=$(awk '/^[0-9]+/ { sub(/[^0-9].*/, ""); printf "%s ", $0 }' "$state/merge-priority" 2>/dev/null || true)
# rows: "<n> <head>" for every READY row, in merge order. The full rows are kept in $rowfile for
# shipped-blocked.sh, and pr-ready's summary line in $sumfile.
rowfile=$(mktemp "${TMPDIR:-/tmp}/merge-pass-rows.XXXXXX") sumfile=$(mktemp "${TMPDIR:-/tmp}/merge-pass-sum.XXXXXX")
trap 'rm -f "$rowfile" "$sumfile"' EXIT
rows() {
  PR_READY_EXTRA="${PR_READY_EXTRA:-} $extra" orch_run pr-ready.sh "${ready_args[@]}" >"$rowfile" 2>"$sumfile" || return 1
  awk -F'\t' '$2 == "READY" { print $1, $3 }' "$rowfile" |
    awk -v pf="$state/merge-priority" 'BEGIN { while ((getline l < pf) > 0) if (l ~ /^[0-9]+/) { sub(/[^0-9].*/, "", l); if (!(l in rank)) rank[l] = ++r } }
      { k = ($1 in rank) ? rank[$1] : 1000000 + $1; print k, $0 }' | sort -n | cut -d' ' -f2-
}
# Serial groups (#412): <state dir>/serial-groups, one `NAME REGEX` per line (# comments): open
# PRs whose title matches REGEX (extended, any case) merge one per pass, so PRs that edit the same
# files land one at a time on a fresh base. The first READY row of a group in merge order goes;
# when it merges, every group it is in waits for the next pass. Titles are read over REST (every
# page; works where GraphQL is refused); a READY PR missing from that list is read on its own, and
# held (`serial:unknown`) when that fails. An invalid REGEX is a usage error (exit 2).
groups_of() { :; }
gfile="$state/serial-groups"
if [[ -f "$gfile" ]]; then
  groups=$(sed -e 's/\r$//' -e 's/^[[:space:]]*//' "$gfile" | grep -v -e '^$' -e '^#' || true)
  while read -r name re; do
    [[ -n "$name" ]] || continue
    grc=0; grep -qE -- "${re:-}" </dev/null 2>/dev/null || grc=$?
    if [[ -z "$re" ]] || ((grc == 2)); then echo "merge-pass.sh: serial-groups: no valid REGEX for group $name" >&2; exit 2; fi
  done <<<"$groups"
  titles=$("$here/gh-read.sh" --tries 3 -- api --paginate "repos/$repo/pulls?state=open&per_page=100" \
    --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null) ||
    { echo "merge-pass.sh: serial-groups is set but the PR titles could not be read; nothing merged" >&2; beat; summary; exit 3; }
  # groups_of N: every group whose regex matches N's title (one per line); `?` when the title
  # cannot be read.
  groups_of() {
    local t name re
    t=$(awk -F'\t' -v n="$1" '$1 == n { sub(/^[^\t]*\t/, ""); print; exit }' <<<"$titles")
    if [[ -z "$t" ]]; then
      t=$("$here/gh-read.sh" --tries 3 -- api "repos/$repo/pulls/$1" --jq .title 2>/dev/null) || { echo "?"; return 0; }
      titles+=$'\n'"$1"$'\t'"$t"
    fi
    while read -r name re; do
      [[ -n "$re" ]] || continue
      ! grep -qiE -- "$re" <<<"$t" || echo "$name"
    done <<<"$groups"
  }
fi
merged_groups=" "
done_prs=" "
if ! list=$(rows); then echo "merge-pass.sh: pr-ready.sh failed; nothing merged" >&2; beat; summary; exit 3; fi
ready=$(grep -c . <<<"$list" || true)
# Older PRs may be missing from a short page: say so every pass.
sum=$(tail -n 1 "$sumfile")
case "$sum" in *truncated=yes* | *page=*) echo "note pr-ready $sum" ;; esac
# Approved PRs that are not READY (merge-bot step 2): one line each, never dropped unread.
orch_run shipped-blocked.sh --repo "$repo" --rows "$rowfile" 2>/dev/null || true
while ((merged < cap)); do
  next="" head=""
  while read -r n h; do
    [[ -n "$n" && "$done_prs" != *" $n "* ]] || continue
    next=$n head=$h; break
  done <<<"$list"
  [[ -n "$next" ]] || break
  done_prs+="$next "
  gs=$(groups_of "$next" | tr '\n' ' ')
  if [[ "$gs" == "? " ]]; then echo "hold $next serial:unknown (its title could not be read)"; held=$((held + 1)); continue; fi
  busy=""
  for g in $gs; do [[ "$merged_groups" != *" $g "* ]] || { busy=$g; break; }; done
  if [[ -n "$busy" ]]; then echo "hold $next serial:$busy (one merge per pass)"; held=$((held + 1)); continue; fi
  dl=$(orch_run device-recheck.sh check --repo "$repo" --pr "$next" 2>/dev/null) && drc=0 || drc=$?
  # Anything but a clear answer holds: a crash must not let a device-regression fix through.
  if ((drc != 0)); then echo "hold $next ${dl:-device-recheck.sh exit $drc}"; held=$((held + 1)); continue; fi
  if [[ "$dry" == yes ]]; then echo "would merge $next"; merged=$((merged + 1)); merged_groups+="$gs"; continue; fi
  out=$(orch_run pr-merge.sh "${merge_args[@]}" --pr "$next" --head "$head" 2>&1) && rc=0 || rc=$?
  first=$(head -n 1 <<<"$out")
  if ((rc == 0)); then
    echo "merged $next"; merged=$((merged + 1)); merged_groups+="$gs"
    list=$(rows) || { echo "merge-pass.sh: pr-ready.sh failed after a merge; pass ended" >&2; break; }
    continue
  fi
  echo "hold $next exit=$rc ${first:-}"; held=$((held + 1))
  if ((rc == 10)) && [[ "$out" == *outage:* ]]; then echo "stop outage $first"; beat; summary; exit 5; fi
done
beat
summary
