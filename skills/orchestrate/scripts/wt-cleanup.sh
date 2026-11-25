#!/usr/bin/env bash
# Conservative worktree cleanup. Lists every linked worktree of a repository with a verdict and
# removes (with --apply) only those that are certainly finished. Never forces, never kills.
#
# Usage: wt-cleanup.sh [--repo-dir DIR] [--older-than-hours N] [--protect GLOB]... [--pr-closed]
#                      [--repo OWNER/REPO] [--default-branch B] [--include-likely]
#                      [--max-count N] [--max-gb G] [--apply]
#   removable only when ALL hold: not the main worktree, not locked; clean (no changes, no
#   untracked files); no process has its working directory inside it; untouched for N hours
#   (default 24; index and directory times); HEAD is on a remote branch (nothing unpushed) and
#   `git ls-remote origin` shows the branch at HEAD or beyond it (a stale tracking ref is not
#   trusted; an unreadable remote keeps the worktree, #262); its
#   branch matches no --protect glob (default main, master, develop, release/*, release-*); with
#   --pr-closed, its branch has a PR and every PR for it is merged or closed (one gh read each,
#   only for otherwise-removable trees; --repo defaults to the checkout's repository).
#   Merged lanes (#393): a tree whose HEAD is on no remote branch (squash- or rebase-merged, its
#   branch deleted) is checked against origin/<default> (--default-branch, else origin/HEAD, else
#   main or master; as last fetched, never fetched here), first proof wins, named in the reason:
#     ancestor  HEAD is an ancestor of origin/<default>
#     cherry    every commit is patch-equivalent to one there (`git cherry` has no +)
#     tree      merging HEAD into origin/<default> changes nothing (`git merge-tree --write-tree`, git 2.38+)
#     squash    the lane's whole diff is patch-equivalent to one commit there (a temporary
#               `git commit-tree` of HEAD's tree on the merge base, then `git cherry`)
#     pr        a merged PR has HEAD as its head (one `commits/<sha>/pulls` read)
#     subject   likely merged: a lane commit's subject is on origin/<default> as "<subject> (#N)",
#               PR N is merged, and no lane commit is newer than that squash commit
#   ancestor..pr are merged: removable as if pushed, and they satisfy --pr-closed. subject is
#   listed as `keep  likely merged: ...` unless --include-likely. pr and subject read GitHub, so
#   they run only when the repository is known (--repo, or --pr-closed / --include-likely, which
#   read it from the checkout), and only for trees that would otherwise be kept as unpushed.
#   --max-count / --max-gb: the worktree budget. After the run, print a budget row with the live
#   linked worktrees (count, and size via du when --max-gb is given) and exit 3 when over it.
#   Lane build dirs (#213, _build_dirs.sh): a lane-private build output dir whose worktree no
#   longer exists (removed here or by hand) is listed as a build row and, with --apply, removed,
#   unless a process is working inside it. Shared per-commit builds (#215, shared-build.sh) that are
#   partial or past the keep / size cap are build rows too. Skipped when processes cannot be read.
# Output (TSV): verdict  path  reason      verdict: remove | removed | keep | build | budget
#   The reason of a remove / removed row ends in "pushed" or in "merged (<proof>): <evidence>";
#   a likely-merged keep starts with "likely merged (subject): ".
# Removal is `git worktree remove <path>` (no --force); a refusal is reported as keep. Which
# processes work inside a tree comes from spectra (`spectra owner --under`, proc_cwds in _lib.sh,
# #331), asked again right before each removal; when spectra cannot answer nothing is removed. A session that must keep
# its worktree whatever happens locks it: `git worktree lock --reason "<session>" <path>`.
# Exit: 0 | 3 over the worktree budget | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_slots.sh
source "$here/_slots.sh"
# shellcheck source=_build_dirs.sh
source "$here/_build_dirs.sh"

repo_dir=. hours=24 apply=no pr_closed=no repo="" max_count="" max_gb="" default="" include_likely=no
protect=()
while (($#)); do
  case "$1" in
    --repo-dir) repo_dir=$2; shift 2 ;;
    --older-than-hours) hours=$2; shift 2 ;;
    --protect) protect+=("$2"); shift 2 ;;
    --pr-closed) pr_closed=yes; shift ;;
    --repo) repo=$2; shift 2 ;;
    --default-branch) default=$2; shift 2 ;;
    --include-likely) include_likely=yes; shift ;;
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

# shellcheck source=_lib.sh
source "$here/_lib.sh"
if [[ "$pr_closed" == yes || "$include_likely" == yes ]]; then
  if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi
  [[ -n "$repo" ]] || repo=$(cd "$repo_dir" && orch_repo) || { echo "wt-cleanup.sh: cannot tell the repository; pass --repo" >&2; exit 2; }
fi

# Working directories of the processes inside any worktree or lane build dir, resolved.
wt_dirs=()
while IFS= read -r p; do wt_dirs+=("$p"); done < <(git -C "$repo_dir" worktree list --porcelain | awk '/^worktree / { print substr($0, 10) }')
cwds="" can_check=yes
cwds=$(proc_cwds "${wt_dirs[@]}" "$(build_root)" | cut -f2-) || can_check=no
# inside LIST DIR: some process's cwd is DIR or below it.
inside() { printf '%s\n' "$1" | awk -v d="$2" '$0 == d || index($0, d "/") == 1 { f = 1 } END { exit !f }'; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "$now"; }

main=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$repo_dir" rev-parse --git-common-dir)
main=$(cd "$main/.." && pwd -P)

# The default branch the merge proofs compare with (#393), as last fetched: origin/<default>.
if [[ -z "$default" ]]; then
  default=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  default=${default#origin/}
fi
if [[ -z "$default" ]]; then
  for b in main master; do
    if git -C "$repo_dir" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1; then default=$b; break; fi
  done
fi
base_ref="" base_name="origin/${default:-<default>}"
if [[ -n "$default" ]] && git -C "$repo_dir" rev-parse -q --verify "refs/remotes/origin/$default^{commit}" >/dev/null 2>&1; then
  base_ref=refs/remotes/origin/$default
fi
# Subjects on the default branch ("<sha> <committer time> <subject>"), read once and only when a
# subject proof needs them.
base_log=""
tab=$'\t' nl=$'\n'
work=$(mktemp -d "${TMPDIR:-/tmp}/wt-cleanup.XXXXXX")
trap 'rm -rf "$work"' EXIT

# merged_proof DIR: whether DIR's HEAD has landed on origin/<default> though it is on no remote
# branch. Prints "merged<TAB>(<proof>): <evidence>" or "likely<TAB>(subject): <evidence>" and
# returns 0; else prints the proofs tried and returns 1. Proofs in the header, cheapest first
# (ancestor is checked by the caller, for every tree).
merged_proof() {
  local d=$1 head out base_tree mb tmp n subj sha ct pr newest
  [[ -n "$base_ref" ]] || { echo "no $base_name to prove a merge against"; return 1; }
  head=$(git -C "$d" rev-parse HEAD 2>/dev/null) || { echo "HEAD unreadable"; return 1; }
  if out=$(git -C "$d" cherry "$base_ref" "$head" 2>/dev/null) && [[ -n "$out" && "$nl$out" != *"$nl+"* ]]; then
    n=$(printf '%s\n' "$out" | grep -c '^-' || true)
    printf 'merged\t(cherry): all %s commits are patch-equivalent to commits on %s\n' "$n" "$base_name"; return 0
  fi
  base_tree=$(git -C "$d" rev-parse "$base_ref^{tree}" 2>/dev/null || true)
  if out=$(git -C "$d" merge-tree --write-tree "$base_ref" "$head" 2>/dev/null) && [[ -n "$base_tree" && "${out%%"$nl"*}" == "$base_tree" ]]; then
    printf 'merged\t(tree): merging HEAD into %s changes nothing\n' "$base_name"; return 0
  fi
  # A temporary commit (no ref points at it; gc drops it) holding the lane's whole diff, as one
  # squash commit would: git-delete-squashed's check. Never signed, whatever the user's config.
  if mb=$(git -C "$d" merge-base "$base_ref" "$head" 2>/dev/null) &&
    tmp=$(GIT_AUTHOR_NAME=wt-cleanup GIT_AUTHOR_EMAIL=wt-cleanup@localhost GIT_COMMITTER_NAME=wt-cleanup \
      GIT_COMMITTER_EMAIL=wt-cleanup@localhost git -C "$d" commit-tree --no-gpg-sign "$head^{tree}" -p "$mb" -m wt-cleanup 2>/dev/null) &&
    out=$(git -C "$d" cherry "$base_ref" "$tmp" 2>/dev/null) && [[ "$out" == -* ]]; then
    printf 'merged\t(squash): the lane'"'"'s whole diff is patch-equivalent to a commit on %s\n' "$base_name"; return 0
  fi
  [[ -n "$repo" ]] || { echo "not merged into $base_name (ancestor, cherry, tree, squash; pass --repo or --pr-closed for the PR proofs)"; return 1; }
  if out=$("$here/gh-read.sh" --json -- api "repos/$repo/commits/$head/pulls" 2>/dev/null) &&
    n=$(jq -r --arg h "$head" '[.[]? | select(.merged_at != null and .head.sha == $h) | .number] | first // empty' <<<"$out" 2>/dev/null) &&
    [[ -n "$n" ]]; then
    printf 'merged\t(pr): PR #%s merged with HEAD as its head\n' "$n"; return 0
  fi
  # Squashed from a later head: a lane subject landed as "<subject> (#N)". Likely, not proven: the
  # lane may hold work the squash left out, so only commits no newer than the squash commit count.
  if [[ -z "$base_log" ]]; then
    git -C "$repo_dir" log -n 5000 --format='%H %ct %s' "$base_ref" >"$work/base-log" 2>/dev/null || true
    base_log=$work/base-log
  fi
  newest=$(git -C "$d" log -n 200 --format=%ct "$base_ref..$head" 2>/dev/null | sort -n | tail -n 1 || true)
  git -C "$d" log -n 200 --format=%s "$base_ref..$head" >"$work/subjects" 2>/dev/null || : >"$work/subjects"
  out=$(awk 'FILENAME == ARGV[1] { s[$0] = 1; next }
      match($0, / \(#[0-9]+\)$/) {
        sub_ = substr($0, 1, RSTART - 1); i = index(sub_, " "); sha = substr(sub_, 1, i - 1); rest = substr(sub_, i + 1)
        j = index(rest, " "); ct = substr(rest, 1, j - 1); t = substr(rest, j + 1)
        if (t in s) { pr = substr($0, RSTART + 3, RLENGTH - 4); print sha "\t" ct "\t" pr "\t" t; if (++k == 3) exit }
      }' "$work/subjects" "$base_log" || true)
  while IFS=$'\t' read -r sha ct pr subj; do
    [[ -n "$sha" && -n "$newest" ]] || continue
    ((newest <= ct)) || continue
    if n=$("$here/gh-read.sh" --json -- api "repos/$repo/pulls/$pr" 2>/dev/null | jq -r '.merged_at // empty' 2>/dev/null) && [[ -n "$n" ]]; then
      printf 'likely\t(subject): "%s" landed on %s as %s (#%s, merged), after every lane commit\n' "$subj" "$base_name" "${sha:0:12}" "$pr"
      return 0
    fi
  done <<<"$out"
  echo "not merged into $base_name (ancestor, cherry, tree, squash, pr, subject)"; return 1
}

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
  [[ "$can_check" == yes ]] || { keep "cannot check processes: spectra owner --under failed"; continue; }
  if inside "$cwds" "$real"; then keep "a process is working inside it"; continue; fi
  ((age >= hours)) || { keep "touched ${age}h ago (< ${hours}h)"; continue; }
  landed=pushed
  if [[ -n "$base_ref" ]] && git -C "$real" merge-base --is-ancestor HEAD "$base_ref" 2>/dev/null; then
    landed="merged (ancestor): HEAD is an ancestor of $base_name"
  elif [[ -z "$(git -C "$real" branch -r --contains HEAD 2>/dev/null)" ]]; then
    # On no remote branch: squash- or rebase-merged lanes land here too (#393).
    proof=$(merged_proof "$real") && rc=0 || rc=$?
    ((rc == 0)) || { keep "HEAD is not on any remote branch (unpushed work): $proof"; continue; }
    case "$proof" in
      likely*) [[ "$include_likely" == yes ]] || { keep "likely merged ${proof#*"$tab"} (--include-likely removes it)"; continue; }
        landed="likely merged ${proof#*"$tab"}" ;;
      *) landed="merged ${proof#*"$tab"}" ;;
    esac
  fi
  # A remote-tracking ref can be stale (a push that died mid-hook never moved it, and an old fetch
  # can make HEAD look pushed): ask the remote itself that the branch holds HEAD (#262). A merged
  # lane's HEAD is on the default branch already: nothing of it lives only on its own branch.
  case "$landed:$branch" in
    *merged*) ;;
    *":(detached)" | *:-) ;;
    *)
      head_sha=$(git -C "$real" rev-parse HEAD 2>/dev/null || true)
      remote_line=$(git -C "$real" ls-remote origin "refs/heads/$branch" 2>/dev/null) || { keep "cannot read the remote branch (ls-remote failed)"; continue; }
      remote_sha=$(printf '%s\n' "$remote_line" | awk 'NR == 1 { print $1 }')
      if [[ -n "$remote_sha" && "$remote_sha" != "$head_sha" ]] && ! git -C "$real" merge-base --is-ancestor "$head_sha" "$remote_sha" 2>/dev/null; then
        keep "remote $branch is ${remote_sha:0:12}, HEAD ${head_sha:0:12} is not on it (push-verify.sh)"; continue
      fi ;;
  esac
  if [[ "$pr_closed" == yes && "$landed" == pushed ]]; then
    case "$branch" in "(detached)" | -) keep "no branch to match a PR"; continue ;; esac
    states=$("$here/gh-read.sh" --json -- pr list --repo "$repo" --head "$branch" --state all --limit 20 --json state 2>/dev/null |
      jq -r '[.[].state] | join(",")' 2>/dev/null) || { keep "PR state unreadable"; continue; }
    [[ -n "$states" ]] || { keep "no PR for $branch"; continue; }
    [[ ",$states," != *,OPEN,* ]] || { keep "PR still open"; continue; }
  fi
  removable=$((removable + 1))
  if [[ "$apply" == yes ]]; then
    # Read again right before removing: a session may have entered it since the first listing.
    fresh=$(proc_cwds "$real" | cut -f2-) || { keep "cannot check processes: spectra owner --under failed"; continue; }
    if inside "$fresh" "$real"; then keep "a process is working inside it"; continue; fi
    if out=$(git -C "$repo_dir" worktree remove "$real" 2>&1); then
      printf 'removed\t%s\tclean, idle %sh, %s\n' "$path" "$age" "$landed"
      live=$((live - 1))
      unset 'live_paths[${#live_paths[@]}-1]'
    else
      keep "git refused: ${out:0:200}"
    fi
  else
    printf 'remove\t%s\tclean, idle %sh, %s (dry run: --apply removes it)\n' "$path" "$age" "$landed"
  fi
done < <(git -C "$repo_dir" worktree list --porcelain | awk '
  /^worktree / { if (p != "") print p "\t" b "\t" l; p = substr($0, 10); b = "-"; l = "no" }
  /^branch / { b = substr($0, 8); sub("^refs/heads/", "", b) }
  /^detached/ { b = "(detached)" }
  /^locked/ { l = "yes" }
  END { if (p != "") print p "\t" b "\t" l }')

# Lane build dirs of worktrees that are gone, with the working directories read again when removing.
if [[ "$can_check" == yes ]]; then
  if [[ "$apply" != yes ]]; then
    build_dirs_sweep no "$cwds"
  elif fresh=$(proc_cwds "$(build_root)" | cut -f2-); then
    build_dirs_sweep yes "$fresh"
  fi
fi

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
