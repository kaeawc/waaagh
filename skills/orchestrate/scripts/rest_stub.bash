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
    case "$(cat "$FX/thread-shape" 2>/dev/null)" in
      snake) printf '%s' "$out" | jq -c 'map({resolved: .isResolved, outdated: .isOutdated, id: "t"})' ;;
      wrapped) printf '%s' "$out" | jq -c '{threads: .}' ;;
      *) printf '%s' "$out" ;;
    esac ;;
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
