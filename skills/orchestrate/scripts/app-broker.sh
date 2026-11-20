#!/usr/bin/env bash
# Ask the waaagh-bot App broker (the app-broker.yml workflow in the target repository, #268) to act
# as the App: post the `orchestrate/review` commit status on a PR's head, or merge the PR at that
# head once the App's own status there is success. For cloud sessions, which must never hold the
# App's key: this script only dispatches the workflow and reads results; the token is minted and
# used inside the workflow run.
#
# Usage: app-broker.sh status --pr N --sha SHA [--state success|failure|pending|error]
#                             [--description TEXT] [--repo OWNER/REPO]
#        app-broker.sh merge  --pr N --sha SHA [--method squash|merge|rebase] [--repo OWNER/REPO]
#        app-broker.sh check  --sha SHA [--repo OWNER/REPO]
#   status  dispatch op=status: the App posts orchestrate/review=STATE (default success) on SHA,
#           which must still be the PR's head when the run starts
#   merge   dispatch op=merge: the run merges PR N at SHA only if the newest orchestrate/review on
#           SHA is success and was posted by the App itself
#   check   print the newest orchestrate/review on SHA: `<state> by <login> at <time>`, or `absent`
# Dispatching returns before the run does: confirm with `check` (status) or a read of the PR
# (merge) on the next pass. The workflow is app-broker.yml on the default branch; only the actors
# in the repository variable APP_BROKER_ACTORS (default: the owner) may dispatch it.
# Exit: 0 dispatched, or check printed a status | 3 the dispatch was refused, or check could not
#   read the statuses | 4 check: no orchestrate/review on SHA | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

op=${1:-}
case "$op" in status | merge | check) shift ;; -h | --help) orch_usage; exit 0 ;; *) orch_usage >&2; exit 2 ;; esac
repo="" pr="" sha="" state=success description="" method=squash
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --pr) pr=${2:-}; shift 2 ;;
    --sha) sha=${2:-}; shift 2 ;;
    --state) state=${2:-}; shift 2 ;;
    --description) description=${2:-}; shift 2 ;;
    --method) method=${2:-}; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "app-broker.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
bad() { echo "app-broker.sh: $1" >&2; exit 2; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || bad "--sha needs the full 40-character head SHA"
if [[ "$op" != check ]]; then
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || bad "--pr needs a pull request number"
fi
case "$state" in success | failure | pending | error) ;; *) bad "--state must be success, failure, pending or error" ;; esac
case "$method" in squash | merge | rebase) ;; *) bad "--method must be squash, merge or rebase" ;; esac
((${#description} <= 140)) || bad "--description is over 140 characters"
repo=$(orch_repo "$repo")

if [[ "$op" == check ]]; then
  out=$("$here/gh-read.sh" --json -- api --paginate "repos/$repo/commits/$sha/statuses?per_page=100" 2>/dev/null) ||
    { echo "app-broker.sh: statuses of $sha unreadable" >&2; exit 3; }
  line=$(jq -rs '[.[][]? | select(.context == "orchestrate/review")] | sort_by(.updated_at // .created_at) | last
    | if . == null then "absent" else "\(.state) by \(.creator.login // "?") at \(.updated_at // .created_at)" end' <<<"$out")
  echo "$line"
  [[ "$line" != absent ]] || exit 4
  exit 0
fi

branch=$(orch_default_branch "$repo") || { echo "app-broker.sh: default branch of $repo unreadable" >&2; exit 3; }
args=(api -X POST "repos/$repo/actions/workflows/app-broker.yml/dispatches" -f "ref=$branch"
  -f "inputs[op]=$op" -f "inputs[pr]=$pr" -f "inputs[sha]=$sha")
if [[ "$op" == status ]]; then args+=(-f "inputs[state]=$state" -f "inputs[description]=$description")
else args+=(-f "inputs[method]=$method"); fi
if ! err=$(gh "${args[@]}" 2>&1); then
  echo "app-broker.sh: dispatch refused: ${err:0:300}" >&2
  exit 3
fi
echo "dispatched $op pr=$pr sha=${sha:0:12} repo=$repo: confirm with $( [[ "$op" == status ]] && echo "app-broker.sh check --sha $sha" || echo "a read of PR $pr" ) on the next pass"
