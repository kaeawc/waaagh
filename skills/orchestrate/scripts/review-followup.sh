#!/usr/bin/env bash
# One review round per PR: review threads that arrive after a PR's first review round become
# follow-up issues instead of blocking its merge (pr-ready.sh counts every unresolved thread).
#
# Usage: review-followup.sh list --pr N [--round-end ISO] [--repo OWNER/REPO]
#        review-followup.sh file --pr N --thread ID (--title TEXT | --append M) [--note TEXT]
#                                [--route cloud-ready|none] [--repo OWNER/REPO] [--dry-run]
#   list  read-only. One TSV row per unresolved, current (not outdated) review thread:
#           class  thread-id  path:line  reviewer  url  summary
#         class: first (part of the first review round) | later (started after it) | own (started
#         by the PR author). The first round ends when the earliest review by anyone other than
#         the PR author was submitted; --round-end overrides that time. Last line on stderr:
#         "pr=<n> unresolved=<n> first=<n> later=<n> own=<n> round-end=<iso|none>".
#   file  settle ONE thread as a follow-up: open a new issue (--title) or add the finding to an
#         open issue with the same root cause (--append M), reply "follow-up #M" on the thread and
#         resolve it (thread-resolve.sh), then put the issue in the cloud dispatch queue
#         (issue-route.sh set --route cloud-ready). An appended issue that already has a route
#         keeps it; --route none skips routing. The issue text quotes the finding and links the
#         thread; --note adds the filer's own line (e.g. the shared root cause).
# A new issue is journaled (<state dir>/ops/followup-<thread>.json) and carries a hidden marker;
# a rerun finds it (journal, else the 100 newest issues) instead of filing it twice, and an append
# is skipped when the issue already has that thread's marker.
# Exit: 0 ok (or would) | 2 usage | 3 refused (thread not on the PR, or --append issue not open) |
#       4 a read failed | 5 a write failed (rerun finishes it) | 9 outcome unknown (rerun reconciles).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority low

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" pr="" round_end="" thread="" title="" append="" note="" route=cloud-ready dry=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --round-end) round_end=$2; shift 2 ;;
    --thread) thread=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --append) append=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    --route) route=$2; shift 2 ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "review-followup.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in list | file) ;; -h | --help) orch_usage; exit 0 ;; *) usage ;; esac
[[ "$pr" =~ ^[0-9]+$ ]] || usage
repo=$(orch_repo "$repo")
ghr() { "$here/gh-read.sh" --json --tries 3 -- "$@" 2>/dev/null; }

case "$cmd" in
  list)
    [[ -z "$round_end" || "$round_end" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || usage
    q='query($owner:String!,$name:String!,$pr:Int!,$cursor:String){repository(owner:$owner,name:$name){
      pullRequest(number:$pr){author{login} reviews(first:100){nodes{author{login} state submittedAt}}
      reviewThreads(first:100,after:$cursor){pageInfo{hasNextPage endCursor}
      nodes{id isResolved isOutdated path line originalLine
      comments(first:1){nodes{author{login} createdAt url body}}}}}}}'
    pages="[]" cursor="" first=yes
    while [[ "$first" == yes || -n "$cursor" ]]; do
      first=no
      args=(-F owner="${repo%%/*}" -F name="${repo##*/}" -F pr="$pr" -f query="$q")
      [[ -z "$cursor" ]] || args+=(-f cursor="$cursor")
      page=$(ghr api graphql "${args[@]}") &&
        jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' >/dev/null 2>&1 <<<"$page" ||
        { echo "review-followup: review threads of PR $pr could not be read" >&2; exit 4; }
      pages=$(jq -c --slurpfile p <(printf '%s\n' "$page") '. + [$p[0].data.repository.pullRequest]' <<<"$pages")
      cursor=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo
        | if .hasNextPage then (.endCursor // "") else "" end' <<<"$page")
    done
    jq -r --arg override "$round_end" --arg pr "$pr" '
      .[0].author.login as $me
      | (if $override != "" then $override else
           ([.[0].reviews.nodes[] | select(.author.login != $me and .submittedAt != null) | .submittedAt]
            | min // "") end) as $end
      | [.[].reviewThreads.nodes[] | select((.isResolved | not) and (.isOutdated | not))
         | .comments.nodes[0] as $c
         | {class: (if $c.author.login == $me then "own" elif $end == "" or $c.createdAt <= $end then "first"
                    else "later" end),
            id, at: "\(.path):\(.line // .originalLine // "-")", who: ($c.author.login // "-"), url: ($c.url // "-"),
            sum: ($c.body // "" | gsub("<[^>]*>|!\\[[^]]*\\]\\([^)]*\\)|\\*\\*"; "") | split("\n")
                  | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")) | (first // "-") | gsub("\t"; " ") | .[0:120])}]
      | (.[] | [.class, .id, .at, .who, .url, .sum] | @tsv),
        ("pr=\($pr) unresolved=\(length) first=\(map(select(.class == "first")) | length) later=\(map(select(.class == "later")) | length) own=\(map(select(.class == "own")) | length) round-end=\(if $end == "" then "none" else $end end)"
         | "SUMMARY\t" + .)' <<<"$pages" | awk -F'\t' '$1 == "SUMMARY" { print $2 > "/dev/stderr"; next } { print }'
    ;;

  file)
    [[ "$thread" =~ ^[A-Za-z0-9_=-]+$ ]] || usage
    [[ -n "$title" && -z "$append" ]] || [[ -z "$title" && "$append" =~ ^[0-9]+$ ]] || usage
    [[ "$route" == cloud-ready || "$route" == none ]] || usage
    state=$(orch_state_dir "$repo")
    refuse() { echo "refused: $*"; exit 3; }
    marker="<!-- waaagh:followup pr=$pr thread=$thread -->"
    journal="$state/ops/followup-$thread.json"

    # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
    t=$(ghr api graphql -F id="$thread" -f query='query($id:ID!){node(id:$id){__typename
      ... on PullRequestReviewThread{path line originalLine pullRequest{number title}
      comments(first:1){nodes{author{login} url body}}}}}') ||
      { echo "review-followup: thread $thread could not be read" >&2; exit 4; }
    [[ "$(jq -r '.data.node.__typename // ""' <<<"$t")" == PullRequestReviewThread ]] ||
      refuse "$thread is not a pull request review thread"
    [[ "$(jq -r .data.node.pullRequest.number <<<"$t")" == "$pr" ]] || refuse "thread $thread is not on PR #$pr"
    finding=$(jq -r --arg pr "$pr" '.data.node | .comments.nodes[0] as $c
      | "- Thread: \($c.url // "-")\n- File: `\(.path):\(.line // .originalLine // "-")`\n- Reviewer: `\($c.author.login // "-")`\n\n"
        + ($c.body // "" | split("\n") | map("> " + .) | join("\n"))' <<<"$t")
    pr_title=$(jq -r .data.node.pullRequest.title <<<"$t")
    issue="" verb=""

    if [[ -n "$append" ]]; then
      info=$(ghr issue view "$append" --repo "$repo" --json state,labels,comments) ||
        { echo "review-followup: issue $append could not be read" >&2; exit 4; }
      [[ "$(jq -r .state <<<"$info")" == OPEN ]] || refuse "issue $append is not open"
      issue=$append verb=appended
      if jq -e --arg m "$marker" 'any(.comments[]?; .body | contains($m))' >/dev/null <<<"$info"; then
        verb=already-appended
      elif [[ "$dry" == yes ]]; then
        echo "would append thread $thread to #$append"
      else
        gh issue comment "$append" --repo "$repo" --body "Same root cause, from a later-round review thread on #$pr ($pr_title).

$finding
${note:+
$note
}
$marker" >/dev/null 2>&1 || { echo "review-followup: comment on issue $append failed; rerun to finish" >&2; exit 5; }
      fi
    else
      [[ -f "$journal" ]] && issue=$(jq -r '.issue // ""' "$journal")
      if [[ -z "$issue" ]]; then   # no journal: the marker on a recent issue proves an earlier filing
        recent=$(ghr issue list --repo "$repo" --state all --limit 100 --json number,body) ||
          { echo "review-followup: recent issues could not be read" >&2; exit 4; }
        issue=$(jq -r --arg m "$marker" '[.[] | select(.body | contains($m)) | .number] | min // ""' <<<"$recent")
      fi
      verb=already-filed
      if [[ -z "$issue" ]]; then
        verb=filed
        if [[ "$dry" == yes ]]; then
          echo "would file \"$title\" for thread $thread"
        else
          orch_journal "$journal" "$(jq -cn --arg p "$pr" --arg t "$thread" '{pr: $p, thread: $t, state: "intent"}')"
          out=$(gh issue create --repo "$repo" --title "$title" --body "Follow-up from a later-round review thread on #$pr ($pr_title). The PR keeps its one review round; this finding is tracked here instead of blocking the merge.

$finding
${note:+
$note
}
$marker" 2>/dev/null) || { echo "unverified: issue create for thread $thread failed or was lost; rerun to reconcile"; exit 9; }
          issue=$(sed -nE 's#.*/issues/([0-9]+).*#\1#p' <<<"$out" | awk 'NR == 1')
          [[ -n "$issue" ]] || { echo "unverified: issue create for thread $thread printed no issue; rerun to reconcile"; exit 9; }
        fi
      fi
      [[ -z "$issue" || "$dry" == yes ]] ||
        orch_journal "$journal" "$(jq -cn --arg p "$pr" --arg t "$thread" --argjson i "$issue" '{pr: $p, thread: $t, issue: $i, state: "filed"}')"
    fi
    [[ -z "$issue" ]] || echo "$verb #$issue pr=$pr thread=$thread"

    if [[ "$dry" == yes ]]; then
      echo "would reply \"follow-up #${issue:-N}\" on $thread and resolve it${route:+; route: $route}"
      exit 0
    fi
    rc=0
    "$here/thread-resolve.sh" --repo "$repo" --pr "$pr" --thread "$thread" --reply "follow-up #$issue" || rc=$?
    routed=none
    if [[ "$route" == cloud-ready ]]; then
      have=""
      if [[ -n "$append" ]]; then
        have=$(jq -r '[.labels[].name | select(. == "cloud-ready" or startswith("needs-local:"))] | join(",")' <<<"$info")
      fi
      if [[ -n "$have" ]]; then
        routed="$have (kept)"
      elif "$here/issue-route.sh" set --repo "$repo" --issue "$issue" --route cloud-ready; then
        routed=cloud-ready
      else
        routed=failed; ((rc)) || rc=5
      fi
    fi
    jstate=partial; ((rc)) || jstate="done"
    [[ -n "$append" ]] || orch_journal "$journal" "$(jq -c --arg s "$jstate" '.state = $s' "$journal")"
    printf '%s\tfollowup\tpr=%s\tthread=%s\tissue=%s\t%s\troute=%s\n' "$(orch_iso "$(orch_now)")" "$pr" "$thread" \
      "$issue" "$verb" "$routed" >>"$state/thread-actions.log"
    echo "followup pr=$pr thread=$thread issue=#$issue route=$routed$([[ $rc == 0 ]] || echo " incomplete; rerun to finish")"
    exit "$rc"
    ;;
esac
