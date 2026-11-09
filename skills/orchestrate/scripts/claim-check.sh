#!/usr/bin/env bash
# Confirm a delegated claim from the source of truth before relaying it to the owner. A lane's
# "merged", "closed", "verified" or "no device check needed" is a claim until one cheap read of the
# PR, the issue or the evidence comment says so.
#
# Usage: claim-check.sh merged --pr N [--repo OWNER/REPO]
#        claim-check.sh open (--pr N | --issue N) [--repo OWNER/REPO]
#        claim-check.sh closed --issue N [--reason completed|not_planned] [--repo OWNER/REPO]
#        claim-check.sh evidence (--pr N | --issue N) --match TEXT [--since ISO] [--repo OWNER/REPO]
#        claim-check.sh device-clear --pr N [--repo OWNER/REPO]
#   merged        the PR's state is MERGED (prints the merge commit and time)
#   open          the PR or issue is still open
#   closed        the issue is closed (with that state reason, when --reason is given)
#   evidence      a comment on the PR or issue contains TEXT (a fixed string), at or after --since;
#                 prints the newest such comment's URL
#   device-clear  "no device check needed" or "device verified": device-recheck.sh check is clear
# One line: `confirmed: ...` or `refuted: ...` (relay the source's state, not the claim).
# Exit: 0 confirmed | 2 usage | 3 refuted | 4 unverified (a read failed): do not relay the claim
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  merged | open | closed | evidence | device-clear) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" pr="" issue="" reason="" match="" since=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --match) match=$2; shift 2 ;;
    --since) since=$2; shift 2 ;;
    *) echo "claim-check.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] && [[ -z "$issue" || "$issue" =~ ^[0-9]+$ ]] || usage
case "$cmd" in
  merged | device-clear) [[ -n "$pr" && -z "$issue" ]] || usage ;;
  closed) [[ -n "$issue" && -z "$pr" ]] && [[ -z "$reason" || "$reason" =~ ^(completed|not_planned)$ ]] || usage ;;
  open) [[ -n "$pr" && -z "$issue" || -z "$pr" && -n "$issue" ]] || usage ;;
  evidence)
    [[ -n "$pr" && -z "$issue" || -z "$pr" && -n "$issue" ]] && [[ -n "$match" ]] || usage
    [[ -z "$since" || "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || usage ;;
esac
repo=$(orch_repo "$repo")

if [[ "$cmd" == device-clear ]]; then
  rc=0
  out=$("$here/device-recheck.sh" check --repo "$repo" --pr "$pr") || rc=$?
  case "$rc" in
    0) echo "confirmed: ${out#clear: }"; exit 0 ;;
    3) echo "refuted: ${out#held: }"; exit 3 ;;
    *) echo "unverified: ${out#unverified: }"; exit 4 ;;
  esac
fi

n=${pr:-$issue}
what=$([[ -n "$pr" ]] && echo PR || echo issue)
case "$cmd" in
  merged)
    j=$(orch_read_retry 3 gh pr view "$pr" --repo "$repo" --json state,mergedAt,mergeCommit) &&
      st=$(jq -er .state <<<"$j") || { echo "unverified: PR $pr could not be read"; exit 4; }
    if [[ "$st" == MERGED ]]; then
      echo "confirmed: PR $pr merged $(jq -r '.mergedAt // "-"' <<<"$j") as $(jq -r '.mergeCommit.oid // "-"' <<<"$j" | cut -c1-9)"
      exit 0
    fi
    echo "refuted: PR $pr is $st, not merged"; exit 3 ;;
  open | closed)
    j=$(orch_read_retry 3 gh api "repos/$repo/issues/$n") &&
      st=$(jq -er .state <<<"$j") || { echo "unverified: $what $n could not be read"; exit 4; }
    sr=$(jq -r '.state_reason // "-"' <<<"$j")
    if [[ "$cmd" == open ]]; then
      if [[ "$st" == open ]]; then echo "confirmed: $what $n is open"; exit 0; fi
      echo "refuted: $what $n is closed ($sr)"; exit 3
    fi
    if [[ "$st" != closed ]]; then echo "refuted: issue $n is open"; exit 3; fi
    if [[ -n "$reason" && "$sr" != "$reason" ]]; then echo "refuted: issue $n is closed as $sr, not $reason"; exit 3; fi
    echo "confirmed: issue $n is closed ($sr) at $(jq -r '.closed_at // "-"' <<<"$j")"; exit 0 ;;
  evidence)
    j=$(orch_read_retry 3 gh api --paginate "repos/$repo/issues/$n/comments?per_page=100") &&
      hit=$(jq -s -r --arg m "$match" --arg s "$since" '[.[] | if type == "array" then .[] else . end
        | select((.body // "") | contains($m)) | select($s == "" or .created_at >= $s)]
        | sort_by(.created_at) | last | if . == null then "" else "\(.html_url) \(.created_at)" end' <<<"$j") ||
      { echo "unverified: the comments of $what $n could not be read"; exit 4; }
    if [[ -n "$hit" ]]; then echo "confirmed: $what $n has the evidence comment ${hit% *} (${hit##* })"; exit 0; fi
    echo "refuted: no comment on $what $n contains \"$match\"${since:+ since $since}"; exit 3 ;;
esac
