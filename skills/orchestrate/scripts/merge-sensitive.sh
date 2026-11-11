#!/usr/bin/env bash
# Merge-sensitive paths: shared, append-mostly files (version catalogs, size-budget tests, generated
# contracts) where two PRs that are each green on their own base can merge cleanly in git and still
# break the default branch together. A PR that touches one may merge only when its head already
# contains the current base branch, or when a cheap merge-result check passes on head + base.
#
# Usage: merge-sensitive.sh paths --pr N [--repo OWNER/REPO]
#        merge-sensitive.sh check --pr N --head SHA [--repo OWNER/REPO]
#                                 [--worktree DIR --check-cmd CMD]
#        merge-sensitive.sh drift --worktree DIR --base B [--repo OWNER/REPO]
#   paths   print each configured pattern the PR touches, one per line (nothing: touches none)
#   check   one line: `clear: ...` (touches none, head contains the base, the base's newer
#           commits touch no protected path, or the merge-result check passed) or `stale: ...`
#           (touches a pattern and the base's newer commits touch a protected path; merge the base
#           in and wait for a green run, or pass a merge-result check)
#   drift   print each protected pattern that origin/B's commits since its merge-base with DIR's
#           HEAD touch (`git diff --name-only <merge-base> origin/B`, read locally), one per line
#           (nothing: unrelated drift). merge-queue.sh re-validates its front only then (#204).
# Protected paths = the merge-sensitive patterns plus the shared manifests, one per line from
# <state dir>/merge-manifests and ORCHESTRATE_MERGE_MANIFESTS (same syntax; either one, even
# empty, replaces the default). Default, at the root or in any directory: package.json and the
# lockfiles (package-lock.json, yarn.lock, pnpm-lock.yaml, Cargo.lock, go.sum, Gemfile.lock,
# poetry.lock, uv.lock, libs.versions.toml) and schema files (*.schema.json, schema.graphql,
# schema.prisma). A manifest never makes a PR merge-sensitive; it only counts as drift.
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
orch_gh_priority normal

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  paths | check | drift) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" pr="" head="" worktree="" check_cmd="" base=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --worktree) worktree=$2; shift 2 ;;
    --check-cmd) check_cmd=$2; shift 2 ;;
    *) echo "merge-sensitive.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ "$cmd" == drift ]]; then
  [[ -n "$worktree" && -n "$base" && -z "$pr$head$check_cmd" ]] || usage
else
  [[ "$pr" =~ ^[0-9]+$ && -z "$base" ]] || usage
  [[ "$cmd" == paths || ${#head} -ge 7 ]] || usage
  [[ -z "$worktree" && -z "$check_cmd" || -n "$worktree" && -n "$check_cmd" ]] ||
    { echo "merge-sensitive.sh: --worktree and --check-cmd go together" >&2; exit 2; }
fi

# clean: stdin without comments, blanks, surrounding space or repeats.
clean() { sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF && !seen[$0]++'; }

# The configured patterns.
patterns() {
  local cfg
  cfg="$(orch_state_dir "$repo")/merge-sensitive"
  {
    [[ ! -f "$cfg" ]] || cat "$cfg"
    printf '%s\n' "${ORCHESTRATE_MERGE_SENSITIVE:-}" | tr ',' '\n'
  } | clean
}

# The shared manifests: the configured list, or the default one when none is configured.
default_manifests="package.json package-lock.json yarn.lock pnpm-lock.yaml Cargo.lock go.sum
  Gemfile.lock poetry.lock uv.lock libs.versions.toml schema.graphql schema.prisma"
manifests() {
  local cfg m
  cfg="$(orch_state_dir "$repo")/merge-manifests"
  if [[ -f "$cfg" || -n "${ORCHESTRATE_MERGE_MANIFESTS+set}" ]]; then
    {
      [[ ! -f "$cfg" ]] || cat "$cfg"
      printf '%s\n' "${ORCHESTRATE_MERGE_MANIFESTS:-}" | tr ',' '\n'
    } | clean
    return 0
  fi
  for m in $default_manifests; do printf '%s\n*/%s\n' "$m" "$m"; done
  printf '%s\n' '*.schema.json'
}

# protected_hits FILES -> each protected pattern (merge-sensitive or manifest) one of FILES matches.
# A `*` line (a file list cut short) counts as a hit: `300+ files`.
protected_hits() {
  local p f
  if grep -Fxq -- '*' <<<"$1"; then echo "300+ files"; return 0; fi
  while IFS= read -r p; do
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if matches "$p" "$f"; then printf '%s\n' "$p"; break; fi
    done <<<"$1"
  done < <({ patterns; manifests; } | awk '!seen[$0]++')
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
if [[ "$cmd" == drift ]]; then
  # Read from the caller's fetched checkout; nothing is read from GitHub.
  mb=$(git -C "$worktree" merge-base HEAD "origin/$base" 2>/dev/null) &&
    dfiles=$(git -C "$worktree" diff --name-only --no-renames "$mb" "origin/$base" 2>/dev/null) ||
    { echo "unverified: could not diff origin/$base against its merge-base with HEAD in $worktree"; exit 9; }
  protected_hits "$dfiles"
  exit 0
fi
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
# Only drift into the protected area makes it stale (#204): the files of the base's newer commits.
drift=$(orch_read_retry 3 gh api "repos/$repo/compare/$head...$base" \
  --jq 'if (.files | length) >= 300 then "*" else .files[] | .filename, (.previous_filename // empty) end') ||
  { echo "unverified: could not read the files $base changed since ${head:0:9}"; exit 9; }
hits=$(protected_hits "$drift")
if [[ -z "$hits" ]]; then
  echo "clear: PR $pr touches $list and is $behind commit(s) behind $base, which touch no protected path"
  exit 0
fi
stale="PR $pr touches merge-sensitive $list and is $behind commit(s) behind $base, which touch $(paste -sd, - <<<"$hits")"
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
