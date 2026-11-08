#!/usr/bin/env bats
# Close policy, owner-decision records, batched decisions, owner steps and lane stop-on-close
# (issue-close.sh --as completed, campaign.sh close-policy, decision.sh, lane-claim.sh on-issue and
# closed) against a stubbed gh. Run: bats close-policy.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0   # 2026-09-27T12:00:00Z
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Per issue N: $FX/labels-N (JSON array of names), $FX/comments-N (JSON array of {body}),
# $FX/closed-N (present = CLOSED), $FX/unreadable-N (views fail). $FX/pr.json for pr view.
echo "$*" >>"$FX/calls"
n=$3
case "$*" in
  "issue view"*)
    [ -f "$FX/unreadable-$n" ] && { echo "HTTP 502" >&2; exit 1; }
    jq -n --argjson l "$(cat "$FX/labels-$n" 2>/dev/null || echo '[]')" \
      --argjson c "$(cat "$FX/comments-$n" 2>/dev/null || echo '[]')" \
      --arg s "$([ -f "$FX/closed-$n" ] && echo CLOSED || echo OPEN)" \
      '{state: $s, labels: ($l | map({name: .})), comments: $c}' ;;
  "issue comment"*)
    [ -f "$FX/comment-fails" ] && exit 1
    body=""; while [ $# -gt 0 ]; do [ "$1" = --body ] && body=$2; shift; done
    jq --arg b "$body" '. + [{body: $b}]' "$FX/comments-$n" 2>/dev/null >"$FX/c.tmp" || jq -n --arg b "$body" '[{body: $b}]' >"$FX/c.tmp"
    mv "$FX/c.tmp" "$FX/comments-$n" ;;
  "issue edit"*)
    [ -f "$FX/edit-fails" ] && exit 1
    l=""; while [ $# -gt 0 ]; do [ "$1" = --remove-label ] && l=$2; shift; done
    jq --arg l "$l" 'map(select(. != $l))' "$FX/labels-$n" >"$FX/l.tmp" && mv "$FX/l.tmp" "$FX/labels-$n" ;;
  "issue close"*)
    body=""; while [ $# -gt 0 ]; do [ "$1" = --comment ] && body=$2; shift; done
    if [ -n "$body" ]; then
      jq --arg b "$body" '. + [{body: $b}]' "$FX/comments-$n" 2>/dev/null >"$FX/c.tmp" || jq -n --arg b "$body" '[{body: $b}]' >"$FX/c.tmp"
      mv "$FX/c.tmp" "$FX/comments-$n"
    fi
    touch "$FX/closed-$n" ;;
  "pr view"*) cat "$FX/pr.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo '{"state":"MERGED"}' >"$FX/pr.json"
  E="PR 9 adds the retry and its unit test; the defect no longer reproduces"
}

close_completed() { run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as completed --evidence "$E" "$@"; }

@test "campaign close-policy defaults to owner-only, is set in the ledger and refuses other values" {
  run "$SCRIPTS/campaign.sh" close-policy --repo o/r
  [ "$status" -eq 0 ] && [ "$output" = owner-only ]
  run "$SCRIPTS/campaign.sh" close-policy verified --repo o/r
  [ "$output" = verified ]
  [ "$(jq -r .close_policy "$ST/campaign.json")" = verified ]
  run "$SCRIPTS/campaign.sh" close-policy sometimes --repo o/r
  [ "$status" -eq 2 ]
  run "$SCRIPTS/campaign.sh" wrap-up verified --repo o/r
  [ "$status" -eq 2 ]
  [ "$(jq -r .close_policy "$ST/campaign.json")" = verified ]
}

@test "owner-only: completed needs an owner decision recorded on the issue" {
  close_completed --pr 9 --platforms none
  [ "$status" -eq 3 ]
  [[ "$output" == *"owner-only: no owner decision"* ]]
  run ! grep -q 'issue close' "$FX/calls"
  echo '[{"body":"Owner decision (2026-09-26): close it once #9 merges.\n\nmore"}]' >"$FX/comments-5"
  close_completed --pr 9
  [ "$status" -eq 0 ]
  grep -q 'issue close 5 --repo o/r --reason completed' "$FX/calls"
  body=$(jq -r '.[-1].body' "$FX/comments-5")
  [[ "$body" == *"Owner decision (2026-09-26): close it once #9 merges."* ]]
  [[ "$body" == *"Close policy: owner-only."* ]]
  [[ "$body" != *"more"* ]]
}

@test "verified: a merged PR plus device evidence for every touched platform closes; gaps are refused" {
  "$SCRIPTS/campaign.sh" close-policy verified --repo o/r >/dev/null
  close_completed --platforms android
  [ "$status" -eq 3 ] && [[ "$output" == *"needs a merged --pr"* ]]
  close_completed --pr 9
  [ "$status" -eq 3 ] && [[ "$output" == *"needs --platforms"* ]]
  close_completed --pr 9 --platforms android,ios --device "android=Pixel 8, API 35: retry shown, PASS"
  [ "$status" -eq 3 ] && [[ "$output" == *"no device evidence for ios"* ]]
  echo '{"state":"OPEN"}' >"$FX/pr.json"
  close_completed --pr 9 --platforms none
  [ "$status" -eq 3 ] && [[ "$output" == *"not merged"* ]]
  echo '{"state":"MERGED"}' >"$FX/pr.json"
  run ! grep -q 'issue close' "$FX/calls"
  close_completed --pr 9 --platforms android,ios --device "android=Pixel 8, API 35: retry shown, PASS" \
    --device "ios=iPhone 15 sim, iOS 18: retry shown, PASS"
  [ "$status" -eq 0 ]
  body=$(jq -r '.[-1].body' "$FX/comments-5")
  [[ "$body" == *"- android: Pixel 8"* && "$body" == *"- ios: iPhone 15"* && "$body" == *"Close policy: verified."* ]]
}

@test "needs-decision is a keep label: an undecided issue is never closed" {
  echo '["needs-decision"]' >"$FX/labels-5"
  echo '[{"body":"Owner decision (2026-09-26): yes"}]' >"$FX/comments-5"
  close_completed
  [ "$status" -eq 3 ] && [[ "$output" == *"labelled needs-decision"* ]]
}

@test "a close prints a stop line for each active lane on the issue; lane-claim closed finds any closed issue" {
  printf 'wt-a\twork/5-x\t5,6\ta.ts\tcodex\tactive\nwt-b\twork/7-y\t7\tb.ts\tsol\tactive\nwt-c\twork/5-z\t5\tc.ts\tsol\tmerged\n' >"$ST/lanes.tsv"
  run "$SCRIPTS/lane-claim.sh" on-issue --issues 5 --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "stop: lane wt-a branch work/5-x agent codex issue 5" ]
  run "$SCRIPTS/lane-claim.sh" on-issue --issues 8 --repo o/r
  [ "$status" -eq 0 ] && [ -z "$output" ]
  echo '[{"body":"Owner decision (2026-09-26): yes, close"}]' >"$FX/comments-5"
  close_completed
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed 5 as completed"* ]]
  [[ "$output" == *"stop: lane wt-a branch work/5-x agent codex issue 5"* ]]
  [[ "$output" != *"wt-c"* ]]
  # Closed some other way (here: issue 7 by its merged PR): `closed` still finds the lane.
  touch "$FX/closed-7"
  run "$SCRIPTS/lane-claim.sh" closed --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"stop: lane wt-a branch work/5-x agent codex issue 5"* ]]
  [[ "$output" == *"stop: lane wt-b branch work/7-y agent sol issue 7"* ]]
  touch "$FX/unreadable-6"
  run "$SCRIPTS/lane-claim.sh" closed --repo o/r
  [ "$status" -eq 4 ]
  [[ "$output" == *"wt-b"* && "$output" == *"issue 6 could not be read"* ]]
  "$SCRIPTS/lane-claim.sh" set --worktree wt-a --status closed --repo o/r
  rm -f "$FX/unreadable-6"
  run "$SCRIPTS/lane-claim.sh" closed --repo o/r
  [ "$output" = "stop: lane wt-b branch work/7-y agent sol issue 7" ]
}

@test "decision record posts the format once, removes needs-decision and ticks decisions.md" {
  echo '["needs-decision","bug"]' >"$FX/labels-5"
  printf -- '- [ ] #5 keep the old API? — keep / drop — recommend: drop — blocks #9\n- [ ] #50 other — a / b — blocks nothing\n' >"$ST/decisions.md"
  rec() { run "$SCRIPTS/decision.sh" record --repo o/r --issue 5 --text "drop the old API" \
    --step "Create the PLAY_UPLOAD_KEY secret (name only) in repo settings" --step "Grant the release account access"; }
  rec
  [ "$status" -eq 0 ]
  body=$(jq -r '.[0].body' "$FX/comments-5")
  [[ "$body" == "Owner decision (2026-09-27): drop the old API"* ]]
  [[ "$body" == *$'Owner steps:\n- [ ] Create the PLAY_UPLOAD_KEY secret'* ]]
  [ "$(jq -c . "$FX/labels-5")" = '["bug"]' ]
  grep -q '^- \[x\] #5 keep' "$ST/decisions.md"
  grep -q '^- \[ \] #50 other' "$ST/decisions.md"
  grep -q 'issue=5' "$ST/decisions.log"
  # A rerun posts nothing new.
  rec
  [ "$status" -eq 0 ]
  [ "$(jq length "$FX/comments-5")" -eq 1 ]
  # Comment posted but the label edit failed: exit 5, and the rerun finishes without a second comment.
  echo '["needs-decision"]' >"$FX/labels-6"; touch "$FX/edit-fails"
  run "$SCRIPTS/decision.sh" record --repo o/r --issue 6 --text "ship it" --date 2026-09-20
  [ "$status" -eq 5 ]
  rm "$FX/edit-fails"
  run "$SCRIPTS/decision.sh" record --repo o/r --issue 6 --text "ship it" --date 2026-09-20
  [ "$status" -eq 0 ]
  [ "$(jq length "$FX/comments-6")" -eq 1 ] && [ "$(jq -c . "$FX/labels-6")" = '[]' ]
  run "$SCRIPTS/decision.sh" record --repo o/r --issue 6 --text "x" --date 26-9-20
  [ "$status" -eq 2 ]
}

@test "decision batch asks one question with the recommendations first and every item listed" {
  cat >"$ST/decisions.md" <<'MD'
# decisions
- [ ] #12 keep the legacy sync? — keep / drop — recommend: drop — blocks #30
- [x] #13 answered already — a / b — recommend: a — blocks nothing
- [ ] #14 which retry cap? — 3 / 5 — Recommendation: 3 — blocks #31
- [ ] #15 rename the setting? — yes / no — blocks nothing
MD
  run "$SCRIPTS/decision.sh" batch --repo o/r
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3 decisions are pending. How should I settle them?" ]
  [[ "${lines[1]}" == "1. Apply all my recommendations (recommended), for the 2 that have one:" ]]
  [ "${lines[2]}" = "   - #12 keep the legacy sync? → drop" ]
  [ "${lines[3]}" = "   - #14 which retry cap? → 3" ]
  [ "${lines[4]}" = "2. One at a time" ]
  [ "${lines[5]}" = "3. Leave them for now" ]
  [[ "$output" == *"   - #15 rename the setting?"* ]]
  [[ "$output" != *"#13"* ]]
  : >"$ST/decisions.md"
  run "$SCRIPTS/decision.sh" batch --repo o/r
  [ "$output" = "no open decisions" ]
}

@test "decision steps extracts the unchecked owner steps from decision records" {
  jq -n '[{body: "unrelated\n- [ ] not a step"},
          {body: "Owner decision (2026-09-26): ship on device\r\n\r\nOwner steps:\r\n- [ ] Add the APPLE_ID secret name\r\n- [x] Done already\r\n- [ ] Enrol the test account\r\n\r\n- [ ] after the list\r\n<!-- waaagh:decision issue=5 key=1 -->"}]' >"$FX/comments-5"
  echo '[{"body":"Owner decision (2026-09-25): no steps here"}]' >"$FX/comments-6"
  run "$SCRIPTS/decision.sh" steps --issues 5,6 --repo o/r
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "- [ ] #5 Add the APPLE_ID secret name" ]
  [ "${lines[1]}" = "- [ ] #5 Enrol the test account" ]
  [ "${#lines[@]}" -eq 2 ]
  touch "$FX/unreadable-6"
  run "$SCRIPTS/decision.sh" steps --issues 6 --repo o/r
  [ "$status" -eq 4 ]
  [[ "$output" == *"no owner steps"* ]]
}

@test "doctrine: owner-decisions.md covers the policy, record format, batch, steps and stop-on-close" {
  D="$ROOT/skills/orchestrate/owner-decisions.md"
  grep -q 'close-policy' "$D"
  grep -q 'owner-only' "$D"
  grep -q 'verified' "$D"
  grep -q 'Owner decision (YYYY-MM-DD):' "$D"
  grep -q 'decision.sh"\? batch' "$D"
  grep -q 'decision.sh"\? steps' "$D"
  grep -q 'lane-claim.sh" closed' "$D"
  grep -q 'owner-decisions.md' "$ROOT/skills/orchestrate/SKILL.md"
  grep -q 'decision.sh' "$ROOT/README.md"
}
