#!/usr/bin/env bash
# One writer per PR branch across cloud sessions (#214). The session that opened a PR stays a live
# writer while the PR is open: "idle" is not "done", it wakes on the PR's CI, review and bot events
# and can push again. Once a repair session is dispatched to the PR, the original must stop
# writing. The orchestrator says so with one marker comment on the PR, which the implement brief
# reads before every push; the triage tick then looks for a second writer it can see.
#
# Usage: repair-writer.sh mark  --pr P --session ID [--issue N] [--repo OWNER/REPO]
#        repair-writer.sh check [--pr P] [--repo OWNER/REPO]
#   mark   post the repairing marker on PR P once (cloud-dispatch.sh record --kind repair runs it):
#          a comment starting "REPAIR-START session ID:" that carries the hidden key
#          <!-- waaagh:repairing pr=P session=ID -->. The PR's comments are read first (REST
#          through gh-read.sh); when one already carries that key nothing is posted, so a rerun is
#          safe. Prints "marked PR #P session ID" or "already marked PR #P session ID".
#   check  for each repair in flight (review-ledger.sh inflight; only PR P with --pr), read the
#          PR's commits and issue events (REST through gh-read.sh, two reads per PR) and look for
#          a second writer since the dispatch. Prints per PR:
#            two-writers #P session:ID since:ISO writers=a,b   commits committed since then carry
#                                                             more than one writer
#            force-push #P session:ID at:ISO                  the branch was force-pushed since
#            clear #P session:ID commits=K                    neither
#            unknown #P session:ID <what>                     a read failed (exit 7, after the rest)
#          A commit's writer is its Claude-Session trailer when it has one, else its author email.
#          GitHub-made commits (committer noreply@github.com, e.g. update-branch merges) are left
#          out. What it cannot see: two sessions committing under one identity with no session
#          trailer (the cloud briefs forbid attribution lines) look like one writer, and a commit
#          made before the dispatch but pushed after it is not counted: commit metadata names no
#          pusher. The marker and the brief's check before each push are the guard; this check
#          reports only what the metadata shows.
# Exit: 0 ok | 2 usage | 5 the marker could not be posted | 7 a read failed (mark: the PR's
#       comments, so nothing was posted; check: a PR's commits or events)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  mark | check) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" pr="" session="" issue=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=${2#\#}; shift 2 ;;
    --session) session=$2; shift 2 ;;
    --issue) issue=${2#\#}; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "repair-writer.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || usage
[[ -z "$issue" || "$issue" =~ ^[0-9]+$ ]] || usage
[[ "$session" =~ ^[A-Za-z0-9_.:-]*$ ]] || { echo "repair-writer.sh: --session must be one word" >&2; exit 2; }
if [[ "$cmd" == mark ]]; then
  [[ -n "$pr" && -n "$session" ]] || { echo "repair-writer.sh: mark needs --pr and --session" >&2; exit 2; }
fi
repo=$(orch_repo "$repo")

# pages URL: every page of a REST list, as one JSON array; fails when a read or a page is bad.
pages() {
  local out
  out=$(orch_read_retry 3 gh api --paginate "$1" </dev/null) || return 1
  jq -cs 'if all(.[]; type == "array") then add // [] else error("not a list") end' <<<"$out" 2>/dev/null
}

if [[ "$cmd" == mark ]]; then
  key="<!-- waaagh:repairing pr=$pr session=$session -->"
  com=$(pages "repos/$repo/issues/$pr/comments?per_page=100") ||
    { echo "repair-writer.sh: PR #$pr's comments could not be read; no marker posted (rerun)" >&2; exit 7; }
  if jq -e --arg k "$key" 'any(.[]; (.body // "") | contains($k))' >/dev/null <<<"$com"; then
    echo "already marked PR #$pr session $session"; exit 0
  fi
  branch="this PR's branch"
  [[ -z "$issue" ]] || branch="branch work/$issue-auto (issue #$issue)"
  body="REPAIR-START session $session: a repair session now owns $branch. Any other session, including the one that opened this PR, must not push to it again: stop, even when CI, review or bot events on this PR wake you.

$key"
  gh api -X POST "repos/$repo/issues/$pr/comments" -f body="$body" >/dev/null 2>&1 ||
    { echo "repair-writer.sh: could not post the REPAIR-START marker on PR #$pr; rerun repair-writer.sh mark --pr $pr --session $session" >&2; exit 5; }
  echo "marked PR #$pr session $session"
  exit 0
fi

# check
fl=$("$here/review-ledger.sh" inflight --repo "$repo" ${pr:+--pr "$pr"}) ||
  { echo "repair-writer.sh: the review ledger could not be read" >&2; exit 7; }
rc=0
while IFS=$'\t' read -r p s since; do
  [[ -n "$p" ]] || continue
  commits=$(pages "repos/$repo/pulls/$p/commits?per_page=100") ||
    { echo "unknown #$p session:$s commits unreadable"; rc=7; continue; }
  events=$(pages "repos/$repo/issues/$p/events?per_page=100") ||
    { echo "unknown #$p session:$s events unreadable"; rc=7; continue; }
  jq -rn --slurpfile c <(printf "%s\n" "$commits") --slurpfile e <(printf "%s\n" "$events") --arg p "$p" --arg s "$s" --arg t "$since" '
    def writer: ([(.commit.message // "") | match("(?m)^Claude-Session:[ \t]*(\\S+)").captures[0].string] | first) as $w
      | if $w then "session:" + ($w | sub(".*/"; "")) else (.commit.author.email // .author.login // "unknown") end;
    [$c[0][] | select((.commit.committer.email // "") != "noreply@github.com")
      | select((.commit.committer.date // "") >= $t)] as $since
    | ([$since[] | writer] | unique) as $w
    | [$e[0][] | select(.event == "head_ref_force_pushed" and (.created_at // "") >= $t) | .created_at] as $f
    | (if ($w | length) > 1 then "two-writers #\($p) session:\($s) since:\($t) writers=\($w | join(","))" else empty end),
      ($f[] | "force-push #\($p) session:\($s) at:\(.)"),
      (if ($w | length) <= 1 and ($f | length) == 0 then "clear #\($p) session:\($s) commits=\($since | length)" else empty end)'
done <<<"$fl"
exit "$rc"
