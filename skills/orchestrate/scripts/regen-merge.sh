#!/usr/bin/env bash
# Merge the base branch into a worktree's branch, resolving conflicts in GENERATED files by taking
# the base's copy and regenerating, then proving the regeneration is stable. Any other conflict
# aborts the merge (it needs a conflict lane). Never rewrites history, never pushes.
#
# Usage: regen-merge.sh --worktree DIR [--base BRANCH] [--spec FILE] [--no-commit]
#   --base   the branch to merge from origin (default: origin's HEAD branch, else main)
#   --spec   generated-file spec, one "<glob><TAB><regenerate command>" per line ("#" comments),
#            e.g. "gen/**<TAB>make codegen". Default $ORCHESTRATE_GENERATED_FILES, else
#            <state dir>/<owner>__<repo>/generated-files.tsv for this checkout's origin. No spec:
#            a plain merge that aborts on any conflict.
# Steps: fetch; merge origin/BASE. On conflict: every conflicted path must match a spec glob,
#   else abort (exit 3). Take the base's side of each, run each matching regenerate command once
#   (in the worktree), stage the generated paths it changed, then run them again: the second run
#   must change nothing (exit 5 otherwise, merge aborted). A regenerate command that touches a
#   path outside the spec also aborts (exit 5). Then commit the merge (unless --no-commit).
# Output: "up-to-date" | "merged clean" | "merged, regenerated: <globs>" | "conflict: <paths>" |
#   "unstable: <why>"
# Exit: 0 merged or up to date | 3 conflict outside generated files | 5 regeneration not stable or
#   out of bounds | 2 usage / not a clean worktree
set -euo pipefail

wt="" base="" spec=${ORCHESTRATE_GENERATED_FILES:-} commit=yes
while (($#)); do
  case "$1" in
    --worktree) wt=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --spec) spec=$2; shift 2 ;;
    --no-commit) commit=no; shift ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "regen-merge.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$wt" ]] || { sed -n '2,23p' "$0" >&2; exit 2; }
g() { git -C "$wt" "$@"; }
[[ -z "$(g status --porcelain)" ]] || { echo "regen-merge.sh: worktree $wt is not clean" >&2; exit 2; }

if [[ -z "$spec" ]] && url=$(g remote get-url origin 2>/dev/null); then
  slug=$(sed -E 's#^.*github\.com[:/]##; s#\.git$##' <<<"$url")
  [[ "$slug" == */* ]] && spec="${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/${slug//\//__}/generated-files.tsv"
fi
[[ -z "$spec" || -f "$spec" ]] || spec=""
g fetch -q origin
if [[ -z "$base" ]]; then
  base=$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  base=${base#origin/}
fi

before=$(g rev-parse HEAD)
if g merge --no-edit --no-commit "origin/$base" >/dev/null 2>&1; then
  if [[ -z "$(g rev-parse -q --verify MERGE_HEAD || true)" ]]; then
    if [[ "$(g rev-parse HEAD)" == "$before" ]]; then echo "up-to-date"; else echo "merged clean (fast-forward)"; fi
    exit 0
  fi
  if [[ "$commit" == yes ]]; then g commit -q --no-edit; fi
  echo "merged clean"; exit 0
fi

abort() { g merge --abort >/dev/null 2>&1 || true; echo "$1"; exit "$2"; }
# After regeneration ran, also drop what it wrote: the worktree was clean when we started (checked
# above), so returning it to HEAD loses nothing of anyone else's.
abort_regen() { g merge --abort >/dev/null 2>&1 || true; g reset -q --hard; g clean -qfd; echo "$1"; exit 5; }
conflicted=$(g diff --name-only --diff-filter=U)
[[ -n "$conflicted" ]] || abort "conflict: merge failed without conflicted paths" 3
[[ -n "$spec" ]] || abort "conflict: $(tr '\n' ' ' <<<"$conflicted")" 3

# spec_for PATH -> the regenerate command of the first glob matching PATH ("" if none).
globs=() cmds=()
while IFS=$'\t' read -r glob command; do
  [[ -n "$glob" && "$glob" != \#* && -n "${command:-}" ]] || continue
  globs+=("$glob"); cmds+=("$command")
done <"$spec"
matches() { # PATH GLOB ("**" spans directories)
  local re
  re=$(printf '%s' "$2" | sed -e 's/[.+^$(){}|\\]/\\&/g' -e 's/\*\*/@DS@/g' -e 's/\*/[^\/]*/g' -e 's/?/[^\/]/g' -e 's/@DS@/.*/g')
  [[ "$1" =~ ^${re}$ ]]
}
spec_index() { local i; for ((i = 0; i < ${#globs[@]}; i++)); do matches "$1" "${globs[$i]}" && { echo "$i"; return; }; done; echo -1; }

outside=() needed=()
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  i=$(spec_index "$path")
  if ((i < 0)); then outside+=("$path"); else needed+=("$i"); fi
done <<<"$conflicted"
((${#outside[@]} == 0)) || abort "conflict: ${outside[*]}" 3

# Take the base's side (a path the base deleted stays deleted), then regenerate.
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if g cat-file -e "MERGE_HEAD:$path" 2>/dev/null; then
    g checkout --theirs -- "$path" && g add -- "$path"
  else
    g rm -q -- "$path"
  fi
done <<<"$conflicted"
uniq_idx=$(printf '%s\n' "${needed[@]}" | sort -un)
run_regen() {
  local i
  for i in $uniq_idx; do (cd "$wt" && bash -c "${cmds[$i]}") >/dev/null 2>&1 || return 1; done
}
in_spec() { [[ "$(spec_index "$1")" -ge 0 ]]; }

run_regen || abort_regen "unstable: a regenerate command failed"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  in_spec "$path" || abort_regen "unstable: regeneration changed $path, which is not a generated file"
  g add -A -- "$path"
done < <(g diff --name-only; g ls-files --others --exclude-standard)
# Stable: a second run must change nothing.
run_regen || abort_regen "unstable: a regenerate command failed on the second run"
if [[ -n "$(g diff --name-only)$(g ls-files --others --exclude-standard)" ]]; then
  abort_regen "unstable: regenerating twice gives different output ($(g diff --name-only | head -3 | tr '\n' ' '))"
fi
if [[ "$commit" == yes ]]; then g commit -q --no-edit; fi
echo "merged, regenerated: $(for i in $uniq_idx; do printf '%s ' "${globs[$i]}"; done | sed 's/ $//')"
