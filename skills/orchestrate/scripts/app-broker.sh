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
#        app-broker.sh workflow [--ref REF | --sha SHA]
#   status  dispatch op=status: the App posts orchestrate/review=STATE (default success) on SHA,
#           which must still be the PR's head when the run starts
#   merge   dispatch op=merge: the run merges PR N at SHA only if the newest orchestrate/review on
#           SHA is success and was posted by the App itself
#   check   print the newest orchestrate/review on SHA: `<state> by <login> at <time>`, or `absent`
#   workflow print the app-broker.yml a target repository commits as .github/workflows/app-broker.yml:
#           templates/app-broker.yml with the kaeawc/waaagh actions/app-broker action pinned to the
#           commit REF resolves to, or to --sha as given. REF defaults to the newest release tag
#           (vX.Y.Z, cut by release-tag.yml when the action changes), so the pin reads
#           `@<sha> # vX.Y.Z` and the repository's Dependabot (github-actions) bumps it; main until
#           the first release. WAAAGH_REPO overrides kaeawc/waaagh (a fork).
# The request is a `repository_dispatch` event (type app-broker, the request in client_payload),
# which needs only Contents write: a Claude Code cloud session has that, but not the Actions write a
# workflow_dispatch needs. It runs app-broker.yml from the default branch; only the actors in the
# repository variable APP_BROKER_ACTORS (default: the owner) may start it. Sending returns before
# the run does: confirm with `check` (status) or a read of the PR (merge) on the next pass.
# Exit: 0 dispatched, or check printed a status | 3 the dispatch was refused, or check could not
#   read the statuses | 4 check: no orchestrate/review on SHA | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

op=${1:-}
case "$op" in status | merge | check | workflow) shift ;; -h | --help) orch_usage; exit 0 ;; *) orch_usage >&2; exit 2 ;; esac
repo="" pr="" sha="" state=success description="" method=squash ref=""
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --pr) pr=${2:-}; shift 2 ;;
    --sha) sha=${2:-}; shift 2 ;;
    --state) state=${2:-}; shift 2 ;;
    --description) description=${2:-}; shift 2 ;;
    --method) method=${2:-}; shift 2 ;;
    --ref) ref=${2:-}; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "app-broker.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
bad() { echo "app-broker.sh: $1" >&2; exit 2; }
if [[ "$op" == workflow ]]; then
  src=${WAAAGH_REPO:-kaeawc/waaagh}
  [[ "$src" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || bad "WAAAGH_REPO must be OWNER/REPO"
  [[ -z "$sha" || -z "$ref" ]] || bad "workflow takes --ref or --sha, not both"
  if [[ -z "$sha" && -z "$ref" ]]; then
    # The newest release tag (vX.Y.Z), so the pin's comment is a version Dependabot can bump; main
    # until the first release.
    tags=$("$here/gh-read.sh" -- api "repos/$src/git/matching-refs/tags/v" --jq '.[].ref' 2>/dev/null) ||
      { echo "app-broker.sh: cannot list the release tags of $src" >&2; exit 3; }
    ref=$(sed -n 's|^refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' <<<"$tags" |
      sort -V | tail -1)
  fi
  if [[ -z "$sha" ]]; then
    ref=${ref:-main}
    [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || bad "--ref is not a ref name"
    sha=$("$here/gh-read.sh" -- api "repos/$src/commits/$ref" --jq .sha 2>/dev/null) ||
      { echo "app-broker.sh: cannot resolve $src@$ref" >&2; exit 3; }
  fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || bad "--sha needs a full 40-character commit SHA"
  sed -e "s|kaeawc/waaagh/actions/app-broker@__WAAAGH_SHA__ # __WAAAGH_REF__|$src/actions/app-broker@$sha # ${ref:-pinned}|" \
    "$here/../templates/app-broker.yml"
  exit 0
fi
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

body=$(jq -cn --arg op "$op" --arg pr "$pr" --arg sha "$sha" --arg state "$state" --arg d "$description" --arg m "$method" '
  {event_type: "app-broker", client_payload: ({op: $op, pr: $pr, sha: $sha}
    + (if $op == "status" then {state: $state, description: $d} else {method: $m} end))}')
if ! err=$(gh api -X POST "repos/$repo/dispatches" --input - <<<"$body" 2>&1); then
  echo "app-broker.sh: dispatch refused: ${err:0:300}" >&2
  exit 3
fi
echo "dispatched $op pr=$pr sha=${sha:0:12} repo=$repo: confirm with $( [[ "$op" == status ]] && echo "app-broker.sh check --sha $sha" || echo "a read of PR $pr" ) on the next pass"
