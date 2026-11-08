# The one gh stub for the REST path (#108, #109, #123), shared by every suite that replays its
# GraphQL scenarios without GraphQL (issues-rest.bats, pr-rest.bats, gh-api.bats). rest_wrap puts it
# in front of the suite's own GraphQL-shaped stub ($BATS_TEST_TMPDIR/bin/gh: stub_gh_router, or a
# suite's inline one). While $FX/rest-mode exists it answers like a Claude Code cloud session: every
# `gh pr ...`, `gh issue ...` and `gh api graphql` call is refused with the real HTTP 403 text (as
# the real gh prints it: `issue list --label` without the "HTTP 403:" prefix), and the REST routes
# are served from the fixtures the GraphQL stub serves. Without $FX/rest-mode every call goes
# straight to the GraphQL stub. Calls in REST mode are logged to $REST_CALLS (default
# $FX/rest-calls).
# PR side: $FX/prs.json (the `gh pr list --json` rows, plus optional `files` and `reviews`),
# $FX/view-<n>.json, and review threads read through the GraphQL stub itself (one PR per query,
# then its cursors). $FX/thread-shape: graphql (default: isResolved/isOutdated) | snake
# (resolved/outdated) | wrapped ({"threads": [...]}). $FX/rest-fails-<sha>: that head's check-runs
# answer HTTP 404.
# Full thread nodes (thread-sweep.sh's fixtures: id, starter, latest) are served as threads tied to
# their first comment (comments[0].databaseId; snake: root_comment_id), with pulls/<n>/comments,
# pulls/<n>/commits and pulls/comments/<id> made from the same nodes (#136), and the two REST
# thread writes: POST .../comments/<id>/replies (appended to $FX/rest-replies) and POST
# .../ccr/comments/<id>/resolve (makes $FX/rest-resolved-<id>; $FX/rest-resolve-fails answers 403),
# both logged to $FX/writes.
# Issue side (REST-shaped fixtures): $FX/issues.json (/repos/o/r/issues items, pull requests
# included), $FX/merged.json (search items), $FX/comments-<n>.json, and $FX/pulls.json, which, when
# it exists, is served as the open pulls instead of prs.json (`_closing` dropped).

rest_wrap() {
  mkdir -p "$BATS_TEST_TMPDIR/restbin"
  cat >"$BATS_TEST_TMPDIR/restbin/gh" <<'STUB'
#!/usr/bin/env bash
real="$BATS_TEST_TMPDIR/bin/gh"
[ -f "$FX/rest-mode" ] || exec "$real" "$@"
echo "$*" >>"${REST_CALLS:-$FX/rest-calls}"
a="$*"; a=${a% --include}; a=${a/api --paginate /api }
nf() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
param() { printf '%s\n' "$a" | sed -nE "s/.*[?&]$1=([^&]*).*/\1/p"; }
decode() { printf '%b' "${1//%/\\x}"; }
# shellcheck disable=SC2016
REST='def rest: {number, title: (.title // ""), body: (.body // ""),
    state: (if .state == "MERGED" then "closed" else ((.state // "OPEN") | ascii_downcase) end),
    merged_at: (if .state == "MERGED" then "2026-09-27T00:00:00Z" else null end),
    user: ((.author.login // "") as $l | if ($l | startswith("app/")) then {login: ($l[4:] + "[bot]"), type: "Bot"}
           else {login: $l, type: "User"} end),
    draft: (.isDraft // false), base: {ref: .baseRefName, repo: {full_name: "o/r"}},
    head: {ref: .headRefName, sha: .headRefOid, repo: (if .isCrossRepository then {full_name: "fork/r"} else {full_name: "o/r"} end)},
    labels: (.labels // []), created_at: .createdAt, updated_at: .updatedAt, html_url: .url,
    mergeable: (if .mergeable == "MERGEABLE" then true elif .mergeable == "CONFLICTING" then false else null end)};
  def status_item: .__typename == "StatusContext" or has("context");
  def rollup($sha): (map(select(.headRefOid == $sha)) | first // {}) | (.statusCheckRollup // []);'
# Full thread nodes as REST review comments: thread i of PR n starts with comment (n*100+i+1)*10;
# its replies follow it (fillers by "someone" between the first comment and the latest).
# shellcheck disable=SC2016
THREADS='def roots($n): to_entries | map(.value + {_root: (($n * 100 + .key + 1) * 10)});
  def comments: ._root as $r | (.latest.totalCount // 1) as $t
    | ([{id: $r, in_reply_to_id: null, user: {login: .starter.nodes[0].author.login}, html_url: .starter.nodes[0].url,
         body: (if $t == 1 then .latest.nodes[0].body else "the finding" end)}]
       + [range(1; $t - 1) | {id: ($r + .), in_reply_to_id: $r, user: {login: "someone"}, body: "a reply"}]
       + (if $t > 1 then [{id: ($r + $t - 1), in_reply_to_id: $r, user: {login: .latest.nodes[0].author.login},
           body: .latest.nodes[0].body}] else [] end))
    | to_entries | map(.value + {created_at: "2026-01-01T00:00:\(.key + 10)Z"}) | .[];'
pr_node() { # N -> the GraphQL stub's pull request node for PR N (commits and review threads)
  local q='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){'
  q+=" p$1: pullRequest(number:$1){commits(last:100){nodes{commit{oid}}} reviewThreads(first:100){nodes{id isResolved isOutdated}}}}}"
  "$real" api graphql -F owner=o -F name=r -f query="$q" 2>/dev/null | jq -ce --arg k "p$1" '.data.repository[$k] // empty'
}
rest_replies() { cat "$FX/rest-replies" 2>/dev/null || true; }
case "$a" in
  "issue list "*--label*)
    echo 'non-200 OK status code: 403 Forbidden body: "{\"message\":\"GitHub GraphQL is not available from Claude Code sessions; use the REST API\"}"' >&2
    exit 1 ;;
  "pr "* | "issue "* | "api graphql"*)
    echo "HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (https://api.github.com/graphql)" >&2
    exit 1 ;;
  "api repos/o/r/issues?"* | "api repos/o/r/pulls?"* | "api search/issues?"*)
    page=$(param page); per=$(param per_page); l=$(decode "$(param labels)")
    case "$a" in
      "api repos/o/r/issues"*) src=$(jq -c . "$FX/issues.json") ;;
      "api search/"*) src=$(jq -c . "$FX/merged.json") ;;
      *) if [ -f "$FX/pulls.json" ]; then src=$(jq -c 'map(del(._closing))' "$FX/pulls.json")
         else src=$(jq -c "$REST"'map(rest | del(.mergeable))' "$FX/prs.json") || exit 1; fi ;;
    esac
    jq -c --arg l "$l" --argjson page "${page:-1}" --argjson per "${per:-30}" --arg s "$a" '
      [.[] | select($l == "" or any(.labels[]; .name == $l))] | .[($page - 1) * $per:$page * $per]
      | if ($s | startswith("api search/")) then {total_count: length, items: .} else . end' <<<"$src" ;;
  "api repos/o/r/issues/"*/comments*)
    n=${a#api repos/o/r/issues/}; n=${n%%/*}
    cat "$FX/comments-$n.json" 2>/dev/null || echo '[]' ;;
  "api repos/o/r/pulls/"*/ccr/review_threads)
    n=${a#api repos/o/r/pulls/}; n=${n%%/*}
    q='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){'
    q+=" p$n: pullRequest(number:$n){reviewThreads(first:100){pageInfo{hasNextPage endCursor} nodes{isResolved isOutdated}}}}}"
    page=$("$real" api graphql -F owner=o -F name=r -f query="$q" 2>/dev/null) || nf
    conn=$(jq -c --arg k "p$n" '.data.repository[$k].reviewThreads // empty' <<<"$page" 2>/dev/null) || nf
    [ -n "$conn" ] || nf
    out=""
    while :; do
      out+=$(jq -c '.nodes' <<<"$conn")$'\n'
      [ "$(jq -r '.pageInfo.hasNextPage' <<<"$conn")" = true ] || break
      c=$(jq -r '.pageInfo.endCursor // empty' <<<"$conn"); [ -n "$c" ] || nf
      page=$("$real" api graphql -F owner=o -F name=r -F pr="$n" -f cursor="$c" -f query='query($owner:String!,$name:String!,$pr:Int!,$cursor:String!){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{isResolved isOutdated}}}}}' 2>/dev/null) || nf
      conn=$(jq -c '.data.repository.pullRequest.reviewThreads // empty' <<<"$page" 2>/dev/null) || nf
      [ -n "$conn" ] || nf
    done
    if printf '%s' "$out" | jq -se 'add | any(.[]; has("latest"))' >/dev/null 2>&1; then
      # Full thread nodes (thread-sweep fixtures): one page, each thread tied to its first comment.
      printf '%s' "$out" | jq -sc --argjson n "$n" --arg shape "$(cat "$FX/thread-shape" 2>/dev/null)" \
        --argjson done "$(cd "$FX" && ls rest-resolved-* 2>/dev/null | sed 's/rest-resolved-//' | jq -sR 'split("\n") | map(select(length > 0) | tonumber)')" "$THREADS"'
        add | roots($n) | map((.isResolved or (._root as $r | $done | index($r) != null)) as $res
          | if $shape == "snake" then {resolved: $res, outdated: .isOutdated, root_comment_id: (._root | tostring)}
            else {id, isResolved: $res, isOutdated, comments: [{databaseId: ._root}]} end)
        | if $shape == "wrapped" then {threads: .} else . end'
    else
      case "$(cat "$FX/thread-shape" 2>/dev/null)" in
        snake) printf '%s' "$out" | jq -c 'map({resolved: .isResolved, outdated: .isOutdated, id: "t"})' ;;
        wrapped) printf '%s' "$out" | jq -c '{threads: .}' ;;
        *) printf '%s' "$out" ;;
      esac
    fi ;;
  "api repos/o/r/pulls/"*/comments\?*)
    n=${a#api repos/o/r/pulls/}; n=${n%%/*}
    pr_node "$n" | jq -c --argjson n "$n" --slurpfile rp <(rest_replies) "$THREADS"'
      [(.reviewThreads.nodes // []) | roots($n)[] | comments] + [$rp[] | select(._pr == $n) | del(._pr)]' ;;
  "api repos/o/r/pulls/"*/commits*)
    n=${a#api repos/o/r/pulls/}; n=${n%%/*}
    pr_node "$n" | jq -c '[(.commits.nodes // [])[] | {sha: .commit.oid}]' ;;
  "api repos/o/r/pulls/comments/"*)
    c=${a#api repos/o/r/pulls/comments/}; n=$((c / 1000))
    pr_node "$n" | jq -ce --argjson n "$n" --argjson c "$c" "$THREADS"'
      [(.reviewThreads.nodes // []) | roots($n)[] | comments | select(.id == $c)] | first
      | select(. != null) | . + {pull_request_url: "https://api.github.com/repos/o/r/pulls/\($n)"}' 2>/dev/null || nf ;;
  "api -X POST repos/o/r/pulls/"*/ccr/comments/*/resolve)
    c=${a%/resolve}; c=${c##*/}
    [ ! -f "$FX/rest-resolve-fails" ] || { echo "gh: Forbidden (HTTP 403)" >&2; exit 1; }
    echo "rest-resolve $c" >>"$FX/writes"; touch "$FX/rest-resolved-$c"; echo '{}' ;;
  "api -X POST repos/o/r/pulls/"*/comments/*/replies*)
    n=${a#api -X POST repos/o/r/pulls/}; n=${n%%/*}
    c=${a%%/replies*}; c=${c##*/}
    for x in "$@"; do case "$x" in body=*) b=${x#body=} ;; esac; done
    echo "rest-reply $c" >>"$FX/writes"
    jq -nc --arg b "$b" --argjson n "$n" --argjson c "$c" \
      '{_pr: $n, id: ($c + 9), in_reply_to_id: $c, user: {login: "me"}, body: $b, created_at: "2026-01-01T00:00:59Z"}' >>"$FX/rest-replies"
    echo '{}' ;;
  "api repos/o/r/pulls/"*/files*)
    n=${a#api repos/o/r/pulls/}; n=${n%%/*}
    jq --argjson n "$n" '(map(select(.number == $n)) | first // {}) | [(.files // [])[] | {filename: .path}]' "$FX/prs.json" ;;
  "api repos/o/r/pulls/"*/reviews*)
    n=${a#api repos/o/r/pulls/}; n=${n%%/*}
    jq --argjson n "$n" '(map(select(.number == $n)) | first // {}) | (.reviews // [])' "$FX/prs.json" ;;
  "api repos/o/r/pulls/"*)
    n=${a#api repos/o/r/pulls/}
    if [ -f "$FX/view-$n.json" ]; then jq "$REST"'rest' "$FX/view-$n.json"
    else one=$(jq -c --argjson n "$n" "$REST"'map(select(.number == $n)) | first // empty | rest' "$FX/prs.json"); [ -n "$one" ] || nf; echo "$one"; fi ;;
  "api repos/o/r/commits/"*/check-runs*)
    s=${a#api repos/o/r/commits/}; s=${s%%/*}
    [ ! -f "$FX/rest-fails-$s" ] || nf
    jq --arg s "$s" "$REST"'[rollup($s)[] | select(status_item | not)
      | ((.conclusion // "") | ascii_upcase) as $c
      | (if $c | IN("SUCCESS", "FAILURE", "NEUTRAL", "CANCELLED", "SKIPPED", "TIMED_OUT", "ACTION_REQUIRED", "STALE", "STARTUP_FAILURE")
         then {status: "completed", conclusion: ($c | ascii_downcase)}
         else {status: ((if $c != "" then $c else (.status // .state // "queued") end) | ascii_downcase), conclusion: null} end)
        + {name, started_at: (.startedAt // null), details_url: (.detailsUrl // null)}]
      | {total_count: length, check_runs: .}' "$FX/prs.json" ;;
  "api repos/o/r/commits/"*/status*)
    s=${a#api repos/o/r/commits/}; s=${s%%/*}
    jq --arg s "$s" "$REST"'{state: "pending", statuses: [rollup($s)[] | select(status_item)
      | {context: (.context // .name), state: ((.state // .conclusion // "") | ascii_downcase),
         target_url: (.targetUrl // .detailsUrl // null), created_at: (.startedAt // .createdAt // null)}]}' "$FX/prs.json" ;;
  "api repos/o/r/actions/runs?head_sha="*)
    s=${a#*head_sha=}; s=${s%%&*}
    jq --arg s "$s" "$REST"'{workflow_runs: ([rollup($s)[] | select(status_item | not)
      | ((.detailsUrl // "") | capture("/actions/runs/(?<r>[0-9]+)") // empty) as $m
      | {id: ($m.r | tonumber), name: (.workflowName // "")}] | unique_by(.id))}' "$FX/prs.json" ;;
  *) exec "$real" "$@" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/restbin/gh"
  export PATH="$BATS_TEST_TMPDIR/restbin:$PATH"
}
