# A gh stub for the REST path (#109). rest_wrap puts it in front of the suite's own GraphQL-shaped
# stub ($BATS_TEST_TMPDIR/bin/gh). While $FX/rest-mode exists it answers like a Claude Code cloud
# session: every `gh pr ...` and `gh api graphql` call is refused with the real HTTP 403 text, and
# the REST routes are served from the SAME fixtures the GraphQL stub serves: $FX/prs.json (the
# `gh pr list --json` rows, plus optional `files` and `reviews`), $FX/view-<n>.json, and review
# threads read through the GraphQL stub itself (one PR per query, then its cursors). Without
# $FX/rest-mode every call goes straight to the GraphQL stub. REST calls are logged to
# $FX/rest-calls. $FX/thread-shape: graphql (default: isResolved/isOutdated) | snake
# (resolved/outdated) | wrapped ({"threads": [...]}). $FX/rest-fails-<sha>: that head's check-runs
# answer HTTP 404.

rest_wrap() {
  mkdir -p "$BATS_TEST_TMPDIR/restbin"
  cat >"$BATS_TEST_TMPDIR/restbin/gh" <<'STUB'
#!/usr/bin/env bash
real="$BATS_TEST_TMPDIR/bin/gh"
[ -f "$FX/rest-mode" ] || exec "$real" "$@"
echo "$*" >>"$FX/rest-calls"
a="$*"; a=${a% --include}; a=${a/api --paginate /api }
nf() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
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
  "pr "* | "api graphql"*)
    echo "HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (https://api.github.com/graphql)" >&2
    exit 1 ;;
  "api repos/o/r/pulls?"*)
    p=$(printf '%s\n' "$a" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p')
    jq --argjson p "${p:-1}" "$REST"'.[(($p - 1) * 100):($p * 100)] | map(rest | del(.mergeable))' "$FX/prs.json" ;;
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

# both ARGS...: pr-ready.sh over GraphQL, then over REST (refused GraphQL, own state dir). The exit
# code, every row and the summary must match; only draft and fork rows may differ in their
# mergeable and passed columns (REST does not read them), and REST adds " api=rest". Leaves the
# REST run in $output and $status.
both() {
  local gq rs gs rss
  rm -f "$FX/rest-mode"
  gq=$(ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state-gq" "$SCRIPTS/pr-ready.sh" "$@" 2>"$FX/gq.err") && gs=0 || gs=$?
  touch "$FX/rest-mode"
  rs=$(ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state-rest" "$SCRIPTS/pr-ready.sh" "$@" 2>"$FX/rs.err") && rss=0 || rss=$?
  norm() { awk -F'\t' -v OFS='\t' '$2 == "SKIP" && ($6 == "draft" || $6 == "fork") { $4 = "-"; $5 = "-" } { print }'; }
  sum() { tail -1 "$1" | sed -E 's/ diagnostics=[^ ]*//; s/ api=rest//'; }
  [ "$gs" = "$rss" ] || { echo "exit: graphql=$gs rest=$rss"; cat "$FX/rs.err"; return 1; }
  [ "$(norm <<<"$gq")" = "$(norm <<<"$rs")" ] || { echo "rows differ:"; diff <(norm <<<"$gq") <(norm <<<"$rs") || true; cat "$FX/rs.err"; return 1; }
  [ "$(sum "$FX/gq.err")" = "$(sum "$FX/rs.err")" ] || { echo "summary: $(tail -1 "$FX/gq.err") | $(tail -1 "$FX/rs.err")"; return 1; }
  if [ "$gs" = 0 ]; then grep -q 'api=rest' "$FX/rs.err" || { echo "no api=rest"; return 1; }; fi
  output="$rs"$'\n'"$(cat "$FX/rs.err")"
  status=$rss
}
