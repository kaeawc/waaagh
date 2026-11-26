#!/usr/bin/env bash
# Carry a ship verdict over clean base merges (#414). A ship recorded --head R covers a later head
# only through merges GitHub made from update-branch (orch_review_covers, #210). A base merge made
# locally (merge-queue.sh's own, or a lane's that resolved nothing) holds the approved PR as
# `review:stale` until someone reviews it again, though it changes nothing. This checks that every
# commit since R is such a merge and records a new ship at the head, saying why.
#
# Usage: reship.sh --pr N [--head SHA] [--base BRANCH] [--repo OWNER/REPO] [--dry-run]
#   --head  the head to cover (default the PR's head on GitHub)
#   --base  the base branch (default the PR's base)
# Covered when the PR's latest ledger verdict is ship recorded --head R, R is an ancestor of the
# head, and every commit after R that is not on origin/BASE has two parents, one of them on
# origin/BASE, and a tree equal to the clean automatic merge of its parents (`git merge-tree
# --write-tree`, git 2.38+): it brings in the base and nothing else, whoever made it. Then
# `review-ledger.sh record --verdict ship --head <head>` with the note `reship: only clean merges
# of BASE since R`. Local git in ORCHESTRATE_GIT_DIR (default the current directory); BASE and
# refs/pull/N/head are fetched from origin first.
# Output: `reshipped #N <head9> (from <R9>)` | `covered #N <head9>: same head` | `refused #N: <why>`
#   | `would reship #N <head9> (from <R9>)` (--dry-run)
# Exit: 0 reshipped or already covered | 2 usage | 3 refused (not ship, no --head on the verdict,
#       or a commit that is not a clean base merge) | 4 the PR or the ledger could not be read
#       | 5 the ledger write failed
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

repo="" pr="" head="" base="" dry=no
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --pr) pr=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --head) head=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --base) base=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "reship.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$pr" =~ ^[0-9]+$ ]] || { echo "reship.sh: --pr needs a number" >&2; exit 2; }
[[ -z "$head" || "$head" =~ ^[0-9a-f]{7,40}$ ]] || { echo "reship.sh: --head needs a SHA" >&2; exit 2; }
repo=$(orch_repo "$repo")
d=${ORCHESTRATE_GIT_DIR:-.}
refuse() { echo "refused #$pr: $*"; exit 3; }

if [[ -z "$head" || -z "$base" ]]; then
  info=$("$here/gh-read.sh" --tries 3 --json -- api "repos/$repo/pulls/$pr") || { echo "reship.sh: PR $pr could not be read" >&2; exit 4; }
  [[ -n "$head" ]] || head=$(jq -r '.head.sha // empty' <<<"$info")
  [[ -n "$base" ]] || base=$(jq -r '.base.ref // empty' <<<"$info")
  [[ -n "$head" && -n "$base" ]] || { echo "reship.sh: PR $pr has no head or base" >&2; exit 4; }
fi

lrc=0; latest=$(orch_run review-ledger.sh latest --repo "$repo" --pr "$pr" 2>/dev/null) || lrc=$?
((lrc != 3)) || refuse "no review verdict recorded"
((lrc == 0)) || { echo "reship.sh: the review ledger could not be read" >&2; exit 4; }
IFS=$'\t' read -r _ _ verdict reviewed _ <<<"$latest"
[[ "$verdict" == ship ]] || refuse "the latest verdict is $verdict, not ship"
[[ -n "$reviewed" && "$reviewed" != - ]] || refuse "the ship verdict was recorded without --head"

git -C "$d" fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" </dev/null >/dev/null 2>&1 || true
git -C "$d" cat-file -e "$head^{commit}" 2>/dev/null ||
  git -C "$d" fetch -q origin "refs/pull/$pr/head" </dev/null >/dev/null 2>&1 || true
r=$(git -C "$d" rev-parse -q --verify "$reviewed^{commit}" 2>/dev/null) || refuse "${reviewed:0:9} is not in $d"
h=$(git -C "$d" rev-parse -q --verify "$head^{commit}" 2>/dev/null) || refuse "${head:0:9} is not in $d"
if [[ "$r" == "$h" ]]; then echo "covered #$pr ${h:0:9}: same head"; exit 0; fi
git -C "$d" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" >/dev/null 2>&1 || refuse "origin/$base is not in $d"
git -C "$d" merge-base --is-ancestor "$r" "$h" 2>/dev/null || refuse "${r:0:9} is not an ancestor of ${h:0:9}"
after=$(git -C "$d" log --format='%H %P' "$h" "^$r" "^refs/remotes/origin/$base") || refuse "git log ${r:0:9}..${h:0:9} failed"
[[ -n "$after" ]] || refuse "no commit after ${r:0:9} outside origin/$base"
while read -r c p1 p2 rest; do
  [[ -n "$c" ]] || continue
  [[ -n "$p2" && -z "$rest" ]] || refuse "${c:0:9} is not a two-parent merge"
  { git -C "$d" merge-base --is-ancestor "$p1" "refs/remotes/origin/$base" 2>/dev/null ||
    git -C "$d" merge-base --is-ancestor "$p2" "refs/remotes/origin/$base" 2>/dev/null; } || refuse "${c:0:9} does not merge $base"
  want=$(git -C "$d" merge-tree --write-tree "$p1" "$p2" 2>/dev/null) || refuse "${c:0:9} is not a clean merge of its parents (or git is older than 2.38)"
  [[ "${want%%$'\n'*}" == "$(git -C "$d" rev-parse "$c^{tree}")" ]] || refuse "${c:0:9} changes more than the merge of $base"
done <<<"$after"

if [[ "$dry" == yes ]]; then echo "would reship #$pr ${h:0:9} (from ${r:0:9})"; exit 0; fi
orch_run review-ledger.sh record --repo "$repo" --pr "$pr" --verdict ship --head "$h" \
  --note "reship: only clean merges of $base since ${r:0:9}" >/dev/null ||
  { echo "reship.sh: the ledger write failed" >&2; exit 5; }
echo "reshipped #$pr ${h:0:9} (from ${r:0:9})"
