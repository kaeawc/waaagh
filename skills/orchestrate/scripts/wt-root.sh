#!/usr/bin/env bash
# The canonical lane worktree root (#394), and moving existing worktrees under it. Spotlight indexes
# no directory whose name ends in .noindex (nor anything below one), so worktrees there do not feed
# mds, mdworker and fseventsd.
#
# Usage: wt-root.sh path [NAME]               print the root for this repository, or root/NAME
#        wt-root.sh migrate [--apply]         move each idle linked worktree outside the root into it
#        wt-root.sh migrate --dir DIR [--apply]   turn a whole directory of worktrees into DIR.noindex
#   [--repo-dir DIR] before or after the command: the repository (default the working directory).
#   Root: ORCHESTRATE_WORKTREE_ROOT, else <WAAAGH_WORKTREE_HOME, default ~/worktrees.noindex>/<repo>,
#   <repo> being the main checkout's directory name (orch_worktree_home in _lib.sh).
#   Create a lane worktree there: git worktree add "$(wt-root.sh path <lane>)" -b <branch>
#   (or jj workspace add "$(wt-root.sh path <lane>)"); worktree-guard.sh refuses other paths.
#   migrate: a dry run unless --apply. Per tree: `git worktree move <tree> <root>/<its name>`. Kept
#   (and said why): the main worktree, a locked or missing tree, one already under a .noindex
#   directory, one any process works in (spectra owner --under, proc_cwds in _lib.sh; when spectra
#   cannot answer nothing moves), and a name already taken in the root. git refuses a tree with
#   submodules; that is reported as kept too.
#   migrate --dir DIR: for a directory that holds many trees (a .claude/worktrees, a ../lanes dir):
#   `mv DIR DIR.noindex && ln -s DIR.noindex DIR`, then `git worktree repair` of every tree that was
#   under it, so old paths keep working through the link. Refused when DIR is already a link or
#   .noindex, DIR.noindex exists, or a process works inside DIR. A missing DIR is created as the
#   link pair, so worktrees made there later (Claude Code's `isolation: worktree` uses
#   <repo>/.claude/worktrees) land in DIR.noindex.
# Output (TSV): verdict  path  detail      verdict: root | move | moved | keep | link | linked
# Exit: 0 | 1 a move or link failed | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac

cmd="" name="" apply=no dir="" repo_dir=.
while (($#)); do
  case "$1" in
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    --apply) apply=yes; shift ;;
    --dir) [[ -n "${2:-}" ]] || { echo "wt-root.sh: --dir needs a directory" >&2; exit 2; }; dir=$2; shift 2 ;;
    --repo-dir) [[ -n "${2:-}" ]] || { echo "wt-root.sh: --repo-dir needs a directory" >&2; exit 2; }; repo_dir=$2; shift 2 ;;
    path | migrate) [[ -z "$cmd" ]] || { echo "wt-root.sh: one command at a time" >&2; exit 2; }; cmd=$1; shift ;;
    -*) echo "wt-root.sh: unknown argument: $1" >&2; exit 2 ;;
    *) [[ "$cmd" == path && -z "$name" ]] || { echo "wt-root.sh: unexpected argument: $1" >&2; exit 2; }
      name=$1; shift ;;
  esac
done
[[ -n "$cmd" ]] || { echo "wt-root.sh: usage: wt-root.sh path [NAME] | migrate [--dir DIR] [--apply]" >&2; exit 2; }
[[ "$cmd" == migrate || ( "$apply" == no && -z "$dir" ) ]] || { echo "wt-root.sh: --apply and --dir go with migrate" >&2; exit 2; }
case "$name" in */* | . | ..) echo "wt-root.sh: NAME is one path part" >&2; exit 2 ;; esac

# shellcheck source=_lib.sh
source "$here/_lib.sh"
root=$(orch_worktree_home "$repo_dir") || {
  if [[ -z "${ORCHESTRATE_WORKTREE_ROOT:-}${WAAAGH_WORKTREE_HOME:-}${HOME:-}" ]]; then
    echo "wt-root.sh: HOME is not set: set WAAAGH_WORKTREE_HOME or ORCHESTRATE_WORKTREE_ROOT" >&2
  else
    echo "wt-root.sh: not in a git checkout: $repo_dir (or set ORCHESTRATE_WORKTREE_ROOT)" >&2
  fi
  exit 2
}

if [[ "$cmd" == path ]]; then
  printf '%s\n' "$root${name:+/$name}"
  exit 0
fi

# inside LIST DIR: some process's cwd is DIR or below it.
inside() { printf '%s\n' "$1" | awk -v d="$2" '$0 == d || index($0, d "/") == 1 { f = 1 } END { exit !f }'; }
# noindexed PATH: some part of PATH ends in .noindex.
noindexed() { case "/$1/" in */*.noindex/*) return 0 ;; esac; return 1; }
main=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)
main=$(cd "$main/.." && pwd -P)
failed=0

if [[ -n "$dir" ]]; then
  dir=${dir%/}
  [[ "$dir" == /* ]] || dir=$PWD/$dir
  if [[ -L "$dir" ]]; then printf 'keep\t%s\talready a link (to %s)\n' "$dir" "$(readlink "$dir")"; exit 0; fi
  if noindexed "$dir"; then printf 'keep\t%s\talready under a .noindex directory\n' "$dir"; exit 0; fi
  if [[ -e "$dir.noindex" ]]; then printf 'keep\t%s\t%s.noindex exists: move its trees by hand\n' "$dir" "$dir"; exit 0; fi
  trees=()
  if [[ -d "$dir" ]]; then
    real=$(cd "$dir" && pwd -P)
    cwds=$(proc_cwds "$real" | cut -f2-) || { printf 'keep\t%s\tcannot check processes: spectra owner --under failed\n' "$dir"; exit 0; }
    if inside "$cwds" "$real"; then printf 'keep\t%s\ta process is working inside it\n' "$dir"; exit 0; fi
    while IFS= read -r p; do
      case "$p/" in "$real"/* | "$dir"/*) trees+=("$p") ;; esac
    done < <(git -C "$repo_dir" worktree list --porcelain | awk '/^worktree / { print substr($0, 10) }')
  fi
  if [[ "$apply" != yes ]]; then
    printf 'link\t%s\tmv to %s.noindex, then link %s -> %s.noindex and repair %s worktree(s) (dry run: --apply does it)\n' \
      "$dir" "$dir" "${dir##*/}" "${dir##*/}" "${#trees[@]}"
    exit 0
  fi
  if [[ -d "$dir" ]]; then
    mv "$dir" "$dir.noindex" || { printf 'keep\t%s\tmv failed\n' "$dir"; exit 1; }
  else
    mkdir -p "$dir.noindex"
  fi
  ln -s "${dir##*/}.noindex" "$dir" || { printf 'keep\t%s\tln failed (the trees are in %s.noindex)\n' "$dir" "$dir"; exit 1; }
  moved=()
  for p in ${trees[@]+"${trees[@]}"}; do moved+=("$dir.noindex${p#"$dir"}"); done
  ((${#moved[@]} == 0)) || git -C "$main" worktree repair "${moved[@]}" >/dev/null 2>&1 || failed=1
  printf 'linked\t%s\t-> %s.noindex, %s worktree(s) repaired\n' "$dir" "${dir##*/}" "${#moved[@]}"
  exit "$failed"
fi

wt_dirs=()
while IFS= read -r p; do wt_dirs+=("$p"); done < <(git -C "$repo_dir" worktree list --porcelain | awk '/^worktree / { print substr($0, 10) }')
can_check=yes
cwds=$(proc_cwds "${wt_dirs[@]}" | cut -f2-) || can_check=no
printf 'root\t%s\t%s\n' "$root" "$([[ -d "$root" ]] && echo exists || echo "created by the first move")"
while IFS=$'\t' read -r path locked; do
  keep() { printf 'keep\t%s\t%s\n' "$path" "$1"; }
  real=$(cd "$path" 2>/dev/null && pwd -P) || { keep "missing (git worktree prune handles it)"; continue; }
  [[ "$real" != "$main" ]] || { keep "main worktree"; continue; }
  [[ "$locked" == no ]] || { keep locked; continue; }
  if noindexed "$real"; then keep "already under a .noindex directory"; continue; fi
  [[ "$can_check" == yes ]] || { keep "cannot check processes: spectra owner --under failed"; continue; }
  if inside "$cwds" "$real"; then keep "a process is working inside it"; continue; fi
  dest="$root/${real##*/}"
  [[ ! -e "$dest" ]] || { keep "$dest exists"; continue; }
  if [[ "$apply" != yes ]]; then printf 'move\t%s\t-> %s (dry run: --apply moves it)\n' "$path" "$dest"; continue; fi
  # Read again right before moving: a session may have entered it since the first listing.
  fresh=$(proc_cwds "$real" | cut -f2-) || { keep "cannot check processes: spectra owner --under failed"; continue; }
  if inside "$fresh" "$real"; then keep "a process is working inside it"; continue; fi
  mkdir -p "$root"
  if out=$(git -C "$main" worktree move "$real" "$dest" 2>&1); then
    printf 'moved\t%s\t-> %s\n' "$path" "$dest"
  else
    keep "git refused: ${out:0:200}"; failed=1
  fi
done < <(git -C "$repo_dir" worktree list --porcelain | awk '
  /^worktree / { if (p != "") print p "\t" l; p = substr($0, 10); l = "no" }
  /^locked/ { l = "yes" }
  END { if (p != "") print p "\t" l }')
exit "$failed"
