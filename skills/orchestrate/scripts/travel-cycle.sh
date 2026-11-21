#!/usr/bin/env bash
# One traveling-mode orchestrator pass for a target repository (traveling-mode.md, "Hourly cycle"):
# what the hourly cloud routine runs while the host is off. It writes no code, never merges or posts
# orchestrate/review with its own identity (the App broker does: app-broker.sh), and works only
# while the store says MODE=traveling and it holds the store's lease.
#
# Usage: travel-cycle.sh run --repo OWNER/REPO --store DIR --holder ID [--app LOGIN]
#                            [--merge-cap N] [--review-cap N] [--repair-cap N] [--busy N]
#                            [--ready-label L] [--stale-hours H] [--dry-run]
#   --store   a checkout of the state store; its <owner>__<repo>/ folder is the state dir
#   --holder  this run's lease holder id, e.g. cloud-run:<session id>
#   --app     the App's login, whose orchestrate/review statuses count (default waaagh-bot[bot])
#   caps      merges per pass (8), cloud-review labels per pass (6), cloud-repair labels per pass
#             (4), worker labels live at once before dispatch stops (10)
#   --ready-label  issues a cloud worker may take (default cloud-ready)
#   --stale-hours  a worker label this old with no activity on its item is removed (default 3)
#   --dry-run  read everything, take no lease and write nothing: each write is printed as
#              `would <action> ...` instead
# Steps, each journaled to the store (journal.tsv) unless --dry-run:
#   1 lease     MODE must be traveling and the lease must be free, expired or this holder's
#   2 main      main-health.sh; only green allows merges
#   3 settle    review-ledger.sh settle; mirror the App's orchestrate/review statuses into the
#               ledger; confirm earlier merge requests that GitHub shows merged; remove worker
#               labels older than --stale-hours with no activity since
#   4 merge     READY (pr-ready.sh), App status success at the head, latest ledger verdict ship,
#               no repair in flight, not held: app-broker.sh merge
#   5 review    READY PRs with no App status at the head and no cloud-review label: add it
#   6 repair    BLOCK PRs with a failing check or a conflict, no cloud-repair label and none
#               added in the last hour: add it and record the repair (review-ledger.sh repair)
#   7 dispatch  open --ready-label issues with no worker label, no open PR closing them and no
#               open blocker (open-blockers.sh): add cloud-dispatch until --busy labels are live
#   8 hygiene   strip Co-Authored-By and "Generated with" lines from bodies of PRs on work/*-auto
#   9 release   journal the pass and release the lease
# Output: progress lines, then one summary line:
#   pass merged=<n> reviews=<n> repairs=<n> dispatched=<n> main=<green|red|unknown> [skipped=<why>]
# Exit: 0 the pass ran, or was skipped (mode local, lease held) | 3 the store or GitHub could not be
#   read where the pass cannot go on | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

[[ "${1:-}" == run ]] || { [[ "${1:-}" == -h || "${1:-}" == --help ]] && { orch_usage; exit 0; }; orch_usage >&2; exit 2; }
shift
repo="" store="" holder="" app="waaagh-bot[bot]" merge_cap=8 review_cap=6 repair_cap=4 busy=10 ready_label=cloud-ready stale_h=3 dry=no
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --store) store=${2:-}; shift 2 ;;
    --holder) holder=${2:-}; shift 2 ;;
    --app) app=${2:-}; shift 2 ;;
    --merge-cap) merge_cap=${2:-}; shift 2 ;;
    --review-cap) review_cap=${2:-}; shift 2 ;;
    --repair-cap) repair_cap=${2:-}; shift 2 ;;
    --busy) busy=${2:-}; shift 2 ;;
    --ready-label) ready_label=${2:-}; shift 2 ;;
    --stale-hours) stale_h=${2:-}; shift 2 ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "travel-cycle.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in "$merge_cap" "$review_cap" "$repair_cap" "$busy" "$stale_h"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "travel-cycle.sh: caps and --stale-hours must be numbers" >&2; exit 2; }
done
[[ "$repo" == */* && -n "$store" && -n "$holder" ]] || { echo "travel-cycle.sh: --repo, --store and --holder are required" >&2; exit 2; }
[[ -d "$store/.git" ]] || { echo "travel-cycle.sh: --store must be a checkout of the state store" >&2; exit 2; }
export ORCHESTRATE_STATE_DIR=$store ORCHESTRATE_GH_API=${ORCHESTRATE_GH_API:-rest}
ns=${repo//\//__} sdir="$store/$ns"
now=$(orch_now)
merged=0 reviews=0 repairs=0 dispatched=0 main=unknown

ts() { orch_run travel-store.sh "$@" --store "$store" --repo "$repo"; }
say() { printf '%s\n' "$*"; }
journal() { # ACTION DETAIL
  [[ "$dry" == yes ]] || ts journal --actor "$holder" --action "$1" --detail "$2" >/dev/null || true
}
finish() { say "pass merged=$merged reviews=$reviews repairs=$repairs dispatched=$dispatched main=$main${1:+ skipped=$1}"; exit 0; }
read_json() { orch_run gh-read.sh --json -- api "$1" 2>/dev/null; }
# write ARGS...: a GitHub write (gh api ...), or its `would` line under --dry-run.
write() { if [[ "$dry" == yes ]]; then say "would gh $*"; else gh "$@" >/dev/null; fi; }
add_label() { write api -X POST "repos/$repo/issues/$1/labels" -f "labels[]=$2"; }
remove_label() { write api -X DELETE "repos/$repo/issues/$1/labels/$2"; }

# --- 1 lease -----------------------------------------------------------------------------------
mode=$(ts mode) || { echo "travel-cycle.sh: the store could not be read" >&2; exit 3; }
[[ "$mode" == traveling ]] || finish mode-local
if [[ "$dry" == no ]]; then
  rc=0; ts lease take --holder "$holder" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) ;; 4) finish lease-held ;; *) finish store-unwritable ;; esac
  trap 'ts lease release --holder "$holder" >/dev/null 2>&1 || true' EXIT
fi

# --- 2 main health -------------------------------------------------------------------------------
rc=0; orch_run main-health.sh --repo "$repo" >/dev/null 2>&1 || rc=$?
case "$rc" in 0) main=green ;; 1) main=red ;; *) main=unknown ;; esac
say "main $main"

# --- reads shared by every step ------------------------------------------------------------------
prs=$(orch_run gh-issues.sh prs-open --repo "$repo" --limit 300 \
  --fields number,headRefName,labels,updatedAt,body,closingIssuesReferences,isDraft 2>/dev/null) ||
  { echo "travel-cycle.sh: open PRs unreadable" >&2; exit 3; }
rows=$(orch_run pr-ready.sh --repo "$repo" 2>/dev/null) || rows=""
held=$(orch_run hold.sh prs --repo "$repo" 2>/dev/null || true)
has_label() { jq -e --argjson n "$1" --arg l "$2" '.[] | select(.number == $n) | any(.labels[]?; .name == $l)' <<<"$prs" >/dev/null 2>&1; }
# app_state SHA: the newest orchestrate/review the App posted on SHA (success, failure, ...), or none.
app_state() {
  read_json "repos/$repo/commits/$1/statuses?per_page=100" | jq -r --arg a "$app" \
    '[.[]? | select(.context == "orchestrate/review" and .creator.login == $a)] | sort_by(.updated_at // .created_at) | last | .state // "none"' 2>/dev/null || echo none
}

# --- 3 settle ------------------------------------------------------------------------------------
[[ "$dry" == yes ]] || orch_run review-ledger.sh settle --repo "$repo" >/dev/null 2>&1 || true
while IFS=$'\t' read -r n verdict head _; do
  [[ "$n" =~ ^[0-9]+$ && "$head" =~ ^[0-9a-f]{7,40}$ ]] || continue
  st=$(app_state "$head")
  case "$st" in success) want=ship ;; failure) want=fix-first ;; *) continue ;; esac
  last=$(orch_run review-ledger.sh latest --repo "$repo" --pr "$n" 2>/dev/null | awk -F'\t' '{ print $3 "\t" $4 }' || true)
  [[ "$last" != "$want	$head" ]] || continue
  if [[ "$dry" == yes ]]; then say "would review-ledger.sh record --pr $n --verdict $want --head $head"
  else orch_run review-ledger.sh record --repo "$repo" --pr "$n" --verdict "$want" --head "$head" --note "orchestrate/review from $app" >/dev/null 2>&1 || true; fi
  journal verdict-mirrored "pr=$n verdict=$want head=${head:0:9}"
done <<<"$rows"
# Earlier merge requests that GitHub now shows merged.
if [[ -f "$sdir/journal.tsv" ]]; then
  while read -r n; do
    [[ -n "$n" ]] || continue
    state=$(read_json "repos/$repo/pulls/$n" | jq -r 'if .merged then "merged" else .state end' 2>/dev/null || echo unknown)
    [[ "$state" != merged ]] || { say "merged #$n (confirmed)"; journal merged "pr=$n"; }
  done < <(awk -F'\t' '$3 == "merge-request" { split($4, a, " "); sub("pr=", "", a[1]); req[a[1]] = 1 }
    $3 == "merged" { split($4, a, " "); sub("pr=", "", a[1]); delete req[a[1]] } END { for (p in req) print p }' "$sdir/journal.tsv")
fi
# Worker labels with no activity for --stale-hours: remove them, once.
for label in cloud-dispatch cloud-repair cloud-review; do
  items=$(orch_run gh-issues.sh issues --repo "$repo" --label "$label" --fields number,updatedAt --limit 100 2>/dev/null || echo '[]')
  items=$(jq -c --argjson p "$(jq -c --arg l "$label" '[.[] | select(any(.labels[]?; .name == $l)) | {number, updatedAt}]' <<<"$prs")" '. + $p | unique_by(.number)' <<<"$items" 2>/dev/null || echo '[]')
  while IFS=$'\t' read -r n upd; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    age=$(( (now - $(jq -rn --arg t "$upd" '$t | fromdateiso8601' 2>/dev/null || echo "$now")) / 3600 ))
    ((age >= stale_h)) || continue
    say "stale $label on #$n (${age}h idle): removed"
    remove_label "$n" "$label"
    journal label-stale "item=$n label=$label idle_h=$age"
  done < <(jq -r '.[] | "\(.number)\t\(.updatedAt)"' <<<"$items" 2>/dev/null)
done

# --- 4 merge ---------------------------------------------------------------------------------------
if [[ "$main" == green ]]; then
  while IFS=$'\t' read -r n verdict head _; do
    ((merged < merge_cap)) || break
    [[ "$verdict" == READY && "$head" =~ ^[0-9a-f]{40}$ ]] || continue
    grep -qx "$n" <<<"$held" && continue
    [[ "$(app_state "$head")" == success ]] || continue
    [[ "$(orch_run review-ledger.sh latest --repo "$repo" --pr "$n" 2>/dev/null | cut -f3)" == ship ]] || continue
    [[ -z "$(orch_run review-ledger.sh inflight --repo "$repo" --pr "$n" 2>/dev/null)" ]] || continue
    if [[ "$dry" == yes ]]; then say "would app-broker.sh merge --pr $n --sha $head"
    else orch_run app-broker.sh merge --repo "$repo" --pr "$n" --sha "$head" >/dev/null 2>&1 || { say "merge request for #$n refused"; continue; }; fi
    journal merge-request "pr=$n sha=${head:0:9}"
    say "merge requested #$n"
    merged=$((merged + 1))
  done <<<"$rows"
fi

# --- 5 review --------------------------------------------------------------------------------------
while IFS=$'\t' read -r n verdict head _; do
  ((reviews < review_cap)) || break
  [[ "$verdict" == READY && "$head" =~ ^[0-9a-f]{7,40}$ ]] || continue
  has_label "$n" cloud-review && continue
  [[ "$(app_state "$head")" == none ]] || continue
  add_label "$n" cloud-review
  journal label "item=$n label=cloud-review head=${head:0:9}"
  say "review #$n"
  reviews=$((reviews + 1))
done <<<"$rows"

# --- 6 repair --------------------------------------------------------------------------------------
recent_repair() { # N: a cloud-repair label added in the last hour, per the journal
  [[ -f "$sdir/journal.tsv" ]] || return 1
  awk -F'\t' -v n="item=$1 " -v since="$(orch_iso $((now - 3600)))" '$1 >= since && $3 == "label" && index($4 " ", n) == 1 && $4 ~ /label=cloud-repair/ { f = 1 } END { exit !f }' "$sdir/journal.tsv"
}
while IFS=$'\t' read -r n verdict head mergeable _ detail; do
  ((repairs < repair_cap)) || break
  [[ "$verdict" == BLOCK && "$n" =~ ^[0-9]+$ ]] || continue
  [[ "$detail" == *fail:* || "$mergeable" == CONFLICTING ]] || continue
  has_label "$n" cloud-repair && continue
  recent_repair "$n" && continue
  add_label "$n" cloud-repair
  [[ "$dry" == yes ]] || orch_run review-ledger.sh repair --repo "$repo" --pr "$n" --session "label:cloud-repair" >/dev/null 2>&1 || true
  journal label "item=$n label=cloud-repair head=${head:0:9}"
  say "repair #$n"
  repairs=$((repairs + 1))
done <<<"$rows"

# --- 7 dispatch ------------------------------------------------------------------------------------
live=$(jq '[.[] | select(any(.labels[]?; .name == "cloud-repair" or .name == "cloud-review"))] | length' <<<"$prs")
issues=$(orch_run gh-issues.sh issues --repo "$repo" --limit 300 --fields number,labels 2>/dev/null) || issues='[]'
live=$((live + $(jq '[.[] | select(any(.labels[]?; .name == "cloud-dispatch" or .name == "cloud-dispatched"))] | length' <<<"$issues")))
closed_by=$(jq -r '[.[] | .closingIssuesReferences[]?.number] | unique | .[]' <<<"$prs")
while read -r n; do
  ((live < busy)) || break
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  grep -qx "$n" <<<"$closed_by" && continue
  orch_run open-blockers.sh --repo "$repo" "$n" >/dev/null 2>&1 || continue
  add_label "$n" cloud-dispatch
  journal label "item=$n label=cloud-dispatch"
  say "dispatch #$n"
  dispatched=$((dispatched + 1)) live=$((live + 1))
done < <(jq -r --arg l "$ready_label" '.[] | select(any(.labels[]?; .name == $l))
  | select(all(.labels[]?; .name != "cloud-dispatch" and .name != "cloud-dispatched")) | .number' <<<"$issues" | sort -n)

# --- 8 hygiene -------------------------------------------------------------------------------------
while IFS=$'\t' read -r n; do
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body // ""' <<<"$prs")
  clean=$(grep -viE '^(co-authored-by:|.*generated with \[?claude)' <<<"$body" || true)
  [[ "$clean" != "$body" ]] || continue
  if [[ "$dry" == yes ]]; then say "would strip attribution from #$n"
  else gh api -X PATCH "repos/$repo/pulls/$n" -f body="$clean" >/dev/null || continue; fi
  journal hygiene "pr=$n stripped=attribution"
done < <(jq -r '.[] | select((.headRefName // "") | test("^work/[0-9]+-auto")) | .number' <<<"$prs")

# --- 9 release -------------------------------------------------------------------------------------
journal pass "merged=$merged reviews=$reviews repairs=$repairs dispatched=$dispatched main=$main"
finish
