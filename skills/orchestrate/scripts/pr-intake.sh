#!/usr/bin/env bash
# List the user's own open PRs and classify whether this orchestrator may take them over.
# Only one author is ever listed: the authenticated gh user (or --author / ORCHESTRATE_AUTHOR).
# PRs from anyone else are never adopted.
#
# Usage: pr-intake.sh [--repo OWNER/REPO] [--author LOGIN] [--owner ID] [--ttl SECONDS]
#                     [--quiet-minutes N] [--include-drafts]
# Output (TSV): number  status  head_ref  updated_at  url
#   status: eligible | mine | claimed:<owner> | busy-local:<path> | recent-activity | draft | fork
# Only `eligible` (or `mine`) PRs may be claimed. Env: ORCHESTRATE_NOW (tests only).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
AUTHOR="" repo="" ttl=1800 quiet=20 include_drafts=no
owner_args=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --author) AUTHOR=$2; shift 2 ;;
    --owner) owner_args=(--owner "$2"); shift 2 ;;
    --ttl) ttl=$2; shift 2 ;;
    --quiet-minutes) quiet=$2; shift 2 ;;
    --include-drafts) include_drafts=yes; shift ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "pr-intake.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")
[[ -n "$AUTHOR" ]] || AUTHOR=$(orch_author)

now=${ORCHESTRATE_NOW:-$(date +%s)}

# branch -> worktree path, for local worktrees with uncommitted changes (someone is mid-edit).
dirty_worktrees=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  wt=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt=${line#worktree } ;;
      "branch refs/heads/"*)
        b=${line#branch refs/heads/}
        if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
          dirty_worktrees+="$b"$'\t'"$wt"$'\n'
        fi
        ;;
    esac
  done < <(git worktree list --porcelain)
fi

gh pr list --repo "$repo" --author "$AUTHOR" --state open --limit 200 \
  --json number,author,isDraft,isCrossRepository,headRefName,updatedAt,url |
  jq -r --arg a "$AUTHOR" '.[] | select(.author.login == $a)
    | [.number, .isDraft, .isCrossRepository, .headRefName, .updatedAt, .url] | @tsv' |
  while IFS=$'\t' read -r num draft cross head updated url; do
    claim=$("$here/pr-claim.sh" status --repo "$repo" --pr "$num" --ttl "$ttl" ${owner_args[@]+"${owner_args[@]}"})
    busy=$(printf '%s' "$dirty_worktrees" | awk -F'\t' -v b="$head" '$1 == b { print $2; exit }')
    updated_epoch=$(jq -rn --arg t "$updated" '$t | fromdateiso8601')
    if [[ "$cross" == true ]]; then status=fork
    elif [[ "$claim" == *"mine=yes"* ]]; then status=mine
    elif [[ "$claim" == *"fresh=yes"* ]]; then
      status="claimed:$(sed -E 's/.*owner=(.*) age=.*/\1/' <<<"$claim")"
    elif [[ -n "$busy" ]]; then status="busy-local:$busy"
    elif [[ "$draft" == true && "$include_drafts" == no ]]; then status=draft
    elif ((now - updated_epoch < quiet * 60)); then status=recent-activity
    else status=eligible
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$status" "$head" "$updated" "$url"
  done
