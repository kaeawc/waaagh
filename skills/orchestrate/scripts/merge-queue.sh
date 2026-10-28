#!/usr/bin/env bash
# Serial local merge queue: bring each queued branch up to date with the default branch, run a
# check command, push, open a PR if needed, wait for fresh readiness evidence, and merge it through
# pr-merge.sh. One pass per `run-once`; there is no daemon and no sleep loop, so no role polls.
#
# Usage: merge-queue.sh <add|run-once|status|retry|parent> [--repo OWNER/REPO] [options]
#   add       --id ID --worktree DIR --branch B --title T --body-file F [--requires ID,ID|-|auto]
#             Appends a row to <state dir>/merge-queue/queue.tsv. A duplicate id is refused.
#             `--requires auto` depends on the queued item whose branch is `parent B`.
#   run-once  Refresh main health, then process eligible items in file order, serially, until the
#             pass ends. An item runs when it has no outcome (or `waiting`) and every id in
#             `requires` has outcome `merged`.
#   status    One line per item: id, outcome (or `pending` / `blocked:<ids>`), branch.
#   retry ID  Clear a non-merged outcome so the next run-once picks the item up again.
#   parent B  Print the branch B stacks on: `name-3` -> `name-2`, `name-2` -> `name`, else nothing.
# Outcomes in <state dir>/merge-queue/<id>.outcome (the reason follows on the next line):
#   merged     done; the only outcome that satisfies a dependent
#   waiting    pushed, but not merged yet: checks pending or not reported, mergeability unknown,
#              GitHub not yet showing the pushed head, a merge queued on GitHub, a merge whose
#              outcome could not be read back, or a transient read failure. The next run-once
#              first re-checks the item's known PR (MERGED -> merged, without any new push, PR or
#              merge), then resumes, skipping the base merge, check and push when nothing moved
#   blocked    readiness found a real blocker (failed check, review thread, conflict, unknown
#              policy...); parked until `retry`
#   conflict | checkfail | error   parked until `retry`
# The merge is never attempted for an item that is not READY on a fresh pr-ready.sh row for the
# exact pushed head, whatever the server's branch protection would allow; pr-merge.sh re-checks.
# Logs of the check and of errors are under <state dir>/merge-queue/logs/.
# Env: MERGE_QUEUE_CHECK_CMD   run in the worktree after the base merge (unset: no check; a
#                              direct-merge campaign should still set a cheap structural gate)
#      MERGE_QUEUE_ADMIN_EVIDENCE, MERGE_QUEUE_ADMIN_CHECKS (comma list)  a BLOCK row whose only
#                              blockers are failures of those checks goes to pr-merge.sh --admin
#                              --except-check ...; pr-merge.sh enforces the fast-path, authorization
#                              and every other gate
#      MERGE_QUEUE_MAIN_HEALTH_ARGS  extra main-health.sh flags (e.g. --ignore-workflow Badges)
#      ORCHESTRATE_DIRECT_MERGE=1    deliberate ungated mode (only on the user's word): no readiness
#                              gate here or in pr-merge.sh
# Exit (run-once): 0 pass finished | 4 default branch red, pass stopped (hold, no outcome written)
# The worktree must be clean and on the branch. Never forces a push and never rewrites history.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi

# parent_branch NAME-N -> the branch NAME-N stacks on. The parent of `-2` is the bare name.
parent_branch() {
  local b=$1
  if [[ "$b" =~ ^(.+)-([0-9]+)$ ]]; then
    local name=${BASH_REMATCH[1]} n=$((10#${BASH_REMATCH[2]}))
    if ((n == 2)); then echo "$name"; elif ((n > 2)); then echo "$name-$((n - 1))"; fi
  fi
}

if [[ "$cmd" == parent ]]; then
  parent_branch "${1:?parent needs a branch}"
  exit 0
fi

repo="" id="" worktree="" branch="" title="" body="" requires="-" arg=""
case "$cmd" in
  add | run-once | status | retry) ;;
  *) sed -n '2,39p' "$0" >&2; exit 2 ;;
esac
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --id) id=$2; shift 2 ;;
    --worktree) worktree=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --body-file) body=$2; shift 2 ;;
    --requires) requires=$2; shift 2 ;;
    *)
      if [[ "$cmd" == retry && -z "$arg" && "$1" != -* ]]; then arg=$1; shift; continue; fi
      echo "merge-queue.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$cmd" != retry || -n "$arg" ]] || { echo "merge-queue.sh: retry needs an id" >&2; exit 2; }

repo=$(orch_repo "$repo")
qdir="$(orch_state_dir "$repo")/merge-queue"
mkdir -p "$qdir/logs"
queue="$qdir/queue.tsv"
touch "$queue"

outcome_of() { [[ -f "$qdir/$1.outcome" ]] && head -1 "$qdir/$1.outcome" || true; }
set_outcome() { printf '%s\n%s\n' "$2" "${3:-}" >"$qdir/$1.outcome"; echo "$1: $2${3:+ ($3)}"; }

# unmet_deps REQUIRES -> the ids in the list whose outcome is not `merged`.
unmet_deps() {
  local dep missing=() deps
  [[ "$1" == "-" || -z "$1" ]] && return 0
  IFS=, read -r -a deps <<<"$1"
  for dep in "${deps[@]}"; do
    [[ "$(outcome_of "$dep")" == merged ]] || missing+=("$dep")
  done
  ((${#missing[@]})) && (IFS=,; echo "${missing[*]}")
  return 0
}

case "$cmd" in
  add)
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ && -n "$worktree" && -n "$branch" && -n "$title" && -n "$body" ]] ||
      { sed -n '2,39p' "$0" >&2; exit 2; }
    if cut -f1 "$queue" | grep -Fxq -- "$id"; then
      echo "refused: id '$id' is already queued; ids are never reused" >&2; exit 3
    fi
    if [[ "$requires" == auto ]]; then
      p=$(parent_branch "$branch")
      requires=$(awk -F'\t' -v p="$p" '$3 == p {print $1; exit}' "$queue")
      [[ -n "$p" && -n "$requires" ]] || { echo "refused: no queued parent for $branch" >&2; exit 3; }
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$worktree" "$branch" "$title" "$body" "$requires" >>"$queue"
    echo "queued $id (requires $requires)"
    ;;
  status)
    while IFS=$'\t' read -r qid _ qbranch _ _ qreq; do
      out=$(outcome_of "$qid")
      if [[ -z "$out" ]]; then
        miss=$(unmet_deps "$qreq")
        out=${miss:+blocked:$miss}; out=${out:-pending}
      fi
      printf '%s\t%s\t%s\n' "$qid" "$out" "$qbranch"
    done <"$queue"
    ;;
  retry)
    out=$(outcome_of "$arg")
    case "$out" in
      merged) echo "refused: $arg is already merged" >&2; exit 3 ;;
      "") echo "$arg has no outcome; nothing to retry" ;;
      *) rm -f "$qdir/$arg.outcome"; echo "$arg re-armed (was $out)" ;;
    esac
    ;;
  run-once)
    base=$(orch_default_branch "$repo")
    if [[ "${ORCHESTRATE_DIRECT_MERGE:-0}" != 1 ]]; then
      # Fresh main evidence for this pass; red writes the hold, unknown leaves it as it was.
      read -r -a mh_args <<<"${MERGE_QUEUE_MAIN_HEALTH_ARGS:-}"
      mh=$("$here/main-health.sh" --repo "$repo" --branch "$base" ${mh_args[@]+"${mh_args[@]}"} 2>&1) || true
      echo "main: $mh"
    fi
    while IFS=$'\t' read -r -u 3 qid qwt qbranch qtitle qbody qreq; do
      prev=$(outcome_of "$qid")
      [[ -z "$prev" || "$prev" == waiting ]] || continue
      miss=$(unmet_deps "$qreq")
      if [[ -n "$miss" ]]; then echo "$qid: blocked on $miss"; continue; fi
      log="$qdir/logs/$qid.log"
      [[ "$prev" == waiting ]] || : >"$log"
      if [[ -n "$(git -C "$qwt" status --porcelain)" ]] ||
        [[ "$(git -C "$qwt" branch --show-current)" != "$qbranch" ]]; then
        set_outcome "$qid" error "worktree dirty or not on $qbranch"; continue
      fi
      # The PR this item already has, if any, is inspected first (merged included), so a pass after
      # a lost response or a retry never pushes, opens or merges a second time.
      if [[ -f "$qdir/$qid.pr" ]]; then
        known=$(cat "$qdir/$qid.pr")
        if ! kstate=$(orch_read_retry 3 gh pr view "$known" --repo "$repo" --json state | jq -re .state); then
          set_outcome "$qid" waiting "PR $known unreadable (transient); will re-check"; continue
        fi
        if [[ "$kstate" == MERGED ]]; then set_outcome "$qid" merged "PR $known (confirmed on re-check)"; continue; fi
      fi
      git -C "$qwt" fetch -q origin >>"$log" 2>&1 || { set_outcome "$qid" error "fetch failed, see $log"; continue; }
      # Resuming a waiting item: the base merge, check and push are already done when the pushed
      # head still contains the current base and nothing moved since.
      local_head=$(git -C "$qwt" rev-parse HEAD)
      if [[ "$prev" == waiting && "$(cat "$qdir/$qid.pushed" 2>/dev/null)" == "$local_head" ]] &&
        [[ "$(git -C "$qwt" rev-parse -q --verify "origin/$qbranch" || true)" == "$local_head" ]] &&
        git -C "$qwt" merge-base --is-ancestor "origin/$base" HEAD; then
        echo "$qid: resuming at ${local_head:0:9}" >>"$log"
      else
        if ! git -C "$qwt" merge --no-edit "origin/$base" >>"$log" 2>&1; then
          git -C "$qwt" merge --abort >>"$log" 2>&1 || true
          set_outcome "$qid" conflict "see $log"; continue
        fi
        if [[ -n "${MERGE_QUEUE_CHECK_CMD:-}" ]] &&
          ! (cd "$qwt" && bash -c "$MERGE_QUEUE_CHECK_CMD") >>"$log" 2>&1; then
          set_outcome "$qid" checkfail "see $log"; continue
        fi
        git -C "$qwt" push -q origin "$qbranch" >>"$log" 2>&1 || { set_outcome "$qid" error "push rejected, see $log"; continue; }
        local_head=$(git -C "$qwt" rev-parse HEAD)
        printf '%s\n' "$local_head" >"$qdir/$qid.pushed"
      fi
      list_open() { orch_read_retry 3 gh pr list --repo "$repo" --head "$qbranch" --state open --json number,headRefOid; }
      if ! prs=$(list_open); then set_outcome "$qid" waiting "PR lookup failed (transient)"; continue; fi
      if [[ "$(jq length <<<"$prs")" == 0 ]]; then
        # Already merged at this exact head (an earlier pass lost the answer)? Then it is done.
        if ! merged=$(orch_read_retry 3 gh pr list --repo "$repo" --head "$qbranch" --state merged --json number,headRefOid); then
          set_outcome "$qid" waiting "PR lookup failed (transient)"; continue
        fi
        mpr=$(jq -r --arg h "$local_head" '[.[] | select(.headRefOid == $h)][0].number // empty' <<<"$merged")
        if [[ -n "$mpr" ]]; then
          printf '%s\n' "$mpr" >"$qdir/$qid.pr"
          set_outcome "$qid" merged "PR $mpr (already merged at ${local_head:0:9})"; continue
        fi
        # A create whose response was lost may still have opened the PR: look before reporting.
        gh pr create --repo "$repo" --head "$qbranch" --base "$base" --title "$qtitle" --body-file "$qbody" >>"$log" 2>&1 ||
          echo "pr create failed; checking whether it was created anyway" >>"$log"
        if ! prs=$(list_open); then set_outcome "$qid" waiting "PR lookup after create failed (transient)"; continue; fi
        [[ "$(jq length <<<"$prs")" != 0 ]] || { set_outcome "$qid" error "pr create failed, see $log"; continue; }
      fi
      pr=$(jq -r '.[0].number // empty' <<<"$prs")
      [[ -z "$pr" ]] || printf '%s\n' "$pr" >"$qdir/$qid.pr"
      head=$(jq -r '.[0].headRefOid // empty' <<<"$prs")
      [[ -n "$pr" && -n "$head" ]] || { set_outcome "$qid" error "no open PR for $qbranch"; continue; }
      if [[ "$head" != "$local_head" ]]; then
        set_outcome "$qid" waiting "PR $pr shows head ${head:0:9}, pushed ${local_head:0:9}"; continue
      fi
      margs=(--repo "$repo" --pr "$pr" --head "$head")
      if [[ "${ORCHESTRATE_DIRECT_MERGE:-0}" != 1 ]]; then
        row=$("$here/pr-ready.sh" --repo "$repo" --base "$base" --pr "$pr" 2>>"$log" | head -1) || row=""
        IFS=$'\t' read -r _ verdict rhead _ _ detail <<<"$row"
        if [[ -z "$row" ]]; then set_outcome "$qid" error "no readiness row for PR $pr"; continue; fi
        if [[ "$head" != "$rhead"* ]]; then set_outcome "$qid" waiting "readiness row is for $rhead"; continue; fi
        # Not there yet (pending, unreported, unknown mergeability) is waiting; anything else blocks.
        others=""; fails=""
        for token in $detail; do
          case "$token" in
            pending:* | few-checks=0 | mergeable=UNKNOWN | -) ;;
            fail:*) fails+=",${token#fail:}" ;;
            *) others+=" $token" ;;
          esac
        done
        case "$verdict" in
          READY) ;;
          WAIT) set_outcome "$qid" waiting "PR $pr: $detail"; continue ;;
          BLOCK)
            if [[ -z "$others" && -z "$fails" ]]; then set_outcome "$qid" waiting "PR $pr: $detail"; continue; fi
            if [[ -z "$others" && -n "${MERGE_QUEUE_ADMIN_EVIDENCE:-}" && -n "${MERGE_QUEUE_ADMIN_CHECKS:-}" ]]; then
              margs+=(--admin --evidence "$MERGE_QUEUE_ADMIN_EVIDENCE")
              IFS=, read -r -a admin_checks <<<"$MERGE_QUEUE_ADMIN_CHECKS"
              for c in "${admin_checks[@]}"; do margs+=(--except-check "$c"); done
            else
              set_outcome "$qid" blocked "PR $pr: $detail"; continue
            fi ;;
          *) set_outcome "$qid" blocked "PR $pr: $verdict $detail"; continue ;;
        esac
      fi
      rc=0
      "$here/pr-merge.sh" "${margs[@]}" >>"$log" 2>&1 || rc=$?
      case "$rc" in
        0) set_outcome "$qid" merged "PR $pr" ;;
        4) echo "hold: default branch is red; pass stopped"; exit 4 ;;
        6) set_outcome "$qid" blocked "admin merge refused, see $log" ;;
        7) set_outcome "$qid" waiting "pr-merge found it not ready, see $log" ;;
        8) set_outcome "$qid" waiting "merge queued on GitHub; will confirm" ;;
        9) set_outcome "$qid" waiting "merge outcome unknown; will reconcile" ;;
        *) set_outcome "$qid" error "pr-merge exit $rc, see $log" ;;
      esac
    done 3<"$queue"
    ;;
esac
