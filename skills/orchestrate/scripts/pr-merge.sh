#!/usr/bin/env bash
# Merge ONE pull request after re-checking, at merge time, that it is still the PR that was judged
# ready. Never merges a draft, a fork-head PR, a PR by an unlisted author, or a moved head.
#
# Usage: pr-merge.sh --pr N --head SHA [--repo OWNER/REPO] [--author LOGIN]...
#                    [--method squash|merge|rebase] [--admin --evidence TEXT] [--main-fix]
#   --head      the head SHA (any prefix >= 7) that pr-ready.sh judged; a moved head refuses
#   --admin     bypass branch protection. Allowed only in the fast path: more open PRs than
#               ORCHESTRATE_FAST_PATH_OVER (default 20), or ORCHESTRATE_ADMIN_MERGE=1 when the
#               user authorized it. Needs --evidence naming the classified flake or pending
#               advisory check being bypassed; it is written to the merge log.
#   --main-fix  this PR fixes a red default branch; merge although MAIN_RED is set
# Exit: 0 merged | 3 ineligible or head moved | 4 default branch is red (hold) | 5 merge failed
#       | 6 --admin not allowed
# Appends one line per attempt to <state dir>/merges.log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" pr="" head="" method=squash admin=no evidence="" main_fix=no
authors=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --author) authors+=("$2"); shift 2 ;;
    --method) method=$2; shift 2 ;;
    --admin) admin=yes; shift ;;
    --evidence) evidence=$2; shift 2 ;;
    --main-fix) main_fix=yes; shift ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "pr-merge.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$pr" && ${#head} -ge 7 ]] || { sed -n '2,16p' "$0" >&2; exit 2; }
case "$method" in squash | merge | rebase) ;; *) echo "pr-merge.sh: bad --method $method" >&2; exit 2 ;; esac
repo=$(orch_repo "$repo")
((${#authors[@]})) || authors=("$(orch_author)")
state=$(orch_state_dir "$repo")
log() { printf '%s\tpr=%s\thead=%s\t%s\n' "$(orch_iso "$(orch_now)")" "$pr" "${head:0:9}" "$*" >>"$state/merges.log"; }

if [[ -f "$state/MAIN_RED" && "$main_fix" == no ]]; then
  echo "hold: default branch is red ($(head -1 "$state/MAIN_RED"))"; exit 4
fi

if [[ "$admin" == yes ]]; then
  [[ -n "$evidence" ]] || { echo "refused: --admin needs --evidence"; exit 6; }
  if [[ "${ORCHESTRATE_ADMIN_MERGE:-0}" != 1 ]]; then
    over=${ORCHESTRATE_FAST_PATH_OVER:-20}
    open=$(gh pr list --repo "$repo" --state open --limit 300 --json number | jq length)
    if ((open <= over)); then
      echo "refused: --admin is fast-path only ($open open PRs, threshold >$over)"; exit 6
    fi
  fi
fi

info=$(gh pr view "$pr" --repo "$repo" --json state,isDraft,isCrossRepository,headRefOid,author,mergeable)
ok=$(jq -r --arg head "$head" --args '
  .state == "OPEN" and (.isDraft | not) and (.isCrossRepository | not)
  and (.headRefOid | startswith($head)) and (.mergeable != "CONFLICTING")
  and (.author.login as $a | $ARGS.positional | index($a) != null)' "${authors[@]}" <<<"$info")
if [[ "$ok" != true ]]; then
  echo "ineligible: $(jq -c '{state,isDraft,isCrossRepository,head:.headRefOid[0:9],author:.author.login,mergeable}' <<<"$info")"
  log "refused ineligible"
  exit 3
fi

args=("--$method")
[[ "$admin" == yes ]] && args+=(--admin)
out=$(gh pr merge "$pr" --repo "$repo" "${args[@]}" 2>&1 | tail -1) || true
final=$(gh pr view "$pr" --repo "$repo" --json state,mergeCommit | jq -r '"\(.state) \(.mergeCommit.oid // "-")"')
if [[ "$final" == MERGED* ]]; then
  log "merged ${final#MERGED } method=$method admin=$admin${evidence:+ evidence=$evidence}"
  echo "merged $pr ${final#MERGED }"
else
  log "failed: $out"
  echo "merge failed: $out"
  exit 5
fi
