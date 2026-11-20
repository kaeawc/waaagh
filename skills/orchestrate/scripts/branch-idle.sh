#!/usr/bin/env bash
# Has anyone written to a PR's branch recently (#242)? The "skip a PR pushed in the last N
# minutes, another session may be writing" guard, keyed on the newest real write, not the head.
# GitHub's update-branch merge (`gh pr update-branch`, update-pace.sh run, the Update branch
# button) gives a PR a fresh head with no second writer, so a guard on the head's time skips every
# PR the orchestrator just updated. Here a commit counts as a write unless it is on the base or is
# such a merge (orch_update_merge in _lib.sh: two parents, committer GitHub, one parent on the
# base, the clean merge tree); a merge made by hand (a conflict resolution) is a write.
#
# Usage: branch-idle.sh (--pr N | --head REF) [--minutes M] [--base BRANCH] [--repo OWNER/REPO]
#   --pr N       read the PR's head from origin (refs/pull/N/head)
#   --head REF   a commit or ref already in the checkout instead (e.g. origin/work/12-auto)
#   --minutes M  the quiet period: idle when the newest write is at least M minutes old (default 30)
#   --base B     the PR's base branch (default: the repository's default branch, one gh read)
# Local git in ORCHESTRATE_GIT_DIR (default .); fetches origin/B (and the PR head) quietly first.
# One line:
#   idle|active <#N|REF> last-write=<sha9>|none age=<m>m|- merges-skipped=<k>
#   last-write=none: no commit off the base but update-branch merges, so nobody wrote: idle.
#   merges-skipped: the update-branch merges after the base that were not counted as writes.
# Env: ORCHESTRATE_GIT_DIR, ORCHESTRATE_NOW (tests).
# Exit: 0 idle | 1 active | 2 usage | 4 the branch or base could not be read
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

repo="" pr="" head="" minutes=30 base=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=${2#\#}; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --minutes) minutes=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "branch-idle.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
{ [[ -n "$pr" && -z "$head" && "$pr" =~ ^[0-9]+$ ]] || [[ -z "$pr" && -n "$head" ]]; } || { orch_usage >&2; exit 2; }
[[ "$minutes" =~ ^[0-9]+$ ]] || { echo "branch-idle.sh: --minutes must be a whole number" >&2; exit 2; }

d=${ORCHESTRATE_GIT_DIR:-.}
if [[ -z "$base" ]]; then
  repo=$(orch_repo "$repo")
  base=$(orch_default_branch "$repo" 2>/dev/null) || base=""
  [[ -n "$base" && "$base" != null ]] || { echo "branch-idle.sh: the default branch of $repo could not be read; pass --base" >&2; exit 4; }
fi
git -C "$d" fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" </dev/null >/dev/null 2>&1 || true
git -C "$d" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" >/dev/null 2>&1 ||
  { echo "branch-idle.sh: origin/$base is not in $d" >&2; exit 4; }
label=$head
if [[ -n "$pr" ]]; then
  label="#$pr"
  git -C "$d" fetch -q origin "refs/pull/$pr/head" </dev/null >/dev/null 2>&1 ||
    { echo "branch-idle.sh: refs/pull/$pr/head could not be fetched into $d" >&2; exit 4; }
  head=FETCH_HEAD
fi
sha=$(git -C "$d" rev-parse -q --verify "$head^{commit}" 2>/dev/null) || { echo "branch-idle.sh: $head is not in $d" >&2; exit 4; }

lw=$(orch_last_write "$d" "$sha" "$base") || { echo "branch-idle.sh: the commits of $label could not be listed" >&2; exit 4; }
IFS=$'\t' read -r c t k <<<"$lw"
if [[ "$c" == - ]]; then
  echo "idle $label last-write=none age=- merges-skipped=$k"
  exit 0
fi
age=$((($(orch_now) - t) / 60))
((age >= 0)) || age=0
state=active
((age < minutes)) || state=idle
echo "$state $label last-write=${c:0:9} age=${age}m merges-skipped=$k"
[[ "$state" == idle ]]
