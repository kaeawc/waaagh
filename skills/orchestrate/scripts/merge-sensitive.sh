#!/usr/bin/env bash
# Merge-sensitive paths: shared, append-mostly files (version catalogs, size-budget tests, generated
# contracts) where two PRs that are each green on their own base can merge cleanly in git and still
# break the default branch together. A PR that touches one may merge only when its head already
# contains the current base branch, or when a cheap merge-result check passes on head + base.
#
# Usage: merge-sensitive.sh paths --pr N [--repo OWNER/REPO]
#        merge-sensitive.sh check --pr N --head SHA [--repo OWNER/REPO]
#                                 [--worktree DIR --check-cmd CMD]
#   paths   print each configured pattern the PR touches, one per line (nothing: touches none)
#   check   one line: `clear: ...` (touches none, head contains the base, or the merge-result
#           check passed) or `stale: ...` (touches a pattern and the base has commits the head
#           lacks; merge the base in and wait for a green run, or pass a merge-result check)
#   --worktree, --check-cmd   the merge-result check: in a temporary detached worktree of DIR (any
#           clone of the repo), fetch the base and the head, merge the head into the base, and run
#           CMD there (e.g. `./gradlew help`, the budget test). A conflict or a failing CMD is stale.
# Patterns, one per line (`#` comments and blank lines ignored), from <state dir>/merge-sensitive
# and from ORCHESTRATE_MERGE_SENSITIVE (newline- or comma-separated). A pattern ending in `/` is a
# directory prefix; otherwise it is a bash glob over the repo path, where `*` also matches `/`
# (`gradle/libs.versions.toml`, `web/budget*.test.ts`, `contracts/`). No patterns: every PR is
# clear and nothing is read from GitHub. Renames count under both names.
# Exit: 0 clear (check) or listed (paths) | 2 usage | 3 stale | 9 unverified (a read failed, or the
#       merge-result check could not be set up): treat as not clear
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

usage() { sed -n '2,23p' "$0" >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  paths | check) shift ;;
  -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
  *) usage ;;
esac
repo="" pr="" head="" worktree="" check_cmd=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --worktree) worktree=$2; shift 2 ;;
    --check-cmd) check_cmd=$2; shift 2 ;;
    *) echo "merge-sensitive.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$pr" =~ ^[0-9]+$ ]] || usage
[[ "$cmd" == paths || ${#head} -ge 7 ]] || usage
[[ -z "$worktree" && -z "$check_cmd" || -n "$worktree" && -n "$check_cmd" ]] ||
  { echo "merge-sensitive.sh: --worktree and --check-cmd go together" >&2; exit 2; }

# The configured patterns, without comments, blanks or surrounding space.
patterns() {
  local cfg
  cfg="$(orch_state_dir "$repo")/merge-sensitive"
  {
    [[ ! -f "$cfg" ]] || cat "$cfg"
    printf '%s\n' "${ORCHESTRATE_MERGE_SENSITIVE:-}" | tr ',' '\n'
  } | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF && !seen[$0]++'
}

# matches PATTERN FILE
matches() {
  local p=$1 f=$2
  if [[ "$p" == */ ]]; then [[ "$f" == "$p"* ]]; else
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ "$f" == $p ]]
  fi
}

repo=$(orch_repo "$repo")
pats=$(patterns)
if [[ -z "$pats" ]]; then
  [[ "$cmd" == paths ]] || echo "clear: no merge-sensitive paths configured"
  exit 0
fi

files=$(orch_read_retry 3 gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" \
  --jq '.[] | .filename, (.previous_filename // empty)') ||
  { echo "unverified: the files of PR $pr could not be read"; exit 9; }
touched=()
while IFS= read -r p; do
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if matches "$p" "$f"; then touched+=("$p"); break; fi
  done <<<"$files"
done <<<"$pats"

if [[ "$cmd" == paths ]]; then
  for p in ${touched[@]+"${touched[@]}"}; do printf '%s\n' "$p"; done
  exit 0
fi
if ((${#touched[@]} == 0)); then echo "clear: PR $pr touches no merge-sensitive path"; exit 0; fi
list=$(IFS=,; echo "${touched[*]}")

base=$(orch_read_retry 3 gh api "repos/$repo/pulls/$pr" --jq .base.ref) && [[ -n "$base" ]] ||
  { echo "unverified: the base branch of PR $pr could not be read"; exit 9; }
behind=$(orch_read_retry 3 gh api "repos/$repo/compare/$base...$head" --jq .behind_by) &&
  [[ "$behind" =~ ^[0-9]+$ ]] ||
  { echo "unverified: could not compare ${head:0:9} with $base"; exit 9; }
if ((behind == 0)); then
  echo "clear: PR $pr touches $list and its head contains $base"; exit 0
fi
stale="PR $pr touches merge-sensitive $list and is $behind commit(s) behind $base"
if [[ -z "$check_cmd" ]]; then
  echo "stale: $stale; merge $base in and wait for a green run, or pass a merge-result check"
  exit 3
fi

# The merge-result check, in a throwaway detached worktree; the caller's checkout is not touched.
git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 ||
  { echo "unverified: $worktree is not a git checkout"; exit 9; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/merge-sensitive.XXXXXX")
cleanup() { git -C "$worktree" worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
logf="$(orch_state_dir "$repo")/merge-sensitive-pr$pr.log"
if ! git -C "$worktree" fetch -q origin "$base" >"$logf" 2>&1 ||
  ! git -C "$worktree" fetch -q origin "$head" >>"$logf" 2>&1; then
  echo "unverified: could not fetch $base and ${head:0:9} into $worktree (see $logf)"; exit 9
fi
full=$(git -C "$worktree" rev-parse -q --verify "FETCH_HEAD^{commit}") && [[ "$full" == "$head"* ]] ||
  { echo "unverified: fetched head is not ${head:0:9}"; exit 9; }
basesha=$(git -C "$worktree" rev-parse -q --verify "refs/remotes/origin/$base^{commit}") ||
  { echo "unverified: origin/$base is not known in $worktree"; exit 9; }
git -C "$worktree" worktree add -q --detach "$tmp/wt" "$basesha" >>"$logf" 2>&1 ||
  { echo "unverified: could not create a temporary worktree (see $logf)"; exit 9; }
if ! git -C "$tmp/wt" -c commit.gpgsign=false merge -q --no-edit --no-ff "$full" >>"$logf" 2>&1; then
  echo "stale: $stale, and the merge result conflicts (see $logf)"; exit 3
fi
if ! (cd "$tmp/wt" && bash -c "$check_cmd") >>"$logf" 2>&1; then
  echo "stale: $stale, and the merge-result check failed (see $logf)"; exit 3
fi
echo "clear: $stale, but the merge-result check passed on ${basesha:0:9} + ${full:0:9}"
