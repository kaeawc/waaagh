#!/usr/bin/env bash
# Reply on ONE pull request review thread (optional) and resolve it, then read it back. The
# building block for every role that settles a thread: later-round follow-ups (review-followup.sh)
# and threads the orchestrator answered or fixed.
#
# Usage: thread-resolve.sh --thread ID [--pr N] [--reply TEXT] [--repo OWNER/REPO] [--dry-run]
#   --thread  the review thread's GraphQL node id (PRRT_...; `review-followup.sh list` prints it)
#   --pr      refuse unless the thread belongs to this pull request
#   --reply   posted once as a thread reply before resolving; it carries a hidden marker keyed by
#             its text, so a rerun never posts the same reply twice
# Prints one line: `resolved <id> pr=<n>`, `unchanged <id> pr=<n>` (already resolved, reply
# already there), or `would resolve <id> pr=<n> [reply]` with --dry-run.
# Exit: 0 ok | 2 usage | 3 refused (not a review thread, or not on --pr) | 4 the thread could not
#       be read | 5 a write failed (rerun finishes it) | 9 outcome unknown (no readback).
# Appends one line per completed resolve to <state dir>/thread-actions.log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

repo="" thread="" pr="" reply="" dry=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --thread) thread=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --reply) reply=$2; shift 2 ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "thread-resolve.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$thread" =~ ^[A-Za-z0-9_=-]+$ ]] && [[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || { sed -n '2,15p' "$0" >&2; exit 2; }
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
marker=""
if [[ -n "$reply" ]]; then
  marker="<!-- waaagh:reply thread=$thread key=$(printf '%s' "$reply" | git hash-object --stdin | cut -c1-12) -->"
fi

# shellcheck disable=SC2016  # GraphQL variables, not shell expansions
view() {
  "$here/gh-read.sh" --json --tries 3 -- api graphql -F id="$thread" -f query='
    query($id:ID!){node(id:$id){__typename ... on PullRequestReviewThread{isResolved
      pullRequest{number} comments(last:100){nodes{body}}}}}' 2>/dev/null
}
# state_of JSON -> "<resolved true|false> <pr> <reply present yes|no>", or "" when not a thread.
state_of() {
  jq -r --arg m "$marker" '.data.node // {} | select(.__typename == "PullRequestReviewThread")
    | [.isResolved, .pullRequest.number,
       (if $m == "" or any(.comments.nodes[]?; .body | contains($m)) then "yes" else "no" end)]
    | map(tostring) | join(" ")' <<<"$1"
}

info=$(view) || { echo "thread-resolve: thread $thread could not be read" >&2; exit 4; }
st=$(state_of "$info")
[[ -n "$st" ]] || { echo "refused: $thread is not a pull request review thread"; exit 3; }
read -r resolved num has_reply <<<"$st"
[[ -z "$pr" || "$num" == "$pr" ]] || { echo "refused: thread $thread is on PR #$num, not #$pr"; exit 3; }
if [[ "$resolved" == true && "$has_reply" == yes ]]; then echo "unchanged $thread pr=$num"; exit 0; fi
if [[ "$dry" == yes ]]; then
  echo "would resolve $thread pr=$num${marker:+$([[ "$has_reply" == no ]] && echo " reply")}"; exit 0
fi

rc=0
if [[ "$has_reply" == no ]]; then
  # shellcheck disable=SC2016
  gh api graphql -F t="$thread" -f b="$reply

$marker" -f query='mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(
    input:{pullRequestReviewThreadId:$t,body:$b}){comment{id}}}' >/dev/null 2>&1 || rc=5
fi
if [[ "$resolved" != true ]] && ((rc == 0)); then
  # shellcheck disable=SC2016
  gh api graphql -F t="$thread" -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){
    thread{isResolved}}}' >/dev/null 2>&1 || rc=5
fi

after=$(view) || { echo "unverified: thread $thread written but not read back; rerun to reconcile"; exit 9; }
read -r resolved num has_reply <<<"$(state_of "$after")"
if [[ "$resolved" == true && "$has_reply" == yes ]]; then
  printf '%s\tresolve\tpr=%s\tthread=%s%s\n' "$(orch_iso "$(orch_now)")" "$num" "$thread" \
    "${reply:+	reply=${reply%%$'\n'*}}" >>"$state/thread-actions.log"
  echo "resolved $thread pr=$num"
else
  echo "thread $thread incomplete (resolved=$resolved reply=$has_reply; exit $rc); rerun to finish"; exit 5
fi
