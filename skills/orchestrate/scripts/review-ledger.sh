#!/usr/bin/env bash
# Internal review ledger: the orchestrator's own review verdicts per PR (roles/review.md), newest
# last. The latest verdict is a merge gate (#206): anything but `ship` holds the PR on every merge
# path (pr-ready.sh SKIP `review:<verdict>`, pr-merge.sh exit 14, merge-queue.sh `held`) until a
# newer row says `ship`. The gate is one helper, orch_review_hold_of in _lib.sh.
#
# Usage: review-ledger.sh record  --pr N --verdict ship|fix-first|rethink [--head SHA] [--note TEXT]
#                                 [--repo OWNER/REPO]
#        review-ledger.sh fix     --pr N [--head SHA] [--note TEXT] [--repo OWNER/REPO]
#        review-ledger.sh latest  --pr N [--repo OWNER/REPO]
#        review-ledger.sh blocked [--repo OWNER/REPO]
#        review-ledger.sh list    [--pr N] [--repo OWNER/REPO]
#   record   append a verdict. A non-ship verdict also holds the PR (`hold.sh add --until
#            review-ship`) unless it is held already; `ship` releases a hold whose condition is
#            review-ship (`hold.sh release`) and leaves any other hold in place.
#   fix      a fix pass on the PR starts: append verdict `fixing` and hold it like a non-ship
#            verdict. Run it before the fix lane starts; only a newer `ship` lets the PR merge.
#   latest   the PR's newest row. Exit 3 when the PR has no verdict.
#   blocked  local only: `pr  verdict` for every PR whose latest verdict is not ship.
#   list     local only: every row (of one PR with --pr).
# The ledger is <state dir>/reviews.tsv, one row per verdict: iso  pr  verdict  head  note
# (head and note `-` when not given). Rows are only appended; never edit the file by hand.
# Exit: 0 ok | 2 usage | 3 no verdict (latest) | 4 the ledger could not be read
#       | 5 a write failed (ledger or hold)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  record | fix | latest | blocked | list) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" pr="" verdict="" head="" note=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=${2#\#}; shift 2 ;;
    --verdict) verdict=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    *) echo "review-ledger.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  record | fix | latest) [[ "$pr" =~ ^[0-9]+$ ]] || usage ;;
  list) [[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || usage ;;
esac
if [[ "$cmd" == record ]]; then
  case "$verdict" in
    ship | fix-first | rethink) ;;
    *) echo "review-ledger.sh: --verdict must be ship, fix-first or rethink" >&2; exit 2 ;;
  esac
fi
[[ "$cmd" != fix ]] || verdict=fixing

repo=$(orch_repo "$repo")
file="$(orch_state_dir "$repo")/reviews.tsv"
if [[ -e "$file" && ! ( -f "$file" && -r "$file" ) ]]; then
  echo "error: could not read $file" >&2; exit 4
fi

# rows [PR]: the ledger's well-formed rows (of PR), in file order.
rows() {
  [[ -f "$file" ]] || return 0
  awk -F'\t' -v pr="${1:-}" 'NF >= 5 && $2 ~ /^[0-9]+$/ && (pr == "" || $2 == pr)' "$file"
}
clean() { local s=${1//$'\t'/ }; s=${s//$'\n'/ }; echo "${s:--}"; }

case "$cmd" in
  latest)
    row=$(rows "$pr" | awk 'END { if (NR) print }')
    [[ -n "$row" ]] || { echo "no verdict: PR $pr has no internal review recorded"; exit 3; }
    printf '%s\n' "$row"
    ;;
  blocked) rows | awk -F'\t' '{ v[$2] = $3 } END { for (p in v) if (v[p] != "ship") print p "\t" v[p] }' | sort -n ;;
  list) rows "$pr" ;;
  record | fix)
    printf '%s\t%s\t%s\t%s\t%s\n' "$(orch_iso "$(orch_now)")" "$pr" "$verdict" "$(clean "$head")" "$(clean "$note")" >>"$file" ||
      { echo "error: could not append to $file" >&2; exit 5; }
    echo "recorded: PR $pr $verdict${head:+ at $head}"
    hrc=0
    hold=$(orch_hold_of "$repo" "$pr") || hrc=$?
    ((hrc != 2)) || { echo "error: the hold file could not be read; the verdict still gates PR $pr" >&2; exit 5; }
    if [[ "$verdict" == ship ]]; then
      if ((hrc == 0)) && [[ "$hold" == *" until:review-ship "* ]]; then
        "$here/hold.sh" release --repo "$repo" --pr "$pr" --note "review ship${head:+ at $head}" || exit 5
      elif ((hrc == 0)); then
        echo "still held: $hold"
      fi
    elif ((hrc == 0)); then
      echo "already held: $hold (kept; the verdict holds it too)"
    else
      "$here/hold.sh" add --repo "$repo" --pr "$pr" --until review-ship --reason "review $verdict${note:+: $(clean "$note")}" || exit 5
    fi
    ;;
esac
