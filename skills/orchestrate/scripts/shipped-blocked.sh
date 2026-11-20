#!/usr/bin/env bash
# Why an approved PR does not merge (#269): every open PR whose latest internal review verdict is
# ship recorded for its current head (review-ledger.sh shipped) but whose pr-ready.sh row is not
# READY gets one line with pr-ready's reasons. A merge loop selects only READY rows, so without
# this an approved, green PR blocked by an unresolved review thread sits unmerged and unreported.
#
# Usage: shipped-blocked.sh [--repo OWNER/REPO] [--rows FILE] [--pr N]... [-- PR-READY-ARGS...]
#   --rows FILE  judge the rows of an earlier pr-ready.sh run (its stdout; `-` reads stdin) instead
#                of running pr-ready.sh again; a merge loop that already holds them passes them
#   --pr N       judge only PR N (repeatable). Such a PR with no pr-ready row (another author,
#                another base, left off the page) prints verdict=unlisted reason=not-selected
#                rather than nothing; give --pr only for PRs known to be open (triage-tick.sh
#                snapshot passes its open, non-draft PRs whose latest verdict is ship)
#   PR-READY-ARGS  passed to pr-ready.sh (e.g. --author LOGIN --ignore-check NAME), after --repo;
#                its stderr summary is dropped (its diagnostics file still records read problems)
# Output, one line per such PR, oldest first:
#   shipped-blocked #<pr> verdict=<BLOCK|WAIT|BEHIND|SKIP|unlisted> reason=<detail>
#   <detail> is the row's detail with its space-separated reasons joined by commas, e.g.
#   reason=threads=1 or reason=conflict,fail:build ("-" when the row gives none). A ship verdict
#   pinned to a head the PR's head does not extend by GitHub update-branch merges alone is not at
#   head (pr-ready.sh shows it SKIP review:stale) and is left out, as is a ship recorded without
#   --head. Drafts are left out: triage-tick.sh snapshot names them
#   on its reviewed-draft lines. Nothing is printed when every such PR is READY or there is none.
# Exit: 0 ok | 2 usage | 3 readiness unreadable (pr-ready.sh failed or --rows FILE unreadable;
#       nothing printed) | 4 the review ledger could not be read
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

repo="" rows_file="" only=() pass=()
while (($#)); do
  case "$1" in
    --repo) repo=${2:?--repo needs OWNER/REPO}; shift 2 ;;
    --rows) rows_file=${2:?--rows needs a FILE}; shift 2 ;;
    --pr) [[ "${2:-}" =~ ^#?[0-9]+$ ]] || { echo "shipped-blocked.sh: --pr needs a PR number" >&2; exit 2; }
      only+=("${2#\#}"); shift 2 ;;
    --) shift; pass=("$@"); break ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "shipped-blocked.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")

lrc=0
shipped=$(orch_run review-ledger.sh shipped --repo "$repo") || lrc=$?
((lrc == 0)) || { echo "shipped-blocked.sh: the review ledger could not be read (review-ledger.sh exit $lrc)" >&2; exit 4; }
if ((${#only[@]})); then
  shipped=$(awk -F'\t' -v want=" ${only[*]} " 'index(want, " " $1 " ")' <<<"$shipped")
fi
[[ -n "$shipped" ]] || exit 0

if [[ -n "$rows_file" ]]; then
  if [[ "$rows_file" == - ]]; then rows=$(cat)
  elif [[ -f "$rows_file" && -r "$rows_file" ]]; then rows=$(cat "$rows_file")
  else echo "shipped-blocked.sh: --rows $rows_file is not readable" >&2; exit 3; fi
else
  prc=0
  rows=$(orch_run pr-ready.sh --repo "$repo" ${pass[@]+"${pass[@]}"} 2>/dev/null) || prc=$?
  ((prc == 0)) || { echo "shipped-blocked.sh: pr-ready.sh exit $prc; readiness unknown" >&2; exit 3; }
fi

# Join the ledger (pr, ship head) with the rows (pr, verdict, head, mergeable, passed, detail).
# pr-ready.sh already judged whether the ship verdict covers the row's head (orch_review_covers:
# the same head, or only GitHub update-branch merges since, #210); one that does not is SKIP
# review:stale, which is a review to do, not a hidden blocker.
awk -F'\t' -v listed="${only[*]-}" '
  NR == FNR { if ($1 ~ /^[0-9]+$/ && $2 != "" && $2 != "-") ship[$1] = $2; next }
  $1 in ship && !($1 in seen) {
    seen[$1] = 1
    if ($2 == "READY" || ($2 == "SKIP" && $6 ~ /(^| )(draft|review:stale)( |$)/)) next
    d = $6; gsub(/^ +| +$/, "", d); gsub(/ +/, ",", d)
    printf "shipped-blocked #%s verdict=%s reason=%s\n", $1, $2, (d == "" ? "-" : d)
  }
  END {
    n = split(listed, l, " ")
    for (i = 1; i <= n; i++) if ((l[i] in ship) && !(l[i] in seen))
      printf "shipped-blocked #%s verdict=unlisted reason=not-selected\n", l[i]
  }' <(printf '%s\n' "$shipped") <(printf '%s\n' "$rows") | sort -t'#' -k2,2n
