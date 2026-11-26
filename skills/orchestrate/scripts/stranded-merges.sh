#!/usr/bin/env bash
# Stranded merges (#410): PRs merged into a stacked base after the base's own PR had already
# merged, so their changes never reach the default branch. GitHub retargets a stacked PR to the
# default branch only when its base branch is deleted on merge (the repository's "Automatically
# delete head branches" setting); without that, a child merged into a finished base looks MERGED
# while its commits sit on a branch nothing will merge again (#404 into wt-session-hint-395 after
# #403 was squash-merged). Read-only; every read goes through gh-read.sh.
#
# Usage: stranded-merges.sh [--repo OWNER/REPO] [--since DAYS] [--limit N]
#   --since  only PRs merged in the last DAYS days (default 30)
#   --limit  read at most N closed PRs, newest first by update (default 300)
# Checked: every PR merged into a base other than the default branch. Its parent is the latest
# merged PR whose head is that base (an open one when none merged). The child is carried when the
# head the parent merged with contains the child's merge commit (compare status identical or
# ahead). When it does not, the files the child added are looked up in the default branch's tree,
# since a stack can be re-landed another way: the same path, or the same file under another
# directory (moved since: the same blob, or a file name that occurs once on main and is not a
# generic one like README.md or index.ts), counts as landed. When the base also has an open PR, that
# PR carries the child (PENDING).
# Output (TSV), one line per checked PR, then a summary line:
#   <n>  OK          base=<b>  parent=#<p>  contained in the head #<p> merged with
#   <n>  STRANDED    ...  missing on main: <k>/<m> added files (<paths>); retarget a new PR ...
#   <n>  RELANDED    ...  not in #<p>'s merged head, but its <m> added files are on main
#   <n>  UNVERIFIED  ...  not in #<p>'s merged head and it added no files, or only some of them
#                         could be checked (a truncated tree): compare by hand
#   <n>  ORPHAN      base=<b>  parent=-  no PR from <b> ever merged or is open
#   <n>  PENDING     ...  the base's PR is still open (it will carry the child when it merges),
#                         or the base has an open PR besides merged ones
#   <n>  unreadable  ...  <what could not be read>
#   checked=<n> stranded=<n> relanded=<n> unverified=<n> ok=<n> since=<YYYY-MM-DD>
# ("main" in the details is the repository's default branch.)
# Exit: 0 nothing stranded | 2 usage | 3 a STRANDED, UNVERIFIED or ORPHAN row | 4 a read failed
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority low

repo="" since=30 limit=300
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --since) since=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --limit) limit=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "stranded-merges.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$since" =~ ^[0-9]+$ ]] || { echo "stranded-merges.sh: --since needs a number of days" >&2; exit 2; }
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "stranded-merges.sh: --limit needs a positive number" >&2; exit 2; }
repo=$(orch_repo "$repo")
owner=${repo%%/*}

ghr() { "$here/gh-read.sh" --tries 3 -- "$@"; }   # bounded, typed, read-only
ghj() { "$here/gh-read.sh" --tries 3 --json -- "$@"; }

cutoff=$(jq -rn --argjson t "$(($(orch_now) - since * 86400))" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")')
default=$(ghj api "repos/$repo" | jq -r '.default_branch // empty') || default=""
[[ -n "$default" ]] || { echo "stranded-merges.sh: the default branch of $repo could not be read" >&2; exit 4; }

# Closed PRs, newest update first, until the limit or an empty page: "<n> <base> <merge sha>" for
# each one merged into another base since the cutoff.
kids=() page=1 seen=0
while ((seen < limit)); do
  body=$(ghj api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page") ||
    { echo "stranded-merges.sh: the closed PRs of $repo could not be read" >&2; exit 4; }
  n=$(jq length <<<"$body")
  ((n > 0)) || break
  while IFS= read -r row; do [[ -z "$row" ]] || kids+=("$row"); done < <(jq -r --arg d "$default" --arg c "$cutoff" \
    '.[] | select(.merged_at != null and .merged_at >= $c and .base.ref != $d)
     | "\(.number) \(.base.ref) \(.merge_commit_sha)"' <<<"$body")
  seen=$((seen + n)); page=$((page + 1))
done

# The default branch's file list, read once when a PR needs it: every path, and every file name
# (a file a later commit moved counts as landed). A truncated tree (a very large repository) falls
# back to one contents read per added file, at most 20 per PR.
work=$(mktemp -d "${TMPDIR:-/tmp}/stranded-merges.XXXXXX")
trap 'rm -rf "$work"' EXIT
tree=""
generic='(README|SKILL|CHANGELOG|LICENSE|CONTRIBUTING|AGENTS|CLAUDE)(\.[A-Za-z]+)?|index\.[a-z]+|main\.[a-z]+|__init__\.py|mod\.rs|lib\.rs|package\.json|Makefile|BUILD(\.bazel)?|build\.gradle(\.kts)?|Cargo\.toml|go\.mod|\.gitignore|\.gitkeep|Dockerfile|config\.[a-z]+|test_helper\.bash'
load_tree() {
  local body
  tree=per-file
  body=$(ghj api "repos/$repo/git/trees/$default?recursive=1") || return 0
  [[ "$(jq -r '.truncated // false' <<<"$body")" == false ]] || return 0
  jq -r '.tree[] | select(.type == "blob") | .path' <<<"$body" >"$work/paths"
  jq -r '.tree[] | select(.type == "blob") | .sha' <<<"$body" | sort -u >"$work/shas"
  # File names that occur once on main and are not generic: a moved file is recognised by its name
  # only when the name cannot belong to some other file.
  sed 's#.*/##' "$work/paths" | sort | uniq -u | grep -vxE "$generic" >"$work/names" || true
  tree=ok
}

# line VERDICT PARENT DETAIL: one output row for the PR in $n, merged into $base.
line() { printf '%s\t%s\tbase=%s\tparent=%s\t%s\n' "$n" "$1" "$base" "$2" "$3"; }
checked=0 stranded=0 relanded=0 unverified=0 ok=0 bad=0 unread=0
for ((i = 0; i < ${#kids[@]}; i++)); do
  read -r n base mc <<<"${kids[$i]}"
  checked=$((checked + 1))
  if ! parents=$(ghj api "repos/$repo/pulls?head=$owner:$base&state=all&per_page=20"); then
    line unreadable - "the base's PRs could not be read"; unread=1; continue
  fi
  # The latest merged PR from the base, and its open one (a long-lived base such as develop has
  # both: the open one carries what merged after the last merged one).
  read -r pn ph <<<"$(jq -r '[.[] | select(.merged_at != null)] | sort_by(.merged_at) | last // {}
    | "\(.number // "") \(.head.sha // "")"' <<<"$parents")"
  read -r open_pn open_ph <<<"$(jq -r '[.[] | select(.state == "open")] | first // {}
    | "\(.number // "") \(.head.sha // "")"' <<<"$parents")"
  if [[ -z "$pn" && -z "$open_pn" ]]; then
    line ORPHAN - "no PR from $base ever merged or is open: its changes are only on $base"; bad=1; continue
  fi
  if [[ -n "$pn" ]]; then
    if ! st=$(ghr api "repos/$repo/compare/$mc...$ph" --jq .status); then
      line unreadable "#$pn" "the compare of its merge commit with #$pn's head could not be read"; unread=1; continue
    fi
    if [[ "$st" == identical || "$st" == ahead ]]; then
      line OK "#$pn" "contained in the head #$pn merged with"; ok=$((ok + 1)); continue
    fi
  fi
  # PENDING only when the open PR's head really holds it: an abandoned PR, or a base deleted and
  # made again, must not hide a stranded child.
  if [[ -n "$open_pn" ]]; then
    if ! ost=$(ghr api "repos/$repo/compare/$mc...$open_ph" --jq .status); then
      line unreadable "#$open_pn" "the compare of its merge commit with open #$open_pn's head could not be read"; unread=1; continue
    fi
    if [[ "$ost" == identical || "$ost" == ahead ]]; then
      if [[ -n "$pn" ]]; then line PENDING "#$open_pn" "not in #$pn's merged head; the base's open PR #$open_pn carries it"
      else line PENDING "#$open_pn" "the base's PR is still open"; fi
      continue
    fi
  fi
  # The PR named in the verdicts below, and how its head is described.
  if [[ -n "$pn" ]]; then where="#$pn's merged head"; else pn=$open_pn where="open #$open_pn's head"; fi
  [[ -n "$tree" ]] || load_tree
  if ! added=$(ghr api --paginate "repos/$repo/pulls/$n/files?per_page=100" --jq '.[] | select(.status == "added") | "\(.sha)\t\(.filename)"'); then
    line unreadable "#$pn" "the PR's files could not be read"; unread=1; continue
  fi
  total=0 looked=0 missing=() moved=0 rc=0
  while IFS=$'\t' read -r sha f; do
    [[ -n "$f" ]] || continue
    total=$((total + 1))
    if [[ "$tree" == ok ]]; then
      looked=$((looked + 1))
      if grep -qxF -- "$f" "$work/paths"; then :
      elif grep -qxF -- "$sha" "$work/shas" || grep -qxF -- "${f##*/}" "$work/names"; then moved=$((moved + 1))
      else missing+=("$f"); fi
      continue
    fi
    ((looked < 20)) || continue
    looked=$((looked + 1)) rc=0
    enc=$(jq -rn --arg f "$f" '$f | @uri | gsub("%2F"; "/")')
    ghr api "repos/$repo/contents/$enc?ref=$default" --silent >/dev/null 2>&1 || rc=$?
    if ((rc == 3)); then missing+=("$f")
    elif ((rc != 0)); then unread=1; missing+=("$f?"); fi
  done <<<"$added"
  if ((total == 0)); then
    line UNVERIFIED "#$pn" "not in $where and it added no files: compare its diff with main by hand"
    unverified=$((unverified + 1)); bad=1
  elif ((${#missing[@]})); then
    line STRANDED "#$pn" "missing on main: ${#missing[@]}/$looked added files (${missing[*]}); retarget a new PR with its changes to main"
    stranded=$((stranded + 1)); bad=1
  elif ((looked < total)); then
    line UNVERIFIED "#$pn" "not in $where; $looked of its $total added files checked (all on main), the rest were not: compare by hand"
    unverified=$((unverified + 1)); bad=1
  else
    note=""; ((moved == 0)) || note=" ($moved under another directory)"
    line RELANDED "#$pn" "not in $where, but its $total added files are on main$note"; relanded=$((relanded + 1))
  fi
done
echo "checked=$checked stranded=$stranded relanded=$relanded unverified=$unverified ok=$ok since=${cutoff:0:10}"
((unread == 0)) || exit 4
((bad == 0)) || exit 3
exit 0
