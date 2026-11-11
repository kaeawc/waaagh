#!/usr/bin/env bats
# A repair session in flight (#212): review-ledger.sh repair marks a PR `repairing` with its
# session, which holds it on every merge path and refuses a ship verdict until the repair ends
# (`repaired`, by hand or by `settle` reading the session's closing comment). cloud-dispatch.sh
# record --kind repair sets it, and the triage tick settles and reports it. gh is stubbed from $FX.
# Run: bats repair-inflight.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FX"
  # Fixtures in $FX: comments-<pr>.json is the answer for that PR's comments (absent: HTTP 404).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r/issues/"*"/comments?per_page=100&since="*)
    a="$*"; n=${a#api repos/o/r/issues/}; n=${n%%/*}
    [ -f "$FX/comments-$n.json" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    cat "$FX/comments-$n.json" ;;
  *) echo "HTTP 404: Not Found" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_JITTER=0 ORCHESTRATE_READ_SLEEP=0   # 2026-09-27T12:00:00Z
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD ORCHESTRATE_HOLD_STALE_HOURS
  export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768
  ST="$ORCHESTRATE_STATE_DIR/o__r"
  mkdir -p "$ST"
}
rl() { "$SCRIPTS/review-ledger.sh" "$1" --repo o/r "${@:2}"; }
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r --no-blocker-check; }
gate() { run bash -c 'source "$1/_lib.sh"; orch_review_hold_of o/r "$2"' _ "$SCRIPTS" "$1"; }
comment() { # comment PR CREATED_AT BODY: the PR's comments answer, one comment
  jq -n --arg t "$2" --arg b "$3" --arg u "https://github.com/o/r/pull/$1#issuecomment-9" \
    '[{created_at: $t, body: $b, html_url: $u}]' >"$FX/comments-$1.json"
}
has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "review-ledger.sh repair: usage errors are exit 2" {
  run rl repair --pr 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"repair needs --session"* ]]
  run rl repair --pr 5 --session 'two words'
  [ "$status" -eq 2 ]
  run rl repaired
  [ "$status" -eq 2 ]
  run rl settle --pr x
  [ "$status" -eq 2 ]
  run rl inflight --pr x
  [ "$status" -eq 2 ]
  run rl inflight
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "a repair in flight holds the PR and refuses ship until it ends; then the final head is reviewed" {
  run rl repair --pr 5 --session trig_a --note "cloud repair"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recorded: PR 5 repairing session trig_a" ]
  [ "${lines[1]}" = "held: PR 5 until:review-ship" ]
  [ "$(cat "$ST/reviews.tsv")" = $'2026-09-27T12:00:00Z\t5\trepairing\t-\tcloud repair\ttrig_a' ]
  run rl inflight
  [ "$output" = $'5\ttrig_a\t2026-09-27T12:00:00Z' ]
  gate 5
  [ "$status" -eq 0 ]
  [ "$output" = "#5 review:repairing since:2026-09-27T12:00:00Z head:- cloud repair session:trig_a" ]
  run rl blocked
  [ "$output" = $'5\trepairing' ]
  # The session's first commit is reviewed: ship is refused, nothing is appended, the hold stays.
  run rl record --pr 5 --verdict ship --head abc
  [ "$status" -eq 6 ]
  [[ "$output" == *"refused: a repair is in flight on PR 5 (session trig_a since 2026-09-27T12:00:00Z)"* ]]
  [ "$(rl list --pr 5 | awk 'END { print NR }')" -eq 1 ]
  grep -q '^5 until:review-ship' "$ST/holds"
  # A non-ship verdict is still recorded; the repair stays in flight under it.
  run rl record --pr 5 --verdict fix-first
  [ "$status" -eq 0 ]
  [ "$(rl inflight --pr 5 | cut -f2)" = trig_a ]
  run rl record --pr 5 --verdict ship
  [ "$status" -eq 6 ]
  # The same session again is a no-op; another session is refused.
  run rl repair --pr 5 --session trig_a
  [ "$status" -eq 0 ]
  [ "$output" = "already in flight: PR 5 session trig_a since 2026-09-27T12:00:00Z" ]
  run rl repair --pr 5 --session trig_b
  [ "$status" -eq 6 ]
  run rl repaired --pr 5 --session trig_b
  [ "$status" -eq 6 ]
  [[ "$output" == *"is session trig_a, not trig_b"* ]]
  # The repair ends: repaired still holds (the final head needs a review), and ship is allowed.
  export ORCHESTRATE_NOW=1790514000
  run rl repaired --pr 5 --session trig_a --note "run ended"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recorded: PR 5 repaired session trig_a" ]
  [[ "${lines[1]}" == "already held: #5 until:review-ship"* ]]
  run rl inflight
  [ "$output" = "" ]
  gate 5
  [ "$status" -eq 0 ]
  [[ "$output" == "#5 review:repaired since:2026-09-27T13:00:00Z head:- run ended session:trig_a" ]]
  run rl repaired --pr 5
  [ "$status" -eq 0 ]
  [ "$output" = "no repair in flight: PR 5" ]
  run rl record --pr 5 --verdict ship --head def
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "released: PR 5 (until:review-ship, held 1h)" ]
  gate 5
  [ "$status" -eq 1 ]
  # Another PR's repair is its own: PR 6 ships while PR 7 is in flight.
  rl repair --pr 7 --session trig_c >/dev/null
  run rl record --pr 6 --verdict ship
  [ "$status" -eq 0 ]
}

@test "settle: a closing comment since the dispatch ends the repair; none or an older one leaves it in flight" {
  rl repair --pr 5 --session trig_a >/dev/null
  rl repair --pr 6 --session trig_b >/dev/null
  rl repair --pr 7 --session trig_c >/dev/null
  comment 5 2026-09-27T12:30:00Z $'REPAIR-END done:\n- fixed the test'
  comment 6 2026-09-27T11:00:00Z "REPAIR-END done: an earlier repair"
  # PR 7's comments cannot be read: it stays in flight, reported unknown, exit 7 after the rest.
  run rl settle
  [ "$status" -eq 7 ]
  [ "${lines[0]}" = "settled #5 session:trig_a https://github.com/o/r/pull/5#issuecomment-9" ]
  [ "${lines[1]}" = "inflight #6 session:trig_b since:2026-09-27T12:00:00Z" ]
  [ "${lines[2]}" = "unknown #7 session:trig_c comments unreadable" ]
  [[ "$(cat "$FX/calls")" == *"api repos/o/r/issues/5/comments?per_page=100&since=2026-09-27T12:00:00Z"* ]]
  [ "$(rl latest --pr 5 | cut -f3,5,6)" = $'repaired\tclosing comment https://github.com/o/r/pull/5#issuecomment-9\ttrig_a' ]
  run rl inflight
  [ "$output" = "$(printf '6\ttrig_b\t2026-09-27T12:00:00Z\n7\ttrig_c\t2026-09-27T12:00:00Z')" ]
  # A SUPERSEDED-CANDIDATE comment ends a repair too; settle --pr reads only that PR.
  comment 6 2026-09-27T12:10:00Z "  SUPERSEDED-CANDIDATE: main ships it another way"
  : >"$FX/calls"
  run rl settle --pr 6
  [ "$status" -eq 0 ]
  [ "$output" = "settled #6 session:trig_b https://github.com/o/r/pull/6#issuecomment-9" ]
  [ "$(grep -c 'issues/7/' "$FX/calls" || true)" -eq 0 ]
  # A comment that only mentions the marker mid-text is not a closing comment.
  comment 7 2026-09-27T12:10:00Z "progress: REPAIR-END comes later"
  run rl settle
  [ "$status" -eq 0 ]
  [ "$output" = "inflight #7 session:trig_c since:2026-09-27T12:00:00Z" ]
}

@test "cloud-dispatch.sh: a recorded repair marks the PR repairing; a second repair is refused while it runs" {
  run cd_ record --issue 5 --kind repair --trigger trig_r --run-at 2026-09-27T12:01:20Z
  [ "$status" -eq 2 ]
  [[ "$output" == *"record --kind repair needs --pr"* ]]
  [ ! -s "$ST/cloud-sessions.tsv" ]
  run cd_ created --issue 5 --kind repair <<<'{"trigger_id":"trig_r"}'
  [ "$status" -eq 2 ]
  run cd_ record --issue 5 --kind repair --pr 31 --trigger trig_r --run-at 2026-09-27T12:01:20Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recorded 5 trig_r 2026-09-27T12:01:20Z repair" ]
  [ "${lines[1]}" = "repairing PR #31 session trig_r: held, and no ship verdict, until the repair ends" ]
  [ "$(rl latest --pr 31 | cut -f3,5,6)" = $'repairing\tcloud repair of issue #5\ttrig_r' ]
  grep -q '^31 until:review-ship' "$ST/holds"
  run cd_ payload --issue 5 --pr 31 --env env_1 --source u --base main --brief-ref repair
  [ "$status" -eq 3 ]
  [[ "$output" == *"a repair is already in flight on PR #31 (session trig_r since 2026-09-27T12:00:00Z)"* ]]
  # A create whose mark fails (another session in flight) is exit 9: the row is written.
  run cd_ record --issue 5 --kind repair --pr 31 --trigger trig_s --run-at 2026-09-27T12:02:00Z
  [ "$status" -eq 9 ]
  [[ "$output" == *"PR #31 is not marked repairing; run review-ledger.sh repair --pr 31 --session trig_s"* ]]
  [ "$(grep -c trig_s "$ST/cloud-sessions.tsv")" -eq 1 ]
  # Once it ended, the next repair dispatches; created --kind repair --pr marks it too.
  rl repaired --pr 31 >/dev/null
  run cd_ payload --issue 5 --pr 31 --env env_1 --source u --base main --brief-ref repair
  [ "$status" -eq 0 ]
  run cd_ created --issue 5 --kind repair --pr 31 --run-at 2026-09-27T12:03:00Z <<<'{"trigger_id":"trig_t"}'
  [ "$status" -eq 0 ]
  [ "$(rl inflight --pr 31 | cut -f2)" = trig_t ]
  # An unreadable review ledger refuses the repair payload (exit 7).
  mv "$ST/reviews.tsv" "$ST/rows"; mkdir "$ST/reviews.tsv"
  run cd_ payload --issue 5 --pr 31 --env env_1 --source u --base main --brief-ref repair
  [ "$status" -eq 7 ]
  rmdir "$ST/reviews.tsv"; mv "$ST/rows" "$ST/reviews.tsv"
}

@test "triage-tick snapshot settles repairs, names the settled ones and those in flight too long" {
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$(grep -c '^repairs ' <<<"$output" || true)" -eq 0 ]
  export ORCHESTRATE_NOW=1790460000   # 2026-09-26T22:00:00Z
  rl repair --pr 5 --session trig_a >/dev/null
  rl repair --pr 6 --session trig_b >/dev/null
  export ORCHESTRATE_NOW=1790510400
  rl repair --pr 7 --session trig_c >/dev/null
  comment 5 2026-09-27T11:00:00Z "REPAIR-END blocked: no device"
  echo '[]' >"$FX/comments-6.json"
  echo '[]' >"$FX/comments-7.json"
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main --hold-hours 12
  [[ "${lines[0]}" == "verdict act "*"repaired=1"*"repair-stale=1"* ]]
  [ "$(grep -x 'repairs inflight=#6,#7 settled=#5 unknown=-' <<<"$output" || true)" != "" ]
  [ "$(grep -x 'repair-stale #6 session:trig_b since:2026-09-26T22:00:00Z' <<<"$output" || true)" != "" ]
  [ "$(rl latest --pr 5 | cut -f3)" = repaired ]
}

@test "doctrine: the repair brief closes with REPAIR-END, and the roles say how a repair ends" {
  B="$SCRIPTS/../briefs/repair.md"
  [[ "$(sed -n 1p "$B")" == "<!-- waaagh-brief repair v"* ]]
  has "$B" '"REPAIR-END done:"'
  has "$B" '"REPAIR-END blocked:"'
  has "$SCRIPTS/../roles/cloud-dispatch.md" "record --kind repair --pr P"
  has "$SCRIPTS/../roles/cloud-dispatch.md" "review-ledger.sh repaired --pr P --session <trigger>"
  has "$SCRIPTS/../roles/triage-tick.md" "repair-stale=<m>"
  has "$SCRIPTS/../roles/merge-bot.md" "repairing"
  has "$SCRIPTS/../SKILL.md" "--kind repair --pr N"
}
