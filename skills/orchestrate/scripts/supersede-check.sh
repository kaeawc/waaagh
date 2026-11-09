#!/usr/bin/env bash
# Before a conflict repair re-applies an old PR on top of the base, ask whether later merges have
# already superseded it (#195): main may ship the PR's behaviour under another design, and
# re-applying would reverse choices main already made. Read-only: no git or GitHub writes.
#
# Usage: supersede-check.sh [--repo OWNER/REPO] [--pr N] [--issue N] [--worktree DIR]
#                           [--base BRANCH] [--head REV]
#   --pr        the PR under repair (state, base branch and linked issue are read from it).
#               Omitted with --worktree: the open PR whose head is the worktree's branch, if any.
#   --issue     the PR's issue (default: the first "Fixes|Closes|Resolves #N" in the PR body)
#   --worktree  a checkout of the PR branch with origin/BASE fetched; enables the hunk check
#   --base      default: the PR's base branch, else origin's HEAD branch, else main
#   --head      the PR side of the comparison in the worktree (default HEAD)
#   At least one of --pr and --worktree.
# Two signals, either one makes the PR a SUPERSEDED-CANDIDATE:
#   issue  the issue is closed and the closing commit belongs to another merged PR (timeline
#          `closed` event -> GET commits/<sha>/pulls); with no closing commit, a merged PR other
#          than this one that cross-references the closed issue.
#   hunks  for each file `git merge-tree HEAD origin/BASE` reports conflicted: the PR's hunks
#          (diff merge-base..HEAD) that touch or overlap the base's hunks (merge-base..origin/BASE)
#          whose added lines `git blame` puts in commits after the merge base. Each commit is tied
#          to its merged PR by a "(#N)" subject or the "Merge pull request #N" that brought it in.
#          An overlap counts when that PR is for the same issue: its commit message mentions #N,
#          it is the PR that closed the issue, or its title or body (GET pulls/<n>) mentions #N.
# Output: line 1 "SUPERSEDED-CANDIDATE pr=#P issue=#I" or "NOT-SUPERSEDED pr=#P issue=#I" (- when
#   unknown; a PR already merged or closed adds ": PR is MERGED|CLOSED"), then one "reason: ..."
#   line per signal, then, when any conflict hunk overlaps later merged lines, the table
#   "file<TAB>pr_lines<TAB>main_lines<TAB>merged_pr<TAB>same_issue" (lines are merge-base line
#   ranges for the PR, origin/BASE line ranges for main; merged_pr is - when no PR is known).
# Exit: 0 not a candidate | 10 SUPERSEDED-CANDIDATE | 2 usage | 3 PR or issue unreadable |
#   4 worktree unusable (no origin/BASE, no merge base, merge-tree failed)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

repo="" pr="" issue="" wt="" base="" head=HEAD
while (($#)); do
  case "$1" in
    -h | --help) orch_usage; exit 0 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --pr) pr=${2:?}; shift 2 ;;
    --issue) issue=${2:?}; shift 2 ;;
    --worktree) wt=${2:?}; shift 2 ;;
    --base) base=${2:?}; shift 2 ;;
    --head) head=${2:?}; shift 2 ;;
    *) echo "supersede-check.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
pr=${pr#\#} issue=${issue#\#}
[[ -n "$pr" || -n "$wt" ]] || { orch_usage >&2; exit 2; }
[[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || { echo "supersede-check.sh: --pr must be a number" >&2; exit 2; }
[[ -z "$issue" || "$issue" =~ ^[0-9]+$ ]] || { echo "supersede-check.sh: --issue must be a number" >&2; exit 2; }
[[ -z "$wt" || -d "$wt" ]] || { echo "supersede-check.sh: no worktree $wt" >&2; exit 4; }

repo=$(orch_repo "$repo")
ghr() { "$here/gh-read.sh" --json -- "$@" 2>/dev/null; }
g() { git -C "$wt" "$@"; }

# The PR: found by the worktree's branch when not given; its state, base and issue.
if [[ -z "$pr" ]]; then
  branch=$(g branch --show-current 2>/dev/null || true)
  if [[ -n "$branch" ]] && open=$(ghr api "repos/$repo/pulls?head=${repo%%/*}:$branch&state=open&per_page=10"); then
    pr=$(jq -r '.[0].number // empty' <<<"$open")
  fi
fi
prstate=OPEN
if [[ -n "$pr" ]]; then
  pj=$(ghr api "repos/$repo/pulls/$pr") || { echo "supersede-check.sh: PR #$pr unreadable" >&2; exit 3; }
  prstate=$(jq -r 'if .merged_at != null then "MERGED" elif .state == "closed" then "CLOSED" else "OPEN" end' <<<"$pj")
  [[ -n "$base" ]] || base=$(jq -r '.base.ref // empty' <<<"$pj")
  if [[ -z "$issue" ]]; then
    issue=$(jq -r '.body // ""' <<<"$pj" |
      grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#[0-9]+' | awk -F'#' 'NR == 1 { print $2 }' || true)
  fi
fi
if [[ "$prstate" != OPEN ]]; then
  echo "NOT-SUPERSEDED pr=#$pr issue=#${issue:--}: PR is $prstate"
  exit 0
fi
if [[ -z "$base" && -n "$wt" ]]; then
  base=$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  base=${base#origin/}
fi

reasons=() closers=""
# mentions TEXT -> whether TEXT names the issue (#I not followed by a digit).
mentions() { [[ -n "$issue" && "$1" =~ \#${issue}([^0-9]|$) ]]; }

# --- signal 1: the issue was closed by another merged PR ---------------------------------------
if [[ -n "$issue" ]]; then
  ij=$(ghr api "repos/$repo/issues/$issue") || { echo "supersede-check.sh: issue #$issue unreadable" >&2; exit 3; }
  if [[ "$(jq -r .state <<<"$ij")" == closed ]]; then
    tl=$(ghr api "repos/$repo/issues/$issue/timeline?per_page=100") || tl='[]'
    while IFS= read -r sha; do
      [[ -n "$sha" ]] || continue
      cp=$(ghr api "repos/$repo/commits/$sha/pulls") || continue
      while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        closers+=" $n"
        reasons+=("reason: issue #$issue closed by merged PR #$n (commit ${sha:0:9})")
      done < <(jq -r --argjson p "${pr:-0}" '.[] | select(.merged_at != null and .number != $p) | .number' <<<"$cp")
    done < <(jq -r '.[] | select(.event == "closed" and .commit_id != null) | .commit_id' <<<"$tl")
    if [[ -z "$closers" ]]; then
      while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        closers+=" $n"
        reasons+=("reason: issue #$issue is closed and merged PR #$n references it")
      done < <(jq -r --argjson p "${pr:-0}" '[.[] | select(.event == "cross-referenced") | .source.issue
        | select(.pull_request.merged_at != null and .number != $p) | .number] | unique | .[]' <<<"$tl")
    fi
  fi
fi

# --- signal 2: conflict hunks overlap lines later merged PRs added ------------------------------
rows=() same_hits=""
# hunks: "@@ -a,b +c,d @@" lines -> "os oe ns ne added" per hunk; a zero-length side is the
# insertion point and the line after it, so an insertion touches its neighbours.
hunks() {
  awk '/^@@ / {
    split(substr($2, 2), o, ","); split(substr($3, 2), n, ",")
    ob = (2 in o) ? o[2] : 1; nb = (2 in n) ? n[2] : 1
    os = o[1] + 0; oe = (ob > 0) ? os + ob - 1 : os + 1
    ns = n[1] + 0; ne = (nb > 0) ? ns + nb - 1 : ns
    print os, oe, ns, ne, nb
  }'
}
# pr_of SHA -> the merged PR a base commit belongs to, or nothing.
pr_of() {
  local s m
  s=$(g log -1 --format=%s "$1")
  if [[ "$s" =~ \(#([0-9]+)\)$ ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ "$s" =~ ^Merge\ pull\ request\ #([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  m=$(g log --merges --ancestry-path --reverse --format=%s "$1..origin/$base" |
    awk '!f && /^Merge pull request #[0-9]+/ { sub(/^Merge pull request #/, ""); sub(/[^0-9].*/, ""); print; f = 1 }')
  [[ -z "$m" ]] || echo "$m"
}
# same_issue N SHA -> yes|no: is merged PR N for this PR's issue? Cached per PR in $same_cache.
same_cache=" "
same_issue() {
  local n=$1 hit=no body
  [[ -n "$issue" ]] || { echo no; return; }
  case "$same_cache" in *" $n:yes "*) echo yes; return ;; *" $n:no "*) echo no; return ;; esac
  if [[ " $closers " == *" $n "* ]] || mentions "$(g log -1 --format=%B "$2")"; then
    hit=yes
  elif body=$(ghr api "repos/$repo/pulls/$n") && mentions "$(jq -r '(.title // "") + "\n" + (.body // "")' <<<"$body")"; then
    hit=yes
  fi
  same_cache+="$n:$hit "
  echo "$hit"
}

if [[ -n "$wt" ]]; then
  g rev-parse -q --verify "origin/$base^{commit}" >/dev/null ||
    { echo "supersede-check.sh: no origin/$base in $wt (fetch it first)" >&2; exit 4; }
  mb=$(g merge-base "$head" "origin/$base") || { echo "supersede-check.sh: no merge base of $head and origin/$base" >&2; exit 4; }
  mrc=0
  mt=$(g merge-tree --write-tree --name-only --no-messages "$head" "origin/$base") || mrc=$?
  ((mrc <= 1)) || { echo "supersede-check.sh: git merge-tree failed (exit $mrc; needs git 2.38+)" >&2; exit 4; }
  conflicted=""
  ((mrc == 0)) || conflicted=$(awk 'NR > 1 && NF' <<<"$mt")
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    prh=$(g diff -U0 "$mb" "$head" -- "$f" | hunks)
    bh=$(g diff -U0 "$mb" "origin/$base" -- "$f" | hunks)
    while read -r ps pe _ _ _; do
      [[ -n "$ps" ]] || continue
      while read -r bs be ns ne nb; do
        [[ -n "$bs" ]] && ((nb > 0 && ps <= be && bs <= pe)) || continue
        prs=""
        while IFS= read -r sha; do
          [[ -n "$sha" ]] || continue
          ! g merge-base --is-ancestor "$sha" "$mb" || continue
          n=$(pr_of "$sha")
          [[ " $prs " != *" ${n:--}:"* ]] || continue
          prs+=" ${n:--}:$sha"
        done < <(g blame --line-porcelain -L "$ns,$ne" "origin/$base" -- "$f" | awk '/^[0-9a-f]{40} / { print $1 }' | sort -u)
        for entry in $prs; do
          n=${entry%%:*} sha=${entry#*:}
          same=no
          [[ "$n" == - ]] || same=$(same_issue "$n" "$sha")
          [[ "$same" == no ]] || same_hits+=" $n"
          lab=$n; [[ "$n" == - ]] || lab="#$n"
          rows+=("$(printf '%s\t%s-%s\t%s-%s\t%s\t%s' "$f" "$ps" "$pe" "$ns" "$ne" "$lab" "$same")")
        done
      done <<<"$bh"
    done <<<"$prh"
  done <<<"$conflicted"
  for n in $(tr ' ' '\n' <<<"$same_hits" | awk 'NF && !s[$0]++'); do
    reasons+=("reason: conflict hunks overlap lines merged PR #$n added for issue #$issue")
  done
fi

verdict=NOT-SUPERSEDED
((${#reasons[@]} == 0)) || verdict=SUPERSEDED-CANDIDATE
echo "$verdict pr=#${pr:--} issue=#${issue:--}"
((${#reasons[@]} == 0)) || printf '%s\n' "${reasons[@]}"
if ((${#rows[@]})); then
  printf 'file\tpr_lines\tmain_lines\tmerged_pr\tsame_issue\n'
  printf '%s\n' "${rows[@]}"
fi
[[ "$verdict" == NOT-SUPERSEDED ]] || exit 10
