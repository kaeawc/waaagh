#!/usr/bin/env bash
# Serial local merge queue: bring each queued branch up to date with the default branch, run a
# check command, then push, open a PR if needed and merge it through pr-merge.sh. One pass per
# `run-once`; there is no daemon and no sleep loop, so no role polls.
#
# Usage: merge-queue.sh <add|run-once|status|retry|parent> [--repo OWNER/REPO] [options]
#   add       --id ID --worktree DIR --branch B --title T --body-file F [--requires ID,ID|-|auto]
#             Appends a row to <state dir>/merge-queue/queue.tsv. A duplicate id is refused.
#             `--requires auto` depends on the queued item whose branch is `parent B`.
#   run-once  Process eligible items in file order, serially, until the pass ends. An item runs
#             only when it has no outcome and every id in `requires` has outcome `merged`.
#   status    One line per item: id, outcome (or `pending` / `blocked:<ids>`), branch.
#   retry ID  Clear a non-merged outcome so the next run-once picks the item up again.
#   parent B  Print the branch B stacks on: `name-3` -> `name-2`, `name-2` -> `name`, else nothing.
# Outcomes in <state dir>/merge-queue/<id>.outcome: merged | conflict | checkfail | error.
# Only `merged` is done and only `merged` satisfies a dependent; any other outcome parks the item
# until `retry`. Logs of the check and of errors are under <state dir>/merge-queue/logs/.
# Env: MERGE_QUEUE_CHECK_CMD   run in the worktree after the base merge (unset: no check; a
#                              direct-merge campaign should still set a cheap structural gate)
#      MERGE_QUEUE_ADMIN_EVIDENCE  when set, merge with --admin --evidence <text>; pr-merge.sh
#                              still enforces the fast-path and authorization rules
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
  *) sed -n '2,24p' "$0" >&2; exit 2 ;;
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

outcome_of() { [[ -f "$qdir/$1.outcome" ]] && cat "$qdir/$1.outcome" || true; }
set_outcome() { printf '%s\n' "$2" >"$qdir/$1.outcome"; echo "$1: $2${3:+ ($3)}"; }

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
      { sed -n '2,24p' "$0" >&2; exit 2; }
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
    while IFS=$'\t' read -r -u 3 qid qwt qbranch qtitle qbody qreq; do
      [[ -z "$(outcome_of "$qid")" ]] || continue
      miss=$(unmet_deps "$qreq")
      if [[ -n "$miss" ]]; then echo "$qid: blocked on $miss"; continue; fi
      log="$qdir/logs/$qid.log"
      : >"$log"
      if [[ -n "$(git -C "$qwt" status --porcelain)" ]] ||
        [[ "$(git -C "$qwt" branch --show-current)" != "$qbranch" ]]; then
        set_outcome "$qid" error "worktree dirty or not on $qbranch"; continue
      fi
      git -C "$qwt" fetch -q origin >>"$log" 2>&1 || { set_outcome "$qid" error "fetch failed, see $log"; continue; }
      if ! git -C "$qwt" merge --no-edit "origin/$base" >>"$log" 2>&1; then
        git -C "$qwt" merge --abort >>"$log" 2>&1 || true
        set_outcome "$qid" conflict "see $log"; continue
      fi
      if [[ -n "${MERGE_QUEUE_CHECK_CMD:-}" ]] &&
        ! (cd "$qwt" && bash -c "$MERGE_QUEUE_CHECK_CMD") >>"$log" 2>&1; then
        set_outcome "$qid" checkfail "see $log"; continue
      fi
      git -C "$qwt" push -q origin "$qbranch" >>"$log" 2>&1 || { set_outcome "$qid" error "push rejected, see $log"; continue; }
      prs=$(gh pr list --repo "$repo" --head "$qbranch" --state open --json number,headRefOid)
      if [[ "$(jq length <<<"$prs")" == 0 ]]; then
        gh pr create --repo "$repo" --head "$qbranch" --base "$base" --title "$qtitle" --body-file "$qbody" >>"$log" 2>&1 ||
          { set_outcome "$qid" error "pr create failed, see $log"; continue; }
        prs=$(gh pr list --repo "$repo" --head "$qbranch" --state open --json number,headRefOid)
      fi
      pr=$(jq -r '.[0].number // empty' <<<"$prs")
      head=$(jq -r '.[0].headRefOid // empty' <<<"$prs")
      [[ -n "$pr" && -n "$head" ]] || { set_outcome "$qid" error "no open PR for $qbranch"; continue; }
      margs=(--repo "$repo" --pr "$pr" --head "$head")
      [[ -z "${MERGE_QUEUE_ADMIN_EVIDENCE:-}" ]] || margs+=(--admin --evidence "$MERGE_QUEUE_ADMIN_EVIDENCE")
      rc=0
      "$here/pr-merge.sh" "${margs[@]}" >>"$log" 2>&1 || rc=$?
      case "$rc" in
        0) set_outcome "$qid" merged "PR $pr" ;;
        4) echo "hold: default branch is red; pass stopped"; exit 4 ;;
        *) set_outcome "$qid" error "pr-merge exit $rc, see $log" ;;
      esac
    done 3<"$queue"
    ;;
esac
