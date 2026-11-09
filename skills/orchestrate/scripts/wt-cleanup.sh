#!/usr/bin/env bash
# Conservative worktree cleanup. Lists every linked worktree of a repository with a verdict and
# removes (with --apply) only those that are certainly finished. Never forces, never kills.
#
# Usage: wt-cleanup.sh [--repo-dir DIR] [--older-than-hours N] [--protect GLOB]... [--pr-closed]
#                      [--repo OWNER/REPO] [--max-count N] [--max-gb G] [--apply]
#   removable only when ALL hold: not the main worktree, not locked; clean (no changes, no
#   untracked files); no process has its working directory inside it; untouched for N hours
#   (default 24; index and directory times); HEAD is on a remote branch (nothing unpushed); its
#   branch matches no --protect glob (default main, master, develop, release/*, release-*); with
#   --pr-closed, its branch has a PR and every PR for it is merged or closed (one gh read each,
#   only for otherwise-removable trees; --repo defaults to the checkout's repository).
#   --max-count / --max-gb: the worktree budget. After the run, print a budget row with the live
#   linked worktrees (count, and size via du when --max-gb is given) and exit 3 when over it.
# Output (TSV): verdict  path  reason      verdict: remove | removed | keep | budget
# Removal is `git worktree remove <path>` (no --force); a refusal is reported as keep. Process
# working directories are read with lsof, else /proc (proc_cwds in _slots.sh), and read again
# right before each removal; when neither can be read nothing is removed. A session that must keep
# its worktree whatever happens locks it: `git worktree lock --reason "<session>" <path>`.
# Exit: 0 | 3 over the worktree budget | 2 usage
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_slots.sh
source "$here/_slots.sh"

repo_dir=. hours=24 apply=no pr_closed=no repo="" max_count="" max_gb=""
protect=()
while (($#)); do
  case "$1" in
    --repo-dir) repo_dir=$2; shift 2 ;;
    --older-than-hours) hours=$2; shift 2 ;;
    --protect) protect+=("$2"); shift 2 ;;
    --pr-closed) pr_closed=yes; shift ;;
    --repo) repo=$2; shift 2 ;;
    --max-count) max_count=$2; shift 2 ;;
    --max-gb) max_gb=$2; shift 2 ;;
    --apply) apply=yes; shift ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "wt-cleanup.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$hours" =~ ^[0-9]+$ ]] || { echo "wt-cleanup.sh: bad --older-than-hours" >&2; exit 2; }
[[ -z "$max_count" || "$max_count" =~ ^[0-9]+$ ]] || { echo "wt-cleanup.sh: bad --max-count" >&2; exit 2; }
[[ -z "$max_gb" || "$max_gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "wt-cleanup.sh: bad --max-gb" >&2; exit 2; }
((${#protect[@]})) || protect=(main master develop 'release/*' 'release-*')
now=${ORCHESTRATE_NOW:-$(date +%s)}

if [[ "$pr_closed" == yes ]]; then
  # shellcheck source=_lib.sh
  source "$here/_lib.sh"
  if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi
  [[ -n "$repo" ]] || repo=$(cd "$repo_dir" && orch_repo) || { echo "wt-cleanup.sh: cannot tell the repository; pass --repo" >&2; exit 2; }
fi

# Working directories of every process we can see, resolved.
cwds="" can_check=yes
cwds=$(proc_cwds | cut -f2-) || can_check=no
# inside LIST DIR: some process's cwd is DIR or below it.
inside() { printf '%s\n' "$1" | awk -v d="$2" '$0 == d || index($0, d "/") == 1 { f = 1 } END { exit !f }'; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "$now"; }

main=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$repo_dir" rev-parse --git-common-dir)
main=$(cd "$main/.." && pwd -P)

live=0 removable=0
live_paths=()
while IFS=$'\t' read -r path branch locked; do
  real=$(cd "$path" 2>/dev/null && pwd -P) || { printf 'keep\t%s\tmissing (git worktree prune handles it)\n' "$path"; continue; }
  [[ "$real" != "$main" ]] || { printf 'keep\t%s\tmain worktree\n' "$path"; continue; }
  live=$((live + 1))
  live_paths+=("$real")
  keep() { printf 'keep\t%s\t%s\n' "$path" "$1"; }
  [[ "$locked" == no ]] || { keep locked; continue; }
  hit=""
  for g in "${protect[@]}"; do
    # shellcheck disable=SC2053  # glob match intended
    [[ "$branch" == $g ]] && hit=$g
  done
  [[ -z "$hit" ]] || { keep "protected branch $branch"; continue; }
  # Idle time first, before any git call could touch the index; status must not write it either.
  touched=$(mtime "$real")
  idx=$(git -C "$real" rev-parse --path-format=absolute --git-path index 2>/dev/null || true)
  [[ -z "$idx" || ! -e "$idx" ]] || { t=$(mtime "$idx"); ((t > touched)) && touched=$t; }
  age=$(((now - touched) / 3600))
  [[ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$real" status --porcelain --untracked-files=all 2>/dev/null)" ]] || { keep "uncommitted or untracked changes"; continue; }
  [[ "$can_check" == yes ]] || { keep "cannot check processes (no lsof or /proc)"; continue; }
  if inside "$cwds" "$real"; then keep "a process is working inside it"; continue; fi
  ((age >= hours)) || { keep "touched ${age}h ago (< ${hours}h)"; continue; }
  [[ -n "$(git -C "$real" branch -r --contains HEAD 2>/dev/null)" ]] || { keep "HEAD is not on any remote branch (unpushed work)"; continue; }
  if [[ "$pr_closed" == yes ]]; then
    case "$branch" in "(detached)" | -) keep "no branch to match a PR"; continue ;; esac
    states=$("$here/gh-read.sh" --json -- pr list --repo "$repo" --head "$branch" --state all --limit 20 --json state 2>/dev/null |
      jq -r '[.[].state] | join(",")' 2>/dev/null) || { keep "PR state unreadable"; continue; }
    [[ -n "$states" ]] || { keep "no PR for $branch"; continue; }
    [[ ",$states," != *,OPEN,* ]] || { keep "PR still open"; continue; }
  fi
  removable=$((removable + 1))
  if [[ "$apply" == yes ]]; then
    # Read again right before removing: a session may have entered it since the first listing.
    fresh=$(proc_cwds | cut -f2-) || { keep "cannot check processes (no lsof or /proc)"; continue; }
    if inside "$fresh" "$real"; then keep "a process is working inside it"; continue; fi
    if out=$(git -C "$repo_dir" worktree remove "$real" 2>&1); then
      printf 'removed\t%s\tclean, idle %sh, pushed\n' "$path" "$age"
      live=$((live - 1))
      unset 'live_paths[${#live_paths[@]}-1]'
    else
      keep "git refused: ${out:0:200}"
    fi
  else
    printf 'remove\t%s\tclean, idle %sh, pushed (dry run: --apply removes it)\n' "$path" "$age"
  fi
done < <(git -C "$repo_dir" worktree list --porcelain | awk '
  /^worktree / { if (p != "") print p "\t" b "\t" l; p = substr($0, 10); b = "-"; l = "no" }
  /^branch / { b = substr($0, 8); sub("^refs/heads/", "", b) }
  /^detached/ { b = "(detached)" }
  /^locked/ { l = "yes" }
  END { if (p != "") print p "\t" b "\t" l }')

[[ -n "$max_count$max_gb" ]] || exit 0
over="" summary="live $live worktrees${max_count:+ (max $max_count)}"
if [[ -n "$max_count" ]] && ((live > max_count)); then over=count; fi
if [[ -n "$max_gb" ]]; then
  kb=0
  for p in ${live_paths[@]+"${live_paths[@]}"}; do
    k=$(du -sk "$p" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
    if [[ "$k" =~ ^[0-9]+$ ]]; then kb=$((kb + k)); fi
  done
  gb=$(awk -v k="$kb" 'BEGIN { printf "%.1f", k / 1048576 }')
  summary="$summary, $gb GB (max $max_gb)"
  if awk -v a="$gb" -v b="$max_gb" 'BEGIN { exit !(a + 0 > b + 0) }'; then over="${over:+$over and }size"; fi
fi
[[ "$apply" == yes || "$removable" == 0 ]] || summary="$summary; $removable removable with --apply"
if [[ -n "$over" ]]; then
  printf 'budget\t-\tover budget (%s): %s\n' "$over" "$summary"
  exit 3
fi
printf 'budget\t-\twithin budget: %s\n' "$summary"
