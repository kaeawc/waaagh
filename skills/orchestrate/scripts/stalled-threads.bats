#!/usr/bin/env bats
# thread-sweep.sh's `stalled` answer (#209): an unresolved thread whose last reply is from our own
# account, came after the PR's head commit and names neither a fix nor an issue ("agreed, proposed
# fix, not pushed here") is a session that stopped without pushing, so it needs a repair now. Also
# the triage tick's stalled=<n> reason, the REST path, and the brief and role text that forbid it.
# Run: bats stalled-threads.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1793880000
  unset ORCHESTRATE_SELF_LOGIN ORCHESTRATE_GH_API ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD
  stub_gh_routes
  write_prs
  echo '{"login":"me"}' >"$FX/user.json"
  gh_route "api user" user.json
  gh_routes <<'R'
case "$a" in
  "api graphql"*"pullRequests("*)
    jq '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}' "$FX/prs.json"; exit 0 ;;
  "api graphql"*"pullRequest(number"*)
    n=$(sed -n 's/.*-F pr=\([0-9]*\).*/\1/p' <<<"$a")
    jq --argjson n "$n" '{data: {repository: {pullRequest: (map(select(.number == $n)) | first)}}}' "$FX/prs.json"; exit 0 ;;
  "api graphql"*"node(id"*)
    id=$(sed -n 's/.*-F id=\([A-Za-z_0-9]*\).*/\1/p' <<<"$a")
    jq --arg id "$id" '[.[] | .number as $n | .reviewThreads.nodes[] | select(.id == $id)
      | {data: {node: {__typename: "PullRequestReviewThread", isResolved: false, pullRequest: {number: $n},
          comments: {nodes: [.latest.nodes[] | {body}]}}}}] | first' "$FX/prs.json"; exit 0 ;;
  "run list"*) echo '[{"workflowName":"Test","status":"completed","conclusion":"success","headSha":"aaaaaaaaaaaa","databaseId":10,"createdAt":"2026-11-05T01:00:00Z"}]'; exit 0 ;;
  "pr list"*) jq '[.[] | {number, closingIssuesReferences: []}]' "$FX/prs.json"; exit 0 ;;
  "issue list"*) echo '[]'; exit 0 ;;
esac
R
}
ts() { "$SCRIPTS/thread-sweep.sh" "$@" --repo o/r; }
calls() { grep -c "$1" "$FX/calls" || true; }

# th ID AUTHOR BODY [CREATED]: a bot-started thread with one reply.
th() {
  jq -nc --arg id "$1" --arg la "$2" --arg lb "$3" --arg at "${4:-}" \
    '{id: $id, isResolved: false, isOutdated: false, starter: {nodes: [{author: {login: "claude"}, url: "u-\($id)"}]},
      latest: {totalCount: 2, nodes: [{author: {login: $la}, body: $lb} + (if $at == "" then {} else {createdAt: $at} end)]}}'
}
# PR 80, head committed 09:00: ours after the head (stalled), ours before it (a push may follow:
# open), someone else's after it (open), ours naming a pushed commit (fix), ours disagreeing (open). PR 81: our reply has no
# time (open, and no login read).
write_prs() {
  jq -n --argjson a "$(th T_stall me 'Traced and agreed: proposed fix, not pushed here.' 2026-11-05T10:00:00Z)" \
    --argjson b "$(th T_early me 'agreed' 2026-11-05T08:00:00Z)" \
    --argjson c "$(th T_other someone 'agreed' 2026-11-05T10:00:00Z)" \
    --argjson d "$(th T_fix me 'Fixed in abc1234.' 2026-11-05T10:00:00Z)" \
    --argjson e "$(th T_notime me 'agreed')" \
    --argjson f "$(th T_no me '**Disagree:** the input is validated upstream.' 2026-11-05T10:00:00Z)" '
    [{number: 80, commits: {nodes: [{commit: {oid: "0000000000000000000000000000000000000001", committedDate: "2026-11-05T07:00:00Z"}},
                                    {commit: {oid: "abc1234def5678900000000000000000000000000", committedDate: "2026-11-05T09:00:00Z"}}]},
      reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [$a, $b, $c, $d, $f]}},
     {number: 81, commits: {nodes: [{commit: {oid: "fedcba9876543210000000000000000000000000", committedDate: "2026-11-05T09:00:00Z"}}]},
      reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [$e]}}]' >"$FX/prs.json"
}

@test "scan: our own reply after the head commit naming no fix is stalled; others stay open" {
  run ts scan
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "$(printf '80\tT_stall\tstalled\t-\tu-T_stall')" ]
  [ "${lines[1]}" = "$(printf '80\tT_early\topen\t-\tu-T_early')" ]
  [ "${lines[2]}" = "$(printf '80\tT_other\topen\t-\tu-T_other')" ]
  [ "${lines[3]}" = "$(printf '80\tT_fix\tfix\tabc1234\tu-T_fix')" ]
  [ "${lines[4]}" = "$(printf '80\tT_no\topen\t-\tu-T_no')" ]
  [ "${lines[5]}" = "$(printf '81\tT_notime\topen\t-\tu-T_notime')" ]
  [ "${lines[6]}" = "threads unresolved=6 answered=1 resolve-now=- repair=#80,#81 stalled=#80" ]
  [ "$(calls '^api user$')" -eq 1 ]
}

@test "the login is read only for a late reply; ORCHESTRATE_SELF_LOGIN replaces the read" {
  run ts scan --summary --pr 81
  [ "$output" = "threads unresolved=1 answered=0 resolve-now=- repair=#81" ]
  [ "$(calls '^api user$')" -eq 0 ]
  ORCHESTRATE_SELF_LOGIN='someone[bot]' run ts scan --summary --pr 80
  [ "$output" = "threads unresolved=5 answered=1 resolve-now=- repair=#80 stalled=#80" ]
  [ "$(calls '^api user$')" -eq 0 ]
  ORCHESTRATE_SELF_LOGIN=someone run ts scan --pr 80
  [ "${lines[0]}" = "$(printf '80\tT_stall\topen\t-\tu-T_stall')" ]
  [ "${lines[2]}" = "$(printf '80\tT_other\tstalled\t-\tu-T_other')" ]
}

@test "an unreadable login leaves the thread open, never guessed stalled" {
  : >"$FX/routes.tsv"
  run ts scan --summary --pr 80
  [ "$status" -eq 0 ]
  [ "$output" = "threads unresolved=5 answered=1 resolve-now=- repair=#80" ]
}

@test "resolve leaves stalled threads alone and counts them open" {
  run ts resolve --pr 80 --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "would resolve T_fix pr=80" ]
  [ "${lines[1]}" = "pr=80 resolved=1 open=4 failed=0" ]
}

@test "the triage tick raises stalled=<n> and prints the stalled PRs" {
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "${lines[0]}" == "verdict act "*"stalled=1"* ]]
  [ "$(snap_line threads)" = "threads unresolved=6 answered=1 resolve-now=- repair=#80,#81 stalled=#80" ]
}

@test "over REST: thread-nodes carries reply and commit times, so the same thread is stalled" {
  export ORCHESTRATE_GH_API=rest
  gh_routes <<'R'
case "$a" in
  "api --paginate repos/o/r/pulls/5/ccr/review_threads"*) echo '[{"isResolved":false,"root_comment_id":11}]'; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/comments"*)
    echo '[{"id":11,"user":{"login":"claude[bot]"},"body":"finding","html_url":"u11","created_at":"2026-11-05T08:00:00Z"},
           {"id":12,"in_reply_to_id":11,"user":{"login":"me"},"body":"agreed, deferred to a follow-up","created_at":"2026-11-05T10:00:00Z"}]'; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/commits"*) echo '[{"sha":"abc1234","commit":{"committer":{"date":"2026-11-05T09:00:00Z"}}}]'; exit 0 ;;
esac
R
  run ts scan --pr 5
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "$(printf '5\t11\tstalled\t-\tu11')" ]
  [ "${lines[1]}" = "threads unresolved=1 answered=0 resolve-now=- repair=#5 stalled=#5" ]
}

@test "the briefs and roles require the push for an agreed finding" {
  for f in implement repair; do
    run grep -c "never end with an agreed but unfixed thread" "$SCRIPTS/../briefs/$f.md"
    [ "$output" -ge 1 ] || { echo "$f.md"; false; }
    run grep -c "commit SHA" "$SCRIPTS/../briefs/$f.md"
    [ "$output" -ge 1 ] || { echo "$f.md"; false; }
  done
  run grep -c "agreed but unfixed thread" "$SCRIPTS/../roles/_common.md"
  [ "$output" -ge 1 ]
  run grep -c "stalled" "$SCRIPTS/../thread-resolution.md" "$SCRIPTS/../roles/triage-tick.md"
  [[ "$output" != *":0"* ]]
}
