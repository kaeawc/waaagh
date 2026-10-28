#!/usr/bin/env bash
# Conservative worktree cleanup. Lists every linked worktree of a repository with a verdict and
# removes (with --apply) only those that are certainly finished. Never forces, never kills.
#
# Usage: wt-cleanup.sh [--repo-dir DIR] [--older-than-hours N] [--protect GLOB]... [--apply]
#   removable only when ALL hold: not the main worktree, not locked; clean (no changes, no
#   untracked files); no process has its working directory inside it; untouched for N hours
#   (default 24; index and directory times); HEAD is on a remote branch (nothing unpushed); its
#   branch matches no --protect glob (default main, master, develop, release/*, release-*).
# Output (TSV): verdict  path  reason      verdict: remove | removed | keep
# Removal is `git worktree remove <path>` (no --force); a refusal is reported as keep.
# Without lsof, and without /proc, process checks cannot be made and nothing is removed.
set -euo pipefail

repo_dir=. hours=24 apply=no
protect=()
while (($#)); do
  case "$1" in
    --repo-dir) repo_dir=$2; shift 2 ;;
    --older-than-hours) hours=$2; shift 2 ;;
    --protect) protect+=("$2"); shift 2 ;;
    --apply) apply=yes; shift ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "wt-cleanup.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$hours" =~ ^[0-9]+$ ]] || { echo "wt-cleanup.sh: bad --older-than-hours" >&2; exit 2; }
((${#protect[@]})) || protect=(main master develop 'release/*' 'release-*')
now=${ORCHESTRATE_NOW:-$(date +%s)}

# Working directories of every process we can see, resolved.
cwds=""
if command -v lsof >/dev/null 2>&1; then
  cwds=$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)
  can_check=yes
elif [[ -d /proc/self ]]; then
  cwds=$(for p in /proc/[0-9]*; do readlink "$p/cwd" 2>/dev/null || true; done)
  can_check=yes
else
  can_check=no
fi
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "$now"; }

main=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$repo_dir" rev-parse --git-common-dir)
main=$(cd "$main/.." && pwd -P)

git -C "$repo_dir" worktree list --porcelain | awk '
  /^worktree / { if (p != "") print p "\t" b "\t" l; p = substr($0, 10); b = "-"; l = "no" }
  /^branch / { b = substr($0, 8); sub("^refs/heads/", "", b) }
  /^detached/ { b = "(detached)" }
  /^locked/ { l = "yes" }
  END { if (p != "") print p "\t" b "\t" l }' |
while IFS=$'\t' read -r path branch locked; do
  real=$(cd "$path" 2>/dev/null && pwd -P) || { printf 'keep\t%s\tmissing (git worktree prune handles it)\n' "$path"; continue; }
  keep() { printf 'keep\t%s\t%s\n' "$path" "$1"; }
  [[ "$real" != "$main" ]] || { keep "main worktree"; continue; }
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
  if printf '%s\n' "$cwds" | awk -v d="$real" '$0 == d || index($0, d "/") == 1 { f = 1 } END { exit !f }'; then
    keep "a process is working inside it"; continue
  fi
  ((age >= hours)) || { keep "touched ${age}h ago (< ${hours}h)"; continue; }
  [[ -n "$(git -C "$real" branch -r --contains HEAD 2>/dev/null)" ]] || { keep "HEAD is not on any remote branch (unpushed work)"; continue; }
  if [[ "$apply" == yes ]]; then
    if out=$(git -C "$repo_dir" worktree remove "$real" 2>&1); then
      printf 'removed\t%s\tclean, idle %sh, pushed\n' "$path" "$age"
    else
      keep "git refused: ${out:0:200}"
    fi
  else
    printf 'remove\t%s\tclean, idle %sh, pushed (dry run: --apply removes it)\n' "$path" "$age"
  fi
done
