#!/usr/bin/env bash
# The travel guard (#268): a repository ruleset that makes GitHub refuse any merge to the default
# branch without a success `orchestrate/review` commit status posted by the waaagh-bot App. On only
# while traveling, so cloud merges are guarded by GitHub itself even if the orchestrator has a bug;
# off at home, where local merges do not post that status. Run it on the host, as the owner (it
# needs admin on the repository): `on` when the trip starts, `off` on return.
#
# Usage: travel-guard.sh <on|off|status> [--repo OWNER/REPO] [--app-id N]
#   on      create the ruleset "waaagh travel guard" (or set an existing one to active)
#   off     set it to disabled; the ruleset is kept for the next trip
#   status  print `on`, `off` or `absent`, and the ruleset id
#   --app-id  the App that must post the status (default $WAAAGH_APP_ID; needed for `on`)
# Exit: 0 done | 3 the rulesets could not be read or written | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

op=${1:-}
case "$op" in on | off | status) shift ;; -h | --help) orch_usage; exit 0 ;; *) orch_usage >&2; exit 2 ;; esac
repo="" app=${WAAAGH_APP_ID:-}
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --app-id) app=${2:-}; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "travel-guard.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$op" != on || "$app" =~ ^[1-9][0-9]*$ ]] || { echo "travel-guard.sh: on needs --app-id (or WAAAGH_APP_ID)" >&2; exit 2; }
repo=$(orch_repo "$repo")
NAME="waaagh travel guard"
fail() { echo "travel-guard.sh: $1" >&2; exit 3; }

list=$(gh api "repos/$repo/rulesets?includes_parents=false&per_page=100" 2>&1) || fail "rulesets of $repo unreadable: ${list:0:200}"
id=$(jq -r --arg n "$NAME" '[.[]? | select(.name == $n)][0].id // empty' <<<"$list" 2>/dev/null) || fail "rulesets of $repo are not a list"

if [[ "$op" == status ]]; then
  if [[ -z "$id" ]]; then echo absent; exit 0; fi
  one=$(gh api "repos/$repo/rulesets/$id" 2>&1) || fail "ruleset $id unreadable: ${one:0:200}"
  case "$(jq -r .enforcement <<<"$one")" in active) echo "on id=$id" ;; *) echo "off id=$id" ;; esac
  exit 0
fi

enforcement=$([[ "$op" == on ]] && echo active || echo disabled)
if [[ -z "$id" ]]; then
  [[ "$op" == on ]] || { echo "absent (nothing to turn off)"; exit 0; }
  body=$(jq -n --arg n "$NAME" --argjson app "$app" '{name: $n, target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [{type: "required_status_checks", parameters: {strict_required_status_checks_policy: false,
      required_status_checks: [{context: "orchestrate/review", integration_id: $app}]}}]}')
  out=$(gh api -X POST "repos/$repo/rulesets" --input - <<<"$body" 2>&1) || fail "creating the ruleset failed: ${out:0:300}"
  echo "on id=$(jq -r .id <<<"$out") (created)"
  exit 0
fi
body=$(jq -n --arg e "$enforcement" '{enforcement: $e}')
out=$(gh api -X PUT "repos/$repo/rulesets/$id" --input - <<<"$body" 2>&1) || fail "updating ruleset $id failed: ${out:0:300}"
echo "$op id=$id"
