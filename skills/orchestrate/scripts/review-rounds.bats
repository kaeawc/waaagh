#!/usr/bin/env bats
# Review rounds (#257): a bot reviewer re-reviews every push, so the fix flow batches one push per
# round, declines optional findings after that round instead of fixing them, reviews only the delta,
# and the triage tick counts fix rounds per PR. Covers review-ledger.sh rounds, review-followup.sh
# list's `optional` class and `decline`, thread-sweep.sh's `declined` answer (GraphQL and REST),
# the tick's rounds and review-loop lines, and the doctrine. gh is stubbed. Run: bats review-rounds.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  DOC="$SCRIPTS/.."
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1793880000   # 2026-11-05T12:00:00Z
  export GH_READ_JITTER=0 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_SELF_LOGIN ORCHESTRATE_GH_API ORCHESTRATE_REVIEW_ROUND_CAP ORCHESTRATE_SCRIPTS_DIR
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
}
rl() { "$SCRIPTS/review-ledger.sh" "$1" --repo o/r "${@:2}"; }
at() { ORCHESTRATE_NOW=$1 "$SCRIPTS/review-ledger.sh" "$2" --repo o/r "${@:3}" >/dev/null; }
H=3600

# --- review-ledger.sh rounds ---------------------------------------------------------------------

@test "rounds: fix and repair rows per PR, the first one's time, hours, and the newest reviewed head" {
  at $((ORCHESTRATE_NOW - 5 * H)) record --pr 7 --verdict fix-first --head aaa1111
  at $((ORCHESTRATE_NOW - 5 * H)) fix --pr 7 --note "pass one"
  at $((ORCHESTRATE_NOW - 3 * H)) record --pr 7 --verdict ship --head bbb2222
  at $((ORCHESTRATE_NOW - 2 * H)) repair --pr 7 --session trig_a
  at $((ORCHESTRATE_NOW - 2 * H)) repaired --pr 7
  at $((ORCHESTRATE_NOW - 1 * H)) record --pr 7 --verdict fix-first
  at $((ORCHESTRATE_NOW - 1 * H)) fix --pr 9
  at "$ORCHESTRATE_NOW" record --pr 8 --verdict ship --head ccc3333
  run rl rounds
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(printf '7\t2\t2026-11-05T07:00:00Z\t5\tbbb2222')" ]
  [ "${lines[1]}" = "$(printf '9\t1\t2026-11-05T11:00:00Z\t1\t-')" ]
  run rl rounds --min 2
  [ "$output" = "$(printf '7\t2\t2026-11-05T07:00:00Z\t5\tbbb2222')" ]
  run rl rounds --pr 9
  [ "$output" = "$(printf '9\t1\t2026-11-05T11:00:00Z\t1\t-')" ]
  run rl rounds --pr 8
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rounds: no ledger prints nothing; a bad --min or --pr is exit 2" {
  run rl rounds
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run rl rounds --min 0
  [ "$status" -eq 2 ]
  run rl rounds --min x
  [ "$status" -eq 2 ]
  run rl rounds --pr x
  [ "$status" -eq 2 ]
}

# --- review-followup.sh list and decline ---------------------------------------------------------
# One stubbed review thread for decline: its PR ($FX/thread-pr), starter body ($FX/starter),
# resolved flag ($FX/resolved) and replies ($FX/replies.json). list reads $FX/threads.json.
stub_followup() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do case "$1" in "$k="*) printf '%s' "${1#"$k="}"; return ;; esac; shift; done; }
q=$(arg query "$@")
case "$q" in
  *addPullRequestReviewThreadReply*)
    echo reply >>"$FX/writes"
    jq --arg b "$(arg b "$@")" '. + [$b]' "$FX/replies.json" >"$FX/r.tmp" && mv "$FX/r.tmp" "$FX/replies.json"
    echo '{"data":{}}' ;;
  *resolveReviewThread*) echo resolve >>"$FX/writes"; touch "$FX/resolved"; echo '{"data":{}}' ;;
  *reviewThreads*) cat "$FX/threads.json" ;;
  *node*)
    jq -n --arg pr "$(cat "$FX/thread-pr")" --argjson r "$([ -f "$FX/resolved" ] && echo true || echo false)" \
      --rawfile s "$FX/starter" --slurpfile rep "$FX/replies.json" '{data: {node: {__typename: "PullRequestReviewThread",
        isResolved: $r, pullRequest: {number: ($pr | tonumber)}, comments: {nodes: ([{body: $s}] + [$rep[0][] | {body: .}])}}}}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo 7 >"$FX/thread-pr"; echo '[]' >"$FX/replies.json"; : >"$FX/writes"
  printf '%s' $'\xf0\x9f\x9f\xa1 **Nit**: the name could be clearer' >"$FX/starter"
}
rf() { "$SCRIPTS/review-followup.sh" "$@" --repo o/r; }

# PR by "me", first reviewed at 10:00: optional and plain threads in and after that round, and an
# optional-marked thread of the author's own.
write_threads() {
  jq -n --arg y $'\xf0\x9f\x9f\xa1' --arg p $'\xf0\x9f\x9f\xa3' '
    def t($id; $who; $at; $body): {id: $id, isResolved: false, isOutdated: false, path: "a.sh", line: 1, originalLine: 1,
      comments: {nodes: [{author: {login: $who}, createdAt: $at, url: "u-\($id)", body: $body}]}};
    {data: {repository: {pullRequest: {author: {login: "me"},
      reviews: {nodes: [{author: {login: "claude"}, state: "COMMENTED", submittedAt: "2026-11-04T10:00:00Z"}]},
      reviewThreads: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [
        t("T_first"; "claude"; "2026-11-04T09:59:00Z"; "Off by one <!-- severity: important -->"),
        t("T_first_opt"; "claude"; "2026-11-04T09:59:00Z"; "\($y) **Nit**: rename it"),
        t("T_later_opt"; "claude"; "2026-11-04T15:00:00Z"; "Tighten the check (optional)"),
        t("T_later_pre"; "claude"; "2026-11-04T15:00:00Z"; "\($p) Pre-existing: the old path leaks"),
        t("T_later_html"; "claude"; "2026-11-04T15:00:00Z"; "Spacing <!-- severity: nit -->"),
        t("T_later"; "claude"; "2026-11-04T15:00:00Z"; "The page is dropped"),
        t("T_own"; "me"; "2026-11-04T16:00:00Z"; "\($y) note to self")]}}}}}' >"$FX/threads.json"
}
classes() { awk -F'\t' '{ print $1 " " $2 }' <<<"$output"; }

@test "list: optional-marked later threads are optional; first-round ones wait for the fix round" {
  stub_followup; write_threads
  run --separate-stderr rf list --pr 7
  [ "$status" -eq 0 ]
  [ "$(classes)" = "first T_first
first T_first_opt
optional T_later_opt
optional T_later_pre
optional T_later_html
later T_later
own T_own" ]
  [ "$stderr" = "pr=7 unresolved=7 first=2 later=1 own=1 optional=3 round-end=2026-11-04T10:00:00Z" ]
}

@test "list: after the fix round (a ledger fixing row, or --after-fix) first-round optional threads are optional" {
  stub_followup; write_threads
  run --separate-stderr rf list --pr 7 --after-fix
  [[ "$(classes)" == *"optional T_first_opt"* ]]
  [[ "$(classes)" == *"first T_first"$'\n'* ]]
  [[ "$stderr" == *"first=1 later=1 own=1 optional=4 "* ]]
  rl fix --pr 8 >/dev/null   # another PR's fix round does not count
  run --separate-stderr rf list --pr 7
  [[ "$stderr" == *"first=2 later=1 own=1 optional=3 "* ]]
  rl repair --pr 7 --session trig_x >/dev/null
  run --separate-stderr rf list --pr 7
  [[ "$(classes)" == *"optional T_first_opt"* ]]
  [[ "$stderr" == *"first=1 later=1 own=1 optional=4 "* ]]
}

@test "decline: replies 'Optional, not fixed: <reason>' and resolves an optional thread" {
  stub_followup
  run rf decline --pr 7 --thread PRRT_a --reason "naming only; the behaviour is right" --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "would resolve PRRT_a pr=7 reply" ]
  [ ! -s "$FX/writes" ]
  run rf decline --pr 7 --thread PRRT_a --reason "naming only; the behaviour is right"
  [ "$status" -eq 0 ]
  [ "$output" = "resolved PRRT_a pr=7" ]
  [ "$(cat "$FX/writes")" = $'reply\nresolve' ]
  [[ "$(jq -r '.[0]' "$FX/replies.json")" == "Optional, not fixed: naming only; the behaviour is right"* ]]
  [[ "$(cat "$ST/thread-actions.log")" == *"thread=PRRT_a"*"reply=Optional, not fixed: naming only"* ]]
  # a rerun posts nothing again
  run rf decline --pr 7 --thread PRRT_a --reason "naming only; the behaviour is right"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged PRRT_a pr=7" ]
  [ "$(awk 'END { print NR }' "$FX/writes")" -eq 2 ]
}

@test "decline: refuses a thread with no optional marker or on another PR; usage is exit 2" {
  stub_followup
  printf '%s' 'Off by one: the last page is dropped' >"$FX/starter"
  run rf decline --pr 7 --thread PRRT_a --reason "later"
  [ "$status" -eq 3 ]
  [[ "$output" == "refused: thread PRRT_a carries no optional marker"* ]]
  printf '%s' 'Could be shorter (optional)' >"$FX/starter"
  run rf decline --pr 8 --thread PRRT_a --reason "later"
  [ "$status" -eq 3 ]
  [ "$output" = "refused: thread PRRT_a is not on PR #8" ]
  [ ! -s "$FX/writes" ]
  : >"$FX/calls"
  run rf decline --pr 7 --thread PRRT_a
  [ "$status" -eq 2 ]
  run rf decline --pr 7 --thread PRRT_a --reason "   "
  [ "$status" -eq 2 ]
  run rf decline --pr 7 --thread 'bad id' --reason x
  [ "$status" -eq 2 ]
  [ ! -s "$FX/calls" ]
}

@test "decline: an unreadable thread is exit 4; a non-thread node is refused" {
  stub_followup
  rm "$FX/thread-pr"
  run rf decline --pr 7 --thread PRRT_a --reason x
  [ "$status" -eq 4 ]
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"data":{"node":{"__typename":"Issue"}}}'
STUB
  run rf decline --pr 7 --thread PRRT_a --reason x
  [ "$status" -eq 3 ]
  [ "$output" = "refused: PRRT_a is not a pull request review thread" ]
}

# --- thread-sweep.sh: the declined answer --------------------------------------------------------
# th ID STARTER_BODY REPLY: a bot-started thread with one reply from "me".
th() {
  jq -nc --arg id "$1" --arg sb "$2" --arg lb "$3" \
    '{id: $id, isResolved: false, isOutdated: false, starter: {nodes: [{author: {login: "claude"}, url: "u-\($id)", body: $sb}]},
      latest: {totalCount: 2, nodes: [{author: {login: "me"}, body: $lb, createdAt: "2026-11-05T08:00:00Z"}]}}'
}
stub_sweep() {
  stub_gh_routes
  jq -n --argjson a "$(th T_dec $'\xf0\x9f\x9f\xa1 Nit: rename' 'Optional, not fixed: naming only.')" \
    --argjson b "$(th T_decl 'Shorter (optional)' '**Declined**: out of scope here.')" \
    --argjson c "$(th T_plain 'Off by one' 'Optional, not fixed: later.')" \
    --argjson d "$(th T_agree $'\xf0\x9f\x9f\xa3 Pre-existing leak' 'Agreed, will look.')" \
    --argjson e "$(th T_dec2 'Could be shorter <!-- severity: pre-existing -->' 'optional: not here.')" '
    [{number: 90, commits: {nodes: [{commit: {oid: "abc1234def5678900000000000000000000000000", committedDate: "2026-11-05T09:00:00Z"}}]},
      reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [$a, $b, $c, $d]}},
     {number: 91, commits: {nodes: [{commit: {oid: "fedcba9876543210000000000000000000000000", committedDate: "2026-11-05T09:00:00Z"}}]},
      reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [$e]}}]' >"$FX/prs.json"
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
esac
R
}
ts() { "$SCRIPTS/thread-sweep.sh" "$@" --repo o/r; }

@test "scan: an 'Optional'/'Declined' reply on an optional-marked thread is answered (declined)" {
  stub_sweep
  export ORCHESTRATE_SELF_LOGIN=me
  run --separate-stderr ts scan
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf '90\tT_dec\tdeclined\toptional\tu-T_dec')" ]
  [ "${lines[1]}" = "$(printf '90\tT_decl\tdeclined\toptional\tu-T_decl')" ]
  [ "${lines[2]}" = "$(printf '90\tT_plain\topen\t-\tu-T_plain')" ]
  [ "${lines[3]}" = "$(printf '90\tT_agree\topen\t-\tu-T_agree')" ]
  [ "${lines[4]}" = "$(printf '91\tT_dec2\tdeclined\toptional\tu-T_dec2')" ]
  [ "$stderr" = "threads unresolved=5 answered=3 resolve-now=#91 repair=#90" ]
  run ts resolve --pr 91 --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "would resolve T_dec2 pr=91" ]
  [ "${lines[1]}" = "pr=91 resolved=1 open=0 failed=0" ]
}

@test "over REST: thread-nodes carries the starter's body, so the same reply is declined" {
  stub_gh_routes
  export ORCHESTRATE_GH_API=rest ORCHESTRATE_SELF_LOGIN=me
  gh_routes <<'R'
case "$a" in
  "api --paginate repos/o/r/pulls/5/ccr/review_threads"*) echo '[{"isResolved":false,"root_comment_id":11}]'; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/comments"*)
    echo '[{"id":11,"user":{"login":"claude[bot]"},"body":"Could be shorter (optional)","html_url":"u11","created_at":"2026-11-05T08:00:00Z"},
           {"id":12,"in_reply_to_id":11,"user":{"login":"me"},"body":"Optional, not fixed: fine as is.","created_at":"2026-11-05T10:00:00Z"}]'; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/commits"*) echo '[{"sha":"abc1234","commit":{"committer":{"date":"2026-11-05T09:00:00Z"}}}]'; exit 0 ;;
esac
R
  run --separate-stderr ts scan --pr 5
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '5\t11\tdeclined\toptional\tu11')" ]
  [ "$stderr" = "threads unresolved=1 answered=1 resolve-now=#5 repair=-" ]
}

# --- triage-tick.sh snapshot: rounds and review-loop ---------------------------------------------
tick_fixture() {
  stub_gh_routes
  stub_spectra   # an idle host: host-load.sh reads it through spectra (#330)
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD
  gh_route 'api repos/o/r/actions/runs?*' runs.json
  gh_route 'pr list*' prs.json
  gh_route 'issue list*' issues.json
  gh_routes <<'R'
case "$a" in
  "api graphql"*reviewThreads*) echo 'no threads here' >&2; exit 1 ;;
  "api graphql"*) cat "$FX/snapshot.json"; exit 0 ;;
esac
R
  echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-11-05T01:00:00Z"}]}' >"$FX/runs.json"
  echo '[]' >"$FX/issues.json"
  echo '[{"number":40,"closingIssuesReferences":[]},{"number":41,"closingIssuesReferences":[]}]' >"$FX/prs.json"
  jq -n 'def node($n): {number: $n, headRefOid: ("abcdef0123456789" + ($n | tostring)), isDraft: false,
        commits: {nodes: [{commit: {statusCheckRollup: {state: "PENDING"}}}]}, reviews: {nodes: []}};
    {data: {repository: {pullRequests: {pageInfo: {hasNextPage: false}, nodes: [node(40), node(41)]}}}}' >"$FX/snapshot.json"
}
snap() { "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main "$@"; }

@test "tick: a rounds line for open PRs with a fix round, a review-loop line and reason at the cap" {
  tick_fixture
  at $((ORCHESTRATE_NOW - 6 * H)) record --pr 40 --verdict fix-first --head 1234567890abcdef
  at $((ORCHESTRATE_NOW - 6 * H)) fix --pr 40
  at $((ORCHESTRATE_NOW - 2 * H)) repair --pr 40 --session trig_a
  at $((ORCHESTRATE_NOW - 1 * H)) repaired --pr 40
  at $((ORCHESTRATE_NOW - 1 * H)) fix --pr 41
  for i in 1 2 3; do at $((ORCHESTRATE_NOW - i * H)) fix --pr 99; done   # merged long ago: not open
  run snap
  [ "$status" -eq 0 ]
  required_snapshot_lines
  [ "$(snap_line rounds)" = "rounds #40=2,#41=1" ]
  [ "$(snap_line review-loop)" = "review-loop #40 rounds=2 since=2026-11-05T06:00:00Z hours=6 reviewed=1234567890ab" ]
  [[ "$(snap_line verdict)" == *"review-loop=1"* ]]
  ORCHESTRATE_REVIEW_ROUND_CAP=3 run snap
  [ "$(snap_line rounds)" = "rounds #40=2,#41=1" ]
  [ "$(grep -c '^review-loop' <<<"$output" || true)" -eq 0 ]
  [[ "$(snap_line verdict)" != *"review-loop"* ]]
}

@test "tick: no fix round on an open PR prints no rounds line" {
  tick_fixture
  at "$ORCHESTRATE_NOW" fix --pr 99
  run snap
  [ "$status" -eq 0 ]
  [ "$(grep -c '^rounds\|^review-loop' <<<"$output" || true)" -eq 0 ]
  [[ "$(snap_line verdict)" != *"review-loop"* ]]
}

@test "the rounds and review-loop lines and reason are documented in triage-tick.sh's header" {
  run snapshot_line_names "$SCRIPTS/triage-tick.sh"
  [[ "$output" == *$'\nrounds\nreview-loop'* ]]
  run "$SCRIPTS/triage-tick.sh" -h
  [[ "$output" == *"review-loop=<m>"* ]]
  [[ "$output" == *"ORCHESTRATE_REVIEW_ROUND_CAP"* ]]
}

# --- doctrine ------------------------------------------------------------------------------------
has() { grep -qF -- "$2" "$1" || { echo "missing in $1: $2"; return 1; }; }

@test "doctrine: one batched push with the base merge, decline after the fix round, delta review, round cap" {
  has "$DOC/review-rounds.md" "One batched fix push per round, with the base merge in it"
  has "$DOC/review-rounds.md" "review-followup.sh decline"
  has "$DOC/review-rounds.md" "git diff <reviewed>..<new head>"
  has "$DOC/review-rounds.md" "ORCHESTRATE_REVIEW_ROUND_CAP"
  has "$DOC/roles/pr-doctor.md" "Commit and push ONCE"
  has "$DOC/roles/pr-doctor.md" "review-followup.sh decline"
  has "$DOC/roles/pr-doctor.md" "never as a push of its own"
  has "$DOC/briefs/repair.md" "every fix and the base merge leave in ONE push"
  has "$DOC/briefs/repair.md" "Optional, not fixed:"
  has "$DOC/roles/triage-tick.md" "review-loop=<m>"
  has "$DOC/roles/triage-tick.md" "only the delta from the"
  has "$DOC/thread-resolution.md" "declined"
  has "$DOC/SKILL.md" "review-rounds.md"
}
