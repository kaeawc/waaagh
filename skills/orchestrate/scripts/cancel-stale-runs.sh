#!/usr/bin/env bash
# Stale CI runs (#413): queued or running pull-request runs for a head no open PR points at any
# more (a superseded push, a closed or merged PR). On a busy repository they hold runners that
# current heads wait for. A dry run unless --apply.
#
# Usage: cancel-stale-runs.sh [--repo OWNER/REPO] [--limit N] [--apply]
#   --limit  read at most N unfinished runs per status (default 100, at most 100: one page)
#   --apply  cancel them (gh run cancel), one at a time
# Stale: a run whose event is pull_request or pull_request_target, whose status is queued,
# in_progress, waiting, pending or requested, and whose (head branch, head SHA) is not the head of
# an open PR. Every other run is kept: push, schedule and workflow_dispatch runs (main included),
# every run at an open PR's current head (all pages of open PRs, read after the runs so a head
# pushed meanwhile counts), and a run that started when or after its PR closed (a workflow on
# `pull_request: types: [closed]`; the last 100 closed PRs are read).
# Output: `would cancel|cancelled|cancel failed <run id> <workflow> <branch> <sha>`, then
#   `stale=<n> kept=<n> cancelled=<n> failed=<n>`
# Exit: 0 | 2 usage | 3 the open PRs or the runs could not be read (nothing cancelled)
# (A run list shorter than the real one only leaves some stale runs for the next pass.)
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority low

repo="" limit=100 apply=no
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --limit) limit=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --apply) apply=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "cancel-stale-runs.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$limit" =~ ^[1-9][0-9]*$ ]] && ((limit <= 100)) || { echo "cancel-stale-runs.sh: --limit needs a number from 1 to 100" >&2; exit 2; }
repo=$(orch_repo "$repo")
ghr() { "$here/gh-read.sh" --tries 3 -- "$@"; }

# Runs first, heads after: a head pushed between the two reads is then in the heads, so its new
# runs are never taken for stale ones.
runs=""
for st in queued in_progress waiting pending requested; do
  # actions/runs directly: `gh run list` makes hidden extra requests per run (gh-budget.bats).
  got=$(ghr api "repos/$repo/actions/runs?status=$st&per_page=$limit" \
    --jq '.workflow_runs[] | "\(.id)\t\(.event)\t\(.head_branch)\t\(.head_sha)\t\(.name)\t\(.created_at)"') ||
    { echo "cancel-stale-runs.sh: the $st runs of $repo could not be read; nothing cancelled" >&2; exit 3; }
  [[ -z "$got" ]] || runs+="$got"$'\n'
done
# Every open PR's head (all pages), and the heads of recently closed PRs with when they closed: a
# workflow on `pull_request: types: [closed]` runs after its PR closes and is not stale.
heads=$(ghr api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq '.[] | "\(.head.ref) \(.head.sha)"') ||
  { echo "cancel-stale-runs.sh: the open PRs of $repo could not be read; nothing cancelled" >&2; exit 3; }
closed=$(ghr api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
  --jq '.[] | select(.closed_at != null) | "\(.head.ref) \(.head.sha)\t\(.closed_at)"') ||
  { echo "cancel-stale-runs.sh: the closed PRs of $repo could not be read; nothing cancelled" >&2; exit 3; }

stale=0 kept=0 cancelled=0 failed=0
while IFS=$'\t' read -r id event branch sha wf created; do
  [[ -n "$id" ]] || continue
  if [[ "$event" != pull_request && "$event" != pull_request_target ]] || grep -qxF -- "$branch $sha" <<<"$heads"; then
    kept=$((kept + 1)); continue
  fi
  # Started when or after its PR closed (ISO times compare as text): a run for the close itself.
  closed_at=$(awk -F'\t' -v h="$branch $sha" '$1 == h { print $2; exit }' <<<"$closed")
  if [[ -n "$closed_at" && ! "$created" < "$closed_at" ]]; then kept=$((kept + 1)); continue; fi
  stale=$((stale + 1))
  if [[ "$apply" != yes ]]; then echo "would cancel $id $wf $branch ${sha:0:9}"; continue; fi
  if gh run cancel "$id" --repo "$repo" >/dev/null 2>&1; then echo "cancelled $id $wf $branch ${sha:0:9}"; cancelled=$((cancelled + 1))
  else echo "cancel failed $id $wf $branch ${sha:0:9}"; failed=$((failed + 1)); fi
done < <(printf '%s' "$runs" | sort -u)
echo "stale=$stale kept=$kept cancelled=$cancelled failed=$failed"
