#!/usr/bin/env bash
# Merge-loop holds: the PRs the merge loop must not merge, each with a machine-checkable release
# condition and the time it was set, and a release that edits the hold file and writes the log line
# in one step, so the log can never claim a release the file does not show (#196).
#
# Usage: hold.sh add     --pr N --until EVENT [--reason TEXT] [--repo OWNER/REPO]
#        hold.sh release --pr N [--note TEXT] [--repo OWNER/REPO]
#        hold.sh list    [--repo OWNER/REPO]
#        hold.sh prs     [--repo OWNER/REPO]
#        hold.sh stale   [--hours H] [--repo OWNER/REPO]
#        hold.sh check   [--pr N] [--release] [--repo OWNER/REPO]
#   add      hold PR N until EVENT (replaces an existing hold on N, keeping nothing of it).
#   release  remove N's line from the hold file, then append the release to holds.log. Exit 3 (and
#            no log line) when N is not held.
#   list     local only, one TSV row per hold: pr  until  since  age_h  reason
#   prs      local only, the held PR numbers, one per line (pr-ready.sh reads them itself).
#   stale    local only: holds older than H hours (default ORCHESTRATE_HOLD_STALE_HOURS, 12) or of
#            unknown age, one line each: `#N age=<h>h|unknown until:<event> reason=<text>`.
#   check    evaluate each hold's release condition (reads GitHub for merged:, closed: and
#            device-recheck), one line each: `#N met|unmet|manual|unknown until:<event> <detail>`.
#            With --release, every met hold is released (same as `release`, note "condition met").
# Release conditions (EVENT):
#   device-recheck  device-recheck.sh check on the PR's current head says clear
#   main-green      no MAIN_RED in the state dir
#   review-ship     the PR's latest internal review verdict (review-ledger.sh latest) is ship;
#                   review-ledger.sh sets and releases it itself (#206)
#   merged:M        PR M is merged
#   closed:M        issue (or PR) M is closed
#   at:ISO          the time ISO (2026-01-02T03:04:05Z) has passed
#   owner           only the owner's word releases it: never met by check
# The hold file is <state dir>/holds, one hold per line: `<pr> until:<event> since:<iso> <reason>`.
# Older lines (`<pr>`, `#<pr>`, `<pr> <free text>`) still read: their condition and age are
# unknown, so check reports them as manual and stale reports them every time until re-added with
# --until. Lines starting `# ` and blank lines are comments. Every add and release appends one line
# to <state dir>/holds.log (`<iso>  pr=N  held|released ...`); never write those lines by hand.
# Exit: 0 ok | 2 usage | 3 not held (release) or stale holds found (stale) | 4 the hold file is
#       locked by another writer | 5 a write failed
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  add | release | list | prs | stale | check) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" pr="" until_ev="" reason="" note="" hours=${ORCHESTRATE_HOLD_STALE_HOURS:-12} do_release=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=${2#\#}; shift 2 ;;
    --until) until_ev=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    --hours) hours=$2; shift 2 ;;
    --release) do_release=yes; shift ;;
    *) echo "hold.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$hours" =~ ^[0-9]+$ ]] || { echo "hold.sh: --hours must be a whole number" >&2; exit 2; }
case "$cmd" in
  add | release) [[ "$pr" =~ ^[0-9]+$ ]] || usage ;;
  check) [[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || usage ;;
esac
valid_event() {
  case "$1" in
    device-recheck | main-green | review-ship | owner) return 0 ;;
    merged:* | closed:*) [[ "${1#*:}" =~ ^[0-9]+$ ]] ;;
    at:*) [[ "${1#at:}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ;;
    *) return 1 ;;
  esac
}
if [[ "$cmd" == add ]]; then
  valid_event "$until_ev" ||
    { echo "hold.sh: --until must be device-recheck, main-green, review-ship, owner, merged:N, closed:N or at:ISO" >&2; exit 2; }
fi

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
file="$state/holds"
logf="$state/holds.log"
now=$(orch_now)
now_iso=$(orch_iso "$now")

# parsed: the hold file as TSV rows `pr  until  since  reason`; unknown fields read "unknown",
# an empty reason "-". The last line for a PR wins.
parsed() {
  [[ -f "$file" ]] || return 0
  awk '
    /^[ \t]*$/ { next }
    { sub(/^[ \t]+/, "") }
    !/^#?[0-9]+([ \t]|$)/ { next }
    { pr = $1; sub(/^#/, "", pr); u = "unknown"; s = "unknown"; r = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^until:/ && u == "unknown") { u = substr($i, 7); continue }
        if ($i ~ /^since:/ && s == "unknown") { s = substr($i, 7); continue }
        r = r (r == "" ? "" : " ") $i
      }
      if (!(pr in row)) order[++n] = pr
      row[pr] = pr "\t" u "\t" s "\t" (r == "" ? "-" : r) }
    END { for (i = 1; i <= n; i++) print row[order[i]] }' "$file"
}

# age_h ISO -> whole hours since ISO, or "unknown".
age_h() {
  local t
  if [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] &&
    t=$(jq -rn --arg s "$1" '$s | fromdateiso8601' 2>/dev/null); then
    echo $(((now - t) / 3600))
  else
    echo unknown
  fi
}

lockd="$state/holds.lock"
unlock() { rmdir "$lockd" 2>/dev/null || true; }
lock() {
  local i
  for ((i = 0; i < 50; i++)); do
    if mkdir "$lockd" 2>/dev/null; then trap unlock EXIT; return 0; fi
    sleep 0.1
  done
  echo "hold.sh: the hold file is locked by another writer ($lockd); retry" >&2
  exit 4
}

# rewrite PR [LINE]: the hold file without PR's lines (plus LINE when given), written atomically.
rewrite() {
  local tmp="$file.tmp.$$"
  {
    if [[ -f "$file" ]]; then
      awk -v pr="$1" '{ l = $0; sub(/^[ \t]+/, "", l); p = l; sub(/[ \t].*/, "", p); sub(/^#/, "", p)
        if (l ~ /^#?[0-9]+([ \t]|$)/ && p == pr) next; print }' "$file"
    fi
    [[ -z "${2:-}" ]] || printf '%s\n' "$2"
  } >"$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; echo "error: could not write $file" >&2; exit 5; }
}
held_row() { parsed | awk -F'\t' -v pr="$1" '$1 == pr'; }
logline() { printf '%s\tpr=%s\t%s\n' "$now_iso" "$1" "$2" >>"$logf" || { echo "error: could not append to $logf" >&2; exit 5; }; }

# release_one PR NOTE: drop the line, confirm the file no longer holds PR, then log.
release_one() {
  local row u s a
  row=$(held_row "$1")
  [[ -n "$row" ]] || { echo "not held: PR $1 is not in $file"; return 3; }
  IFS=$'\t' read -r _ u s _ <<<"$row"
  rewrite "$1"
  [[ -z "$(held_row "$1")" ]] || { echo "error: PR $1 is still in $file after the rewrite" >&2; exit 5; }
  a=$(age_h "$s")
  [[ "$a" == unknown ]] || a="${a}h"
  logline "$1" "released until:$u since:$s held=$a${2:+ note=$2}"
  echo "released: PR $1 (until:$u, held $a)"
}

case "$cmd" in
  add)
    lock
    line="$pr until:$until_ev since:$now_iso ${reason:--}"
    line=${line//$'\n'/ }
    prev=$(held_row "$pr")
    rewrite "$pr" "$line"
    logline "$pr" "held until:$until_ev reason=${reason:--}${prev:+ (replaced an earlier hold)}"
    echo "held: PR $pr until:$until_ev"
    ;;
  release)
    lock
    rc=0
    release_one "$pr" "$note" || rc=$?
    exit "$rc"
    ;;
  list)
    parsed | while IFS=$'\t' read -r p u s r; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$u" "$s" "$(age_h "$s")" "$r"
    done
    ;;
  prs) parsed | cut -f1 ;;
  stale)
    found=0
    while IFS=$'\t' read -r p u s r; do
      a=$(age_h "$s")
      if [[ "$a" == unknown ]] || ((a >= hours)); then
        found=1
        echo "#$p age=$([[ "$a" == unknown ]] && echo unknown || echo "${a}h") until:$u reason=$r"
      fi
    done < <(parsed)
    ((found == 0)) || exit 3
    ;;
  check)
    rows=$(parsed)
    [[ -z "$pr" ]] || rows=$(awk -F'\t' -v pr="$pr" '$1 == pr' <<<"$rows")
    [[ -n "$rows" ]] || exit 0
    [[ "$do_release" == no ]] || lock
    while IFS=$'\t' read -r p u s r; do
      v=unknown d=""
      case "$u" in
        owner) v=manual d="only the owner releases it" ;;
        main-green) if [[ -f "$state/MAIN_RED" ]]; then v=unmet d="MAIN_RED is set"; else v=met d="no MAIN_RED"; fi ;;
        review-ship)
          rrc=0
          rrow=$("$here/review-ledger.sh" latest --repo "$repo" --pr "$p" </dev/null 2>/dev/null) || rrc=$?
          rv=$(cut -f3 <<<"$rrow")
          case "$rrc" in
            0) if [[ "$rv" == ship ]]; then v=met d="latest review: ship"; else v=unmet d="latest review: $rv"; fi ;;
            3) v=unmet d="no review recorded" ;;
            *) d="the review ledger could not be read" ;;
          esac ;;
        at:*) if [[ "$now_iso" > "${u#at:}" || "$now_iso" == "${u#at:}" ]]; then v=met d="${u#at:} passed"; else v=unmet d="not before ${u#at:}"; fi ;;
        merged:*)
          n=${u#merged:}
          if j=$(orch_read_retry 3 gh api "repos/$repo/pulls/$n" </dev/null) && m=$(jq -r 'if .merged_at then "yes" else "no" end' <<<"$j" 2>/dev/null); then
            if [[ "$m" == yes ]]; then v=met d="PR $n merged"; else v=unmet d="PR $n not merged"; fi
          else d="PR $n could not be read"; fi ;;
        closed:*)
          n=${u#closed:}
          if j=$(orch_read_retry 3 gh api "repos/$repo/issues/$n" </dev/null) && st=$(jq -r '.state // empty' <<<"$j" 2>/dev/null) && [[ -n "$st" ]]; then
            if [[ "$st" == closed ]]; then v=met d="#$n closed"; else v=unmet d="#$n $st"; fi
          else d="#$n could not be read"; fi ;;
        device-recheck)
          drc=0
          dout=$("$here/device-recheck.sh" check --repo "$repo" --pr "$p" </dev/null 2>/dev/null) || drc=$?
          case "$drc" in 0) v=met ;; 3) v=unmet ;; *) v=unknown ;; esac
          d=$(printf '%s' "$dout" | sed -n 1p) ;;
        *) v=manual d="no release condition (legacy line): re-add it with --until" ;;
      esac
      echo "#$p $v until:$u ${d:-$r}"
      if [[ "$v" == met && "$do_release" == yes ]]; then release_one "$p" "condition met: $d"; fi
    done <<<"$rows"
    ;;
esac
