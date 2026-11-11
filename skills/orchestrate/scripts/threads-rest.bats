#!/usr/bin/env bats
# The triage tick's last two GraphQL-only parts over REST (#136): the dispatch queue (gh-issues.sh
# prs-open and issues), thread-sweep.sh scan (gh-rest-pr.sh thread-nodes: ccr/review_threads plus
# pulls/<n>/comments and commits) and thread-resolve.sh with a numeric comment id (POST
# .../replies, POST .../ccr/comments/<id>/resolve). The same fixtures are read both ways: a
# GraphQL stub, and rest_wrap (rest_stub.bash) refusing GraphQL with the cloud 403 in front of it.
# Run: bats threads-rest.bats

setup() {
  load test_helper
  load rest_stub
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1793880000 ORCHESTRATE_AUTHOR=me
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD ORCHESTRATE_GH_API
  export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768
  MEMO="$ORCHESTRATE_STATE_DIR/gh-no-graphql"
  # GraphQL side: $FX/prs.json holds the open PRs as thread-sweep's pull request nodes, $FX/pulls.json
  # their REST rows (`_closing`: the issues GraphQL says they close), $FX/issues.json the REST issues.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do case "$1" in "$k="*) printf '%s' "${1#"$k="}"; return ;; esac; shift; done; }
case "$1 $2" in
  "api graphql")
    q=$(arg query "$@")
    case "$q" in
      *resolveReviewThread*) echo "resolve $(arg t "$@")" >>"$FX/writes"; touch "$FX/resolved-$(arg t "$@")"; echo '{"data":{}}' ;;
      *" p"[0-9]*": pullRequest(number:"*)
        n=$(printf '%s' "$q" | sed -nE 's/.* p([0-9]+): pullRequest.*/\1/p')
        jq --argjson n "$n" '{data: {repository: {"p\($n)": (map(select(.number == $n)) | first)}}}' "$FX/prs.json" ;;
      *pullRequests\(states:OPEN*) jq '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}' "$FX/prs.json" ;;
      *pullRequest\(number*) jq --argjson n "$(arg pr "$@")" '{data: {repository: {pullRequest: (map(select(.number == $n)) | first)}}}' "$FX/prs.json" ;;
      *node*)
        id=$(arg id "$@")
        jq --arg id "$id" --argjson r "$([ -f "$FX/resolved-$id" ] && echo true || echo false)" '
          [.[] | .number as $n | .reviewThreads.nodes[] | select(.id == $id)
           | {data: {node: {__typename: "PullRequestReviewThread", isResolved: (.isResolved or $r),
               pullRequest: {number: $n}, comments: {nodes: [.latest.nodes[] | {body}]}}}}] | first' "$FX/prs.json" ;;
      *) echo "HTTP 404: unexpected query" >&2; exit 1 ;;
    esac ;;
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-11-05T01:00:00Z"}]}' ;;
  "pr list") jq '[.[] | {number, closingIssuesReferences: (._closing // [])}]' "$FX/pulls.json" ;;
  "issue list") jq '[.[] | select(.pull_request == null) | {number, labels: [.labels[] | {name}]}]' "$FX/issues.json" ;;
  *) echo "HTTP 404: unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  rest_wrap
  : >"$FX/calls"; : >"$FX/writes"
  write_fixtures
}

# th ID STARTER [AUTHOR BODY]... -> one thread node; the first author starts it, the last replied.
th() {
  local id=$1 starter=$2 total=1 la=$2 lb="the finding"; shift 2
  while (($#)); do total=$((total + 1)) la=$1 lb=$2; shift 2; done
  jq -nc --arg id "$id" --arg s "$starter" --arg la "$la" --arg lb "$lb" --argjson t "$total" \
    '{id: $id, isResolved: false, isOutdated: false, starter: {nodes: [{author: {login: $s}, url: "u-\($id)"}]},
      latest: {totalCount: $t, nodes: [{author: {login: $la}, body: $lb}]}}'
}
# PR 70: every unresolved thread answered (an issue link, a pushed fix), plus a resolved and an
# outdated one. PR 71: nothing usable. PR 72: no threads. Issues: #5 (closed by PR 70), #6, #7
# (blocked), #8.
write_fixtures() {
  jq -n --argjson a "$(th PRRT_iss claude me 'Filed as follow-up #101.')" \
    --argjson b "$(th PRRT_fix claude me 'Fixed in ABC1234 (pushed).')" \
    --argjson c "$(th PRRT_done bot me 'follow-up #9' | jq -c '.isResolved = true')" \
    --argjson d "$(th PRRT_old bot me 'follow-up #9' | jq -c '.isOutdated = true')" \
    --argjson e "$(th PRRT_none claude)" \
    --argjson f "$(th PRRT_badsha claude me 'fixed in 1234567')" \
    --argjson g "$(th PRRT_back claude me 'follow-up #5' claude 'that issue is about something else')" \
    --argjson h "$(th PRRT_self claude me 'see #71 and https://github.com/o/r/pull/71#discussion_r2')" '
    def pr($n; $oids; $t): {number: $n, commits: {nodes: [$oids[] | {commit: {oid: .}}]},
      reviewThreads: {pageInfo: {hasNextPage: false}, nodes: $t}};
    [pr(70; ["abc1234def5678900000000000000000000000000"]; [$a, $b, $c, $d]),
     pr(71; ["fedcba9876543210000000000000000000000000"]; [$e, $f, $g, $h]),
     pr(72; []; [])]' >"$FX/prs.json"
  jq -n '[{n: 70, body: "Fixes #5", c: [5]}, {n: 71, body: "Part of #6", c: []}, {n: 72, body: "", c: []}]
    | map({number: .n, title: "pr \(.n)", body, state: "open", user: {login: "me", type: "User"}, draft: false,
        head: {ref: "b\(.n)", sha: "h\(.n)", repo: {full_name: "o/r"}}, base: {ref: "main", repo: {full_name: "o/r"}},
        labels: [], created_at: "2026-11-01T00:00:00Z", updated_at: "2026-11-01T00:00:00Z", html_url: "u", _closing: [.c[] | {number: .}]})' >"$FX/pulls.json"
  jq -n '[5, 6, 7, 8] | map({number: ., title: "issue \(.)", body: "", state: "open", html_url: "u", user: {login: "me"},
      labels: (if . == 7 then [{name: "blocked"}] else [] end), created_at: "2026-11-01T00:00:00Z", updated_at: "2026-11-01T00:00:00Z"})
    + [{number: 70, title: "pr", state: "open", labels: [], user: {login: "me"}, pull_request: {}}]' >"$FX/issues.json"
}
ts() { "$SCRIPTS/thread-sweep.sh" "$@" --repo o/r; }
graphql() { rm -f "$FX/rest-mode" "$MEMO"; }
cloud() { touch "$FX/rest-mode"; rm -f "$MEMO"; }
verdicts() { cut -f1,3-5 <<<"$1"; }   # the scan rows without the thread-id column

@test "scan: the same answers and summary over REST as over GraphQL; REST ids are comment ids" {
  graphql
  run ts scan
  [ "$status" -eq 0 ]
  gq=$output
  [ "${lines[${#lines[@]}-1]}" = "threads unresolved=6 answered=2 resolve-now=#70 repair=#71" ]
  cloud
  run ts scan
  [ "$status" -eq 0 ]
  [ "$(verdicts "$output")" = "$(verdicts "$gq")" ]
  [ "${lines[0]}" = "$(printf '70\t70010\tissue\t#101\tu-PRRT_iss')" ]
  [ "${lines[1]}" = "$(printf '70\t70020\tfix\tabc1234\tu-PRRT_fix')" ]
  [[ "${lines[4]}" == 71$'\t'71030$'\t'open* ]]
  [ -f "$MEMO" ]
  grep -q '^api --paginate repos/o/r/pulls/70/ccr/review_threads' "$FX/rest-calls"
  grep -q '^api --paginate repos/o/r/pulls/71/comments?per_page=100' "$FX/rest-calls"
  grep -q '^api --paginate repos/o/r/pulls/70/commits?per_page=100' "$FX/rest-calls"
  # a PR with no thread costs one read: no comments, no commits
  [ "$(grep -c 'pulls/72/' "$FX/rest-calls")" -eq 1 ]
  [ ! -s "$FX/writes" ]
}

@test "scan --summary and --pr over REST, in every thread shape gh-rest-pr knows" {
  cloud
  for shape in graphql snake wrapped; do
    echo "$shape" >"$FX/thread-shape"
    run ts scan --summary
    [ "$status" -eq 0 ]
    [ "$output" = "threads unresolved=6 answered=2 resolve-now=#70 repair=#71" ] || { echo "$shape: $output"; false; }
  done
  run ts scan --summary --pr 72
  [ "$output" = "threads unresolved=0 answered=0 resolve-now=- repair=-" ]
  # ORCHESTRATE_GH_API=rest makes no GraphQL attempt at all
  : >"$FX/rest-calls"
  ORCHESTRATE_GH_API=rest run ts scan --summary --pr 70
  [ "$output" = "threads unresolved=2 answered=2 resolve-now=#70 repair=-" ]
  [ "$(grep -c graphql "$FX/rest-calls" || true)" -eq 0 ]
}

@test "scan over REST: an unreadable thread list is exit 4 and threads unknown, never a guess" {
  cloud
  echo '{"message":"something else"}' >"$BATS_TEST_TMPDIR/odd.json"
  mkdir -p "$BATS_TEST_TMPDIR/odd"
  cat >"$BATS_TEST_TMPDIR/odd/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in *ccr/review_threads*) cat "$BATS_TEST_TMPDIR/odd.json"; exit 0 ;; esac
exec "$BATS_TEST_TMPDIR/restbin/gh" "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/odd/gh"
  PATH="$BATS_TEST_TMPDIR/odd:$PATH" run ts scan --summary
  [ "$status" -eq 4 ]
  [ "${lines[${#lines[@]}-1]}" = "threads unknown" ]
  # a GraphQL failure that is not the refusal is not answered over REST
  graphql
  echo 'not json' >"$FX/prs.json"
  run ts scan --summary
  [ "$status" -eq 4 ]
  [ ! -f "$MEMO" ]
}

@test "gh-rest-pr thread-nodes ties each thread to its comments, and fails closed without a tie" {
  mkdir -p "$BATS_TEST_TMPDIR/tbin"
  cat >"$BATS_TEST_TMPDIR/tbin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/tcalls"
case "$*" in
  *ccr/review_threads*) cat "$FX/t-threads" ;;
  *"/comments?"*) cat "$FX/t-comments" ;;
  *"/commits?"*) echo '[{"sha":"abc"}]' ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/tbin/gh"
  tn() { printf '%s' "$1" >"$FX/t-threads"; PATH="$BATS_TEST_TMPDIR/tbin:$PATH" "$SCRIPTS/gh-rest-pr.sh" thread-nodes --repo o/r --pr 5 2>/dev/null; }
  echo '[{"id":11,"user":{"login":"bot[bot]"},"body":"finding","html_url":"u11","created_at":"2026-01-01T00:00:01Z"},
         {"id":13,"in_reply_to_id":11,"user":{"login":"bot[bot]"},"body":"no","created_at":"2026-01-01T00:00:03Z"},
         {"id":12,"in_reply_to_id":11,"user":{"login":"me"},"body":"follow-up #9","created_at":"2026-01-01T00:00:02Z"},
         {"id":20,"user":{"login":"x"},"body":"b","html_url":"u20","created_at":"2026-01-01T00:00:01Z"}]' >"$FX/t-comments"
  out=$(tn '[{"isResolved":false,"comments":{"nodes":[{"id":"PRRC_x","databaseId":11}]}},{"is_resolved":true,"root_comment_id":"20"}]')
  jq -e '.number == 5 and .commits.nodes == [{commit: {oid: "abc"}}]
    and .reviewThreads.nodes[0] == {id: "11", isResolved: false, isOutdated: false,
      starter: {nodes: [{author: {login: "bot"}, url: "u11"}]},
      latest: {totalCount: 3, nodes: [{author: {login: "bot"}, body: "no"}]},
      comments: {nodes: [{body: "finding"}, {body: "follow-up #9"}, {body: "no"}]}}
    and (.reviewThreads.nodes[1] | .id == "20" and .isResolved and .latest.totalCount == 1)' <<<"$out"
  # a reply's id names the thread it is in
  [ "$(tn '[{"resolved":false,"comment_id":12}]' | jq -r '.reviewThreads.nodes[0].id')" = 11 ]
  # no thread: the comments and commits are not read
  : >"$FX/tcalls"
  [ "$(tn '[]' | jq -c .reviewThreads.nodes)" = '[]' ]
  [ "$(wc -l <"$FX/tcalls")" -eq 1 ]
  run tn '[{"isResolved":false}]'
  [ "$status" -eq 3 ]
  run tn '[{"isResolved":false,"comment_id":99}]'
  [ "$status" -eq 3 ]
  run tn '[{"isResolved":false,"comments":[{"id":"PRRC_only"}]}]'
  [ "$status" -eq 3 ]
}

@test "resolve over REST: answered threads by their comment id, journaled and read back" {
  cloud
  run ts resolve --pr 70 --dry-run
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "would resolve 70010 pr=70" ]
  [ ! -s "$FX/writes" ]
  run ts resolve --pr 70
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "resolved 70010 pr=70" ]
  [ "${lines[1]}" = "resolved 70020 pr=70" ]
  [ "${lines[2]}" = "pr=70 resolved=2 open=0 failed=0" ]
  [ "$(cat "$FX/writes")" = "$(printf 'rest-resolve 70010\nrest-resolve 70020')" ]
  grep -qF "pr=70"$'\t'"thread=70020" "$ORCHESTRATE_STATE_DIR/o__r/thread-actions.log"
  run ts scan --summary --pr 70
  [ "$output" = "threads unresolved=0 answered=0 resolve-now=- repair=-" ]
  run ts resolve --pr 71
  [ "$output" = "pr=71 resolved=0 open=4 failed=0" ]
  [ "$(wc -l <"$FX/writes")" -eq 2 ]
}

@test "thread-resolve over REST: one reply, one resolve, a rerun changes nothing" {
  cloud
  tr_() { "$SCRIPTS/thread-resolve.sh" "$@" --repo o/r; }
  run tr_ --thread 71010 --reply "Tracked in #300."
  [ "$status" -eq 0 ]
  [ "$output" = "resolved 71010 pr=71" ]
  [ "$(cat "$FX/writes")" = "$(printf 'rest-reply 71010\nrest-resolve 71010')" ]
  grep -q 'waaagh:reply thread=71010' "$FX/rest-replies"
  grep -q '^api repos/o/r/pulls/comments/71010' "$FX/rest-calls"   # no --pr: the comment names it
  grep -qF "thread=71010"$'\t'"reply=Tracked in #300." "$ORCHESTRATE_STATE_DIR/o__r/thread-actions.log"
  run tr_ --thread 71010 --pr 71 --reply "Tracked in #300."
  [ "$output" = "unchanged 71010 pr=71" ]
  [ "$(wc -l <"$FX/writes")" -eq 2 ]
  # refusals: a comment that does not exist, a thread not on --pr, a reply's id
  run tr_ --thread 99010
  [ "$status" -eq 3 ]
  run tr_ --thread 71020 --pr 70
  [ "$status" -eq 3 ]
  run tr_ --thread 71031 --pr 71
  [ "$status" -eq 3 ]
  # a refused resolve is exit 5 and leaves no journal line
  touch "$FX/rest-resolve-fails"
  run tr_ --thread 71020 --pr 71
  [ "$status" -eq 5 ]
  [ "$(grep -c 'thread=71020' "$ORCHESTRATE_STATE_DIR/o__r/thread-actions.log" || true)" -eq 0 ]
}

@test "thread-resolve: a GraphQL node id where GraphQL is refused is exit 4, pointing at the REST id" {
  cloud
  run "$SCRIPTS/thread-resolve.sh" --thread PRRT_iss --repo o/r
  [ "$status" -eq 4 ]
  [[ "$output" == *"REST id of the thread's first comment"* ]]
  [ -f "$MEMO" ]
  : >"$FX/rest-calls"
  run "$SCRIPTS/thread-resolve.sh" --thread PRRT_iss --repo o/r
  [ "$status" -eq 4 ]
  [ ! -s "$FX/rest-calls" ]
  [ ! -s "$FX/writes" ]
}

@test "triage-tick snapshot: the same dispatch and threads lines over REST as over GraphQL" {
  graphql
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$status" -eq 0 ]
  gq=$output
  [[ "$gq" == *$'\n'"dispatch 2 next=#6,#8"$'\n'* ]]
  [[ "$gq" == *$'\n'"threads unresolved=6 answered=2 resolve-now=#70 repair=#71"$'\n'* ]]
  [[ "${lines[0]}" == "verdict act "*"dispatch=2"*"resolve-now=1"* ]]
  cloud
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(sed -n 1p <<<"$gq")" ]
  [[ "$output" == *$'\n'"prs open=3"* ]]
  [[ "$output" == *$'\n'"dispatch 2 next=#6,#8"$'\n'* ]]
  [[ "$output" == *$'\n'"threads unresolved=6 answered=2 resolve-now=#70 repair=#71"$'\n'* ]]
  grep -q '^api repos/o/r/issues?state=open' "$FX/rest-calls"
}
