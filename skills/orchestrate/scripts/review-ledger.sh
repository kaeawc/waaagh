#!/usr/bin/env bash
# Internal review ledger: the orchestrator's own review verdicts per PR (roles/review.md), newest
# last. The latest verdict is a merge gate (#206): anything but `ship` holds the PR on every merge
# path (pr-ready.sh SKIP `review:<verdict>`, pr-merge.sh exit 14, merge-queue.sh `held`) until a
# newer row says `ship`. The gate is one helper, orch_review_hold_of in _lib.sh.
# A repair session in flight (#212) is a state too: from `repair` until the repair ends, the PR
# never merges and `record --verdict ship` is refused, so a first pushed commit is never taken
# for the end of the repair.
#
# Usage: review-ledger.sh record   --pr N --verdict ship|fix-first|rethink [--head SHA] [--note TEXT]
#                                  [--repo OWNER/REPO]
#        review-ledger.sh fix      --pr N [--head SHA] [--note TEXT] [--repo OWNER/REPO]
#        review-ledger.sh repair   --pr N --session ID [--head SHA] [--note TEXT] [--repo R]
#        review-ledger.sh repaired --pr N [--session ID] [--head SHA] [--note TEXT] [--repo R]
#        review-ledger.sh settle   [--pr N] [--repo OWNER/REPO]
#        review-ledger.sh inflight [--pr N] [--repo OWNER/REPO]
#        review-ledger.sh latest   --pr N [--repo OWNER/REPO]
#        review-ledger.sh blocked  [--repo OWNER/REPO]
#        review-ledger.sh shipped  [--repo OWNER/REPO]
#        review-ledger.sh list     [--pr N] [--repo OWNER/REPO]
#   record   append a verdict. A non-ship verdict also holds the PR (`hold.sh add --until
#            review-ship`) unless it is held already; `ship` releases a hold whose condition is
#            review-ship (`hold.sh release`) and leaves any other hold in place. `ship` is
#            refused (exit 6) while a repair is in flight on the PR.
#   fix      a fix pass on the PR starts: append verdict `fixing` and hold it like a non-ship
#            verdict. Run it before the fix lane starts; only a newer `ship` lets the PR merge.
#   repair   a repair session was dispatched to the PR (cloud-dispatch.sh record --kind repair
#            runs it): append verdict `repairing` with the session id (the routine's trigger id)
#            and hold the PR like `fix`. It is in flight until a `repaired` row. The same session
#            again is a no-op; another while one is in flight is refused (exit 6).
#   repaired the repair ended (its run ended, or it posted its closing comment): append verdict
#            `repaired`, still not ship, so the final head needs a review before it merges. With
#            --session, refused (exit 6) when another session is the one in flight; with no
#            repair in flight it prints `no repair in flight: PR N` and appends nothing.
#   settle   for each repair in flight (of PR N), read the PR's comments since the dispatch: one
#            starting REPAIR-END or SUPERSEDED-CANDIDATE (briefs/repair.md) ends it as `repaired`.
#            Prints `settled #N session:ID <comment url>`, `inflight #N session:ID since:ISO`, or
#            `unknown #N session:ID comments unreadable` (then exit 7, after the others).
#   inflight local only: `pr  session  since` for every repair in flight (of PR N).
#   latest   the PR's newest row. Exit 3 when the PR has no verdict.
#   blocked  local only: `pr  verdict` for every PR whose latest verdict is not ship.
#   shipped  local only: `pr  head` for every PR whose latest verdict is ship recorded with --head.
#            The merge paths hold such a PR (`review:stale`) once its head moved past that head,
#            unless only GitHub-made update-branch merges came after it (orch_review_covers, #210).
#   list     local only: every row (of one PR with --pr).
# The ledger is <state dir>/reviews.tsv, one row per verdict: iso  pr  verdict  head  note
# [session] (head and note `-` when not given; the session only on repairing and repaired rows).
# Rows are only appended; never edit the file by hand.
# Exit: 0 ok | 2 usage | 3 no verdict (latest) | 4 the ledger could not be read
#       | 5 a write failed (ledger or hold) | 6 refused: a repair is in flight
#       | 7 settle: a PR's comments could not be read (its repair stays in flight)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  record | fix | repair | repaired | settle | inflight | latest | blocked | shipped | list) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" pr="" verdict="" head="" note="" session=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=${2#\#}; shift 2 ;;
    --verdict) verdict=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    --session) session=$2; shift 2 ;;
    *) echo "review-ledger.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  record | fix | repair | repaired | latest) [[ "$pr" =~ ^[0-9]+$ ]] || usage ;;
  list | settle | inflight) [[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || usage ;;
esac
if [[ "$cmd" == record ]]; then
  case "$verdict" in
    ship | fix-first | rethink) ;;
    *) echo "review-ledger.sh: --verdict must be ship, fix-first or rethink" >&2; exit 2 ;;
  esac
fi
[[ "$cmd" != repair || -n "$session" ]] || { echo "review-ledger.sh: repair needs --session" >&2; exit 2; }
[[ "$session" =~ ^[A-Za-z0-9_.:-]*$ ]] || { echo "review-ledger.sh: --session must be one word" >&2; exit 2; }
case "$cmd" in fix) verdict=fixing ;; repair) verdict=repairing ;; repaired) verdict=repaired ;; esac

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
# inflight [PR]: `pr  session  since` for each PR whose newest repairing/repaired row is repairing.
inflight() {
  rows "${1:-}" | awk -F'\t' '$3 == "repairing" { s[$2] = $6; t[$2] = $1; o[$2] = 1 } $3 == "repaired" { o[$2] = 0 }
    END { for (p in o) if (o[p]) print p "\t" (s[p] == "" ? "-" : s[p]) "\t" t[p] }' | sort -n
}
# append VERDICT [SESSION]: one row for $pr, with the session column only when given.
append() {
  printf '%s\t%s\t%s\t%s\t%s%s\n' "$(orch_iso "$(orch_now)")" "$pr" "$1" "$(clean "$head")" "$(clean "$note")" \
    "${2:+$'\t'$2}" >>"$file" || { echo "error: could not append to $file" >&2; exit 5; }
  echo "recorded: PR $pr $1${head:+ at $head}${2:+ session $2}"
}
# hold_after VERDICT: keep $pr's hold in step with the verdict just appended.
hold_after() {
  local hrc=0 hold
  hold=$(orch_hold_of "$repo" "$pr") || hrc=$?
  ((hrc != 2)) || { echo "error: the hold file could not be read; the verdict still gates PR $pr" >&2; exit 5; }
  if [[ "$1" == ship ]]; then
    if ((hrc == 0)) && [[ "$hold" == *" until:review-ship "* ]]; then
      "$here/hold.sh" release --repo "$repo" --pr "$pr" --note "review ship${head:+ at $head}" || exit 5
    elif ((hrc == 0)); then
      echo "still held: $hold"
    fi
  elif ((hrc == 0)); then
    echo "already held: $hold (kept; the verdict holds it too)"
  else
    "$here/hold.sh" add --repo "$repo" --pr "$pr" --until review-ship --reason "review $1${note:+: $(clean "$note")}" || exit 5
  fi
}

case "$cmd" in
  latest)
    row=$(rows "$pr" | awk 'END { if (NR) print }')
    [[ -n "$row" ]] || { echo "no verdict: PR $pr has no internal review recorded"; exit 3; }
    printf '%s\n' "$row"
    ;;
  blocked) rows | awk -F'\t' '{ v[$2] = $3 } END { for (p in v) if (v[p] != "ship") print p "\t" v[p] }' | sort -n ;;
  shipped) rows | awk -F'\t' '{ v[$2] = $3; h[$2] = $4 } END { for (p in v) if (v[p] == "ship" && h[p] != "-") print p "\t" h[p] }' | sort -n ;;
  list) rows "$pr" ;;
  inflight) inflight "$pr" ;;
  record | fix)
    fl=""
    [[ "$verdict" != ship ]] || fl=$(inflight "$pr")
    if [[ -n "$fl" ]]; then
      IFS=$'\t' read -r _ fs ft <<<"$fl"
      echo "refused: a repair is in flight on PR $pr (session $fs since $ft); record ship only after it ends (review-ledger.sh settle or repaired)" >&2
      exit 6
    fi
    append "$verdict"
    hold_after "$verdict"
    ;;
  repair)
    fl=$(inflight "$pr")
    if [[ -n "$fl" ]]; then
      IFS=$'\t' read -r _ fs ft <<<"$fl"
      if [[ "$fs" == "$session" ]]; then echo "already in flight: PR $pr session $fs since $ft"; exit 0; fi
      echo "refused: a repair is in flight on PR $pr (session $fs since $ft); end it first (review-ledger.sh repaired)" >&2
      exit 6
    fi
    append repairing "$session"
    hold_after repairing
    ;;
  repaired)
    fl=$(inflight "$pr")
    [[ -n "$fl" ]] || { echo "no repair in flight: PR $pr"; exit 0; }
    IFS=$'\t' read -r _ fs _ <<<"$fl"
    if [[ -n "$session" && "$session" != "$fs" ]]; then
      echo "refused: the repair in flight on PR $pr is session $fs, not $session" >&2
      exit 6
    fi
    append repaired "$fs"
    hold_after repaired
    ;;
  settle)
    src=0 fl=$(inflight "$pr")
    while IFS=$'\t' read -r p fs ft; do
      [[ -n "$p" ]] || continue
      url="" rc=0
      com=$(orch_read_retry 3 gh api "repos/$repo/issues/$p/comments?per_page=100&since=$ft" </dev/null) || rc=$?
      ((rc != 0)) || url=$(jq -r --arg t "$ft" '
        if type != "array" then error("not a list") else
          [.[] | select((.created_at // "") >= $t)
           | select((.body // "") | test("^\\s*(REPAIR-END|SUPERSEDED-CANDIDATE)")) | (.html_url // "-")]
          | first // "" end' <<<"$com" 2>/dev/null) || rc=1
      if ((rc != 0)); then echo "unknown #$p session:$fs comments unreadable"; src=7; continue; fi
      if [[ -z "$url" ]]; then echo "inflight #$p session:$fs since:$ft"; continue; fi
      pr=$p head="" note="closing comment $url"
      append repaired "$fs" >/dev/null
      hold_after repaired </dev/null >/dev/null
      echo "settled #$p session:$fs $url"
    done <<<"$fl"
    exit "$src"
    ;;
esac
