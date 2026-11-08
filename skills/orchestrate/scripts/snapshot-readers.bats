#!/usr/bin/env bats
# The per-pass readers on gh-snapshot.sh (#118): triage-tick.sh snapshot takes the last reviews of
# every open PR (and, where GraphQL is refused, the open count) from one snapshot call, and
# review-gate.sh check reads a fresh snapshot row instead of its own head and reviews reads.
# Run: bats snapshot-readers.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me
  unset ORCHESTRATE_NOW ORCHESTRATE_GH_API ORCHESTRATE_SNAPSHOT_TTL ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_REVIEW_BOTS
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  H70=7070707070707070707070707070707070707070
  H71=7171717171717171717171717171717171717171
  H72=7272727272727272727272727272727272727272
  OLD=1111111111111111111111111111111111111111
  # number head review-state review-commit (or "-"), one PR per line
  printf '70 %s APPROVED %s\n71 %s CHANGES_REQUESTED %s\n72 %s - -\n' "$H70" "$H70" "$H71" "$OLD" "$H72" >"$FX/prs"
  echo '[]' >"$FX/comments.json"
  echo '[{"number":5,"labels":[]}]' >"$FX/issues.json"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >>"$FX/calls"
refuse() { echo "HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the REST API" >&2; exit 1; }
rows() { jq -R 'split(" ") | {number: (.[0] | tonumber), head: .[1], state: .[2], commit: .[3]}' "$FX/prs" | jq -s .; }
case "$*" in
  "api repos/o/r/actions/runs?branch="*) echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-09-27T01:00:00Z"}]}' ;;
  "api graphql"*"pullRequests(states: OPEN"*) [ ! -f "$FX/rest" ] || refuse
    [ ! -f "$FX/snap-bad" ] || { echo '{"data":{}}'; exit 0; }
    rows | jq '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: false}, nodes: map({number, headRefOid: .head, isDraft: false,
      commits: {nodes: [{commit: {statusCheckRollup: {state: "SUCCESS"}}}]},
      reviews: {nodes: (if .state == "-" then [] else [{state, commit: {oid: .commit}}] end)}})}}}}' ;;
  "api graphql"*) [ ! -f "$FX/rest" ] || refuse
    echo '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
  "pr list"*) [ ! -f "$FX/rest" ] || refuse
    rows | jq 'map({number, closingIssuesReferences: [{number: 5}]})' ;;
  "pr view"*) [ ! -f "$FX/rest" ] || refuse; jq -n --arg h "$(cat "$FX/view-head")" '{headRefOid: $h}' ;;
  "issue list"*) cat "$FX/issues.json" ;;
  "api repos/o/r/pulls?state=open"*) rows | jq 'map({number, draft: false, user: {login: "me", type: "User"}, body: "",
      base: {ref: "main", repo: {full_name: "o/r"}}, head: {ref: "b", sha: .head, repo: {full_name: "o/r"}}, labels: []})' ;;
  *"/check-runs"*) echo '{"total_count":1,"check_runs":[{"name":"build","status":"completed","conclusion":"success"}]}' ;;
  *"/status"*) echo '{"state":"success","statuses":[]}' ;;
  *"/pulls/"*"/reviews"*) n=$(printf '%s\n' "$*" | sed -nE 's#.*/pulls/([0-9]+)/reviews.*#\1#p')
    if [ -f "$FX/reviews.json" ]; then cat "$FX/reviews.json"
    else rows | jq --argjson n "$n" '[.[] | select(.number == $n and .state != "-") | {user: {login: "someone"}, state, commit_id: .commit, body: "x"}]'; fi ;;
  *"/issues/"*"/comments"*) cat "$FX/comments.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

snap() { "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main "$@"; }
rg() { "$SCRIPTS/review-gate.sh" "$@" --repo o/r; }
calls() { grep -c "$1" "$FX/calls" || true; }

@test "triage-tick: the last review of every open PR comes from one snapshot call" {
  run snap
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "prs open=3 reviews=head:1,stale:1,none:1 changes-requested=#71" ]
  [ "$(calls 'pullRequests(states: OPEN')" -eq 1 ]
  [ "$(calls '^pr list')" -eq 1 ]
  # it refreshed the per-head cache review-gate.sh reads
  [ -f "$ST/pr-snapshot/$H72.json" ]
}

@test "triage-tick: an unreadable snapshot says reviews=unknown, the rest of the line stands" {
  touch "$FX/snap-bad"   # gh-snapshot.sh exits 3 on a page without pullRequests
  run snap
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "prs open=3 reviews=unknown" ]
}

@test "triage-tick: where GraphQL is refused, the open count comes from the snapshot over REST" {
  touch "$FX/rest"
  run snap
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "prs open=3 reviews=head:1,stale:1,none:1 changes-requested=#71" ]
  [[ "$output" == *$'\n'"dispatch unknown next=-"$'\n'* ]]
  [ "$(calls '/pulls/[0-9]*/reviews')" -eq 3 ]
  # ORCHESTRATE_GH_API=rest skips both GraphQL attempts and the PR list
  : >"$FX/calls"
  ORCHESTRATE_GH_API=rest run snap
  [ "${lines[2]}" = "prs open=3 reviews=head:1,stale:1,none:1 changes-requested=#71" ]
  [ "$(calls 'pullRequests(states: OPEN')" -eq 0 ]
  [ "$(calls '^pr list')" -eq 0 ]
}

@test "review-gate check: a fresh snapshot row with no review skips the head and reviews reads" {
  rg policy review-at-head >/dev/null
  "$SCRIPTS/gh-snapshot.sh" --repo o/r >/dev/null
  : >"$FX/calls"
  run rg check --pr 72
  [ "$status" -eq 3 ]
  [ "$output" = "wait never-reviewed" ]
  [ "$(calls '^pr view')" -eq 0 ]
  [ "$(calls '/reviews')" -eq 0 ]
  [ "$(calls '/comments')" -eq 1 ]
  # a bot comment naming the head still counts: comments are always read
  jq -n --arg h "$H72" '[{user: {login: "coderabbitai[bot]"}, body: ("Reviewed commit: " + $h[0:10])}]' >"$FX/comments.json"
  run rg check --pr 72 --head "$H72"
  [ "$status" -eq 0 ] && [ "$output" = "ok reviewed at-head" ]
}

@test "review-gate check: a snapshot row with a review still reads the reviews (the snapshot cannot tell a bot)" {
  rg policy review-at-head >/dev/null
  "$SCRIPTS/gh-snapshot.sh" --repo o/r >/dev/null
  : >"$FX/calls"
  jq -n --arg h "$H70" '[{user: {login: "chatgpt-codex-connector[bot]"}, state: "COMMENTED", commit_id: $h, body: "fine"}]' >"$FX/reviews.json"
  run rg check --pr 70
  [ "$status" -eq 0 ]
  [ "$output" = "ok reviewed at-head" ]
  [ "$(calls '^pr view')" -eq 0 ]
  [ "$(calls '/reviews')" -eq 1 ]
}

@test "review-gate check: a stale snapshot, or one for another head, falls back to its own reads" {
  rg policy review-at-head >/dev/null
  "$SCRIPTS/gh-snapshot.sh" --repo o/r >/dev/null
  echo "$H72" >"$FX/view-head"
  # another head than the snapshot's: the given head is checked, with its own reviews read
  : >"$FX/calls"
  run rg check --pr 72 --head "$OLD"
  [ "$status" -eq 3 ]
  [ "$(calls '/reviews')" -eq 1 ]
  # older than ORCHESTRATE_SNAPSHOT_TTL: head and reviews are read again
  touch -t 202001010000 "$ST/pr-snapshot/$H72.json"
  : >"$FX/calls"
  run rg check --pr 72
  [ "$status" -eq 3 ]
  [ "$output" = "wait never-reviewed" ]
  [ "$(calls '^pr view')" -eq 1 ]
  [ "$(calls '/reviews')" -eq 1 ]
  # a long TTL makes the same row fresh again
  : >"$FX/calls"
  ORCHESTRATE_SNAPSHOT_TTL=999999999 run rg check --pr 72
  [ "$(calls '^pr view')" -eq 0 ]
}

@test "the readers' snapshot use is documented in their headers" {
  run "$SCRIPTS/triage-tick.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *'one gh-snapshot.sh call'* ]]
  run "$SCRIPTS/review-gate.sh" -h
  [ "$status" -eq 0 ] && [[ "$output" == *'ORCHESTRATE_SNAPSHOT_TTL'* ]]
}
