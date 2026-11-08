#!/usr/bin/env bats
# thread-sweep.sh against a stubbed gh (answered-thread detection, resolve through
# thread-resolve.sh), the triage-tick resolve-now flag, and the thread-resolution doctrine (#70).
# Run: bats thread-sweep.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1793880000   # 2026-11-05T10:40:00Z
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD
  # Open PRs and their threads live in $FX/prs.json (GraphQL pull request nodes); a resolved
  # thread gets $FX/resolved-<id>. Every write is logged to $FX/writes.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do case "$1" in "$k="*) printf '%s' "${1#"$k="}"; return ;; esac; shift; done; }
case "$1 $2" in
  "api graphql")
    [ -f "$FX/read-fails" ] && { echo "HTTP 404: Not Found" >&2; exit 1; }
    q=$(arg query "$@")
    case "$q" in
      *addPullRequestReviewThreadReply*) echo "reply" >>"$FX/writes"; echo '{"data":{}}' ;;
      *resolveReviewThread*) echo "resolve $(arg t "$@")" >>"$FX/writes"; touch "$FX/resolved-$(arg t "$@")"; echo '{"data":{}}' ;;
      *pullRequests\(*) jq '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}' "$FX/prs.json" ;;
      *pullRequest\(number*) jq --argjson n "$(arg pr "$@")" '{data: {repository: {pullRequest: (map(select(.number == $n)) | first)}}}' "$FX/prs.json" ;;
      *node*)
        id=$(arg id "$@")
        jq --arg id "$id" --argjson r "$([ -f "$FX/resolved-$id" ] && echo true || echo false)" '
          [.[] | .number as $n | .reviewThreads.nodes[] | select(.id == $id)
           | {data: {node: {__typename: "PullRequestReviewThread", isResolved: (.isResolved or $r),
               pullRequest: {number: $n}, comments: {nodes: [.latest.nodes[] | {body}]}}}}] | first' "$FX/prs.json" ;;
      *) echo "unexpected query" >&2; exit 9 ;;
    esac ;;
  "run list") echo '[{"workflowName":"Test","status":"completed","conclusion":"success","headSha":"aaaaaaaaaaaa","databaseId":10,"createdAt":"2026-11-05T01:00:00Z"}]' ;;
  "pr list") jq '[.[] | {number, closingIssuesReferences: []}]' "$FX/prs.json" ;;
  "issue list") echo '[]' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  : >"$FX/calls"; : >"$FX/writes"
  write_prs
}
ts() { "$SCRIPTS/thread-sweep.sh" "$@" --repo o/r; }
tse() { ts "$@" 2>"$FX/err"; }   # stdout only; stderr kept in $FX/err

# th ID STARTER [AUTHOR BODY]... -> one thread node; the first author starts it, the last replied.
th() {
  local id=$1 starter=$2 total=1 la=$2 lb="the finding"; shift 2
  while (($#)); do total=$((total + 1)) la=$1 lb=$2; shift 2; done
  jq -nc --arg id "$id" --arg s "$starter" --arg la "$la" --arg lb "$lb" --argjson t "$total" \
    '{id: $id, isResolved: false, isOutdated: false, starter: {nodes: [{author: {login: $s}, url: "u-\($id)"}]},
      latest: {totalCount: $t, nodes: [{author: {login: $la}, body: $lb}]}}'
}
# PR 70: every thread answered (an issue link, a pushed fix), plus resolved and outdated ones.
# PR 71: nothing usable (no reply, a sha not on the PR, the reviewer spoke last, its own number,
# an HTML entity). PR 72: no threads. PR 73: answered, but more than 100 threads.
write_prs() {
  local done old
  done=$(th PRRT_done bot me "follow-up #9" | jq -c '.isResolved = true')
  old=$(th PRRT_old bot me "follow-up #9" | jq -c '.isOutdated = true')
  jq -n --argjson a "$(th PRRT_iss codex-bot me 'Filed as follow-up #101.')" \
    --argjson b "$(th PRRT_fix codex-bot me 'Fixed in ABC1234 (pushed).')" \
    --argjson c "$done" --argjson d "$old" \
    --argjson e "$(th PRRT_none codex-bot)" \
    --argjson f "$(th PRRT_badsha codex-bot me 'fixed in 1234567')" \
    --argjson g "$(th PRRT_back codex-bot me 'follow-up #5' codex-bot 'that issue is about something else')" \
    --argjson h "$(th PRRT_self codex-bot me 'see #71 and https://github.com/o/r/pull/71#discussion_r2')" \
    --argjson i "$(th PRRT_ent codex-bot me 'it&#39;s fine')" \
    --argjson j "$(th PRRT_big codex-bot me 'follow-up #102')" '
    def pr($n; $oids; $t; $more): {number: $n, commits: {nodes: [$oids[] | {commit: {oid: .}}]},
      reviewThreads: {pageInfo: {hasNextPage: $more}, nodes: $t}};
    [pr(70; ["abc1234def5678900000000000000000000000000"]; [$a, $b, $c, $d]; false),
     pr(71; ["fedcba9876543210000000000000000000000000"]; [$e, $f, $g, $h, $i]; false),
     pr(72; []; []; false),
     pr(73; []; [$j]; true)]' >"$FX/prs.json"
}

@test "scan: an issue link or a commit of the PR in the last reply answers a thread" {
  run tse scan
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 8 ]
  [ "${lines[0]}" = "$(printf '70\tPRRT_iss\tissue\t#101\tu-PRRT_iss')" ]
  [ "${lines[1]}" = "$(printf '70\tPRRT_fix\tfix\tabc1234\tu-PRRT_fix')" ]
  [ "${lines[2]}" = "$(printf '71\tPRRT_none\topen\t-\tu-PRRT_none')" ]
  [[ "${lines[3]}" == 71$'\t'PRRT_badsha$'\t'open* ]]
  [[ "${lines[4]}" == 71$'\t'PRRT_back$'\t'open* ]]
  [[ "${lines[5]}" == 71$'\t'PRRT_self$'\t'open* ]]
  [[ "${lines[6]}" == 71$'\t'PRRT_ent$'\t'open* ]]
  [ "${lines[7]}" = "$(printf '73\tPRRT_big\tissue\t#102\tu-PRRT_big')" ]
  [ "$(cat "$FX/err")" = "threads unresolved=8 answered=3 resolve-now=#70 repair=#71,#73" ]
  [ ! -s "$FX/writes" ]
}

@test "scan --summary prints only the summary; --pr reads one PR" {
  run ts scan --summary
  [ "$status" -eq 0 ]
  [ "$output" = "threads unresolved=8 answered=3 resolve-now=#70 repair=#71,#73" ]
  run ts scan --summary --pr 72
  [ "$output" = "threads unresolved=0 answered=0 resolve-now=- repair=-" ]
  grep -q 'pullRequest(number' "$FX/calls"
}

@test "an unreadable PR list is exit 4 and threads unknown, never a guess" {
  touch "$FX/read-fails"
  run ts scan --summary
  [ "$status" -eq 4 ]
  [ "${lines[${#lines[@]}-1]}" = "threads unknown" ]
}

@test "resolve: answered threads are resolved without a new reply; open ones are left alone" {
  run ts resolve --pr 70 --dry-run
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "would resolve PRRT_iss pr=70" ]
  [ ! -s "$FX/writes" ]
  run ts resolve --pr 70
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "resolved PRRT_iss pr=70" ]
  [ "${lines[1]}" = "resolved PRRT_fix pr=70" ]
  [ "${lines[2]}" = "pr=70 resolved=2 open=0 failed=0" ]
  [ "$(cat "$FX/writes")" = "$(printf 'resolve PRRT_iss\nresolve PRRT_fix')" ]
  grep -qF "pr=70"$'\t'"thread=PRRT_fix" "$ORCHESTRATE_STATE_DIR/o__r/thread-actions.log"
  run ts resolve --pr 71
  [ "$status" -eq 0 ]
  [ "$output" = "pr=71 resolved=0 open=5 failed=0" ]
  [ "$(wc -l <"$FX/writes")" -eq 2 ]
}

@test "usage errors are exit 2; the header is the -h text exactly" {
  run "$SCRIPTS/thread-sweep.sh" resolve --repo o/r
  [ "$status" -eq 2 ]
  run "$SCRIPTS/thread-sweep.sh" bogus --repo o/r
  [ "$status" -eq 2 ]
  run "$SCRIPTS/thread-sweep.sh" -h
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "# Find review threads that already carry an answer"* ]]
  [[ "${lines[${#lines[@]}-1]}" == "#       9 a resolve's outcome is unknown (rerun reconciles)." ]]
}

@test "the triage tick flags all-answered PRs as resolve-now, not as repair targets" {
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "verdict act "*"resolve-now=1"* ]]
  [ "${lines[7]}" = "threads unresolved=8 answered=3 resolve-now=#70 repair=#71,#73" ]
  echo '[]' >"$FX/prs.json"
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "${lines[7]}" = "threads none" ]
  [[ "${lines[0]}" != *resolve-now* ]]
}

@test "the thread-resolution doctrine is documented (#70)" {
  has() { grep -qF -- "$2" "$1" || { echo "missing in $1: $2"; return 1; }; }
  D="$ROOT/skills/orchestrate"
  has "$D/thread-resolution.md" "do not try to resolve"
  has "$D/thread-resolution.md" "thread-sweep.sh\" resolve"
  has "$D/thread-resolution.md" "resolveReviewThread"
  has "$D/SKILL.md" "thread-resolution.md"
  has "$D/roles/triage-tick.md" "resolve-now"
  has "$D/roles/pr-doctor.md" "thread-sweep.sh"
  has "$ROOT/README.md" "thread-sweep.sh"
}
