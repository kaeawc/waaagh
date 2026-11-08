#!/usr/bin/env bats
# Self-test for the regression and device gates (#75): device-recheck.sh (the needs-device-recheck
# hold) and claim-check.sh (confirm delegated claims before relaying them), with a stubbed gh; and
# the doctrine that points at them.
# Run: bats scripts/regression-gates.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_DEVICE_REGRESSION_LABELS ORCHESTRATE_DEVICE_HOLD_LABEL
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  pr_body "Fixes the Duo inner panel. Closes #11, part of #12, refs #13"
  issue 11 manual-test-regression
  issue 12 bug
  issue 13 manual-test-regression
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
case "$all" in
  "pr view 7 "*) [ ! -f "$FX/pr-fail" ] || { echo "HTTP 502" >&2; exit 1; }; cat "$FX/pr.json" ;;
  "pr view 9 "*) echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null}' ;;
  "pr view 8 "*) echo '{"state":"MERGED","mergedAt":"2026-11-07T10:00:00Z","mergeCommit":{"oid":"feedface12345"}}' ;;
  "api repos/o/r/issues/"[0-9]*"/comments"*|"api --paginate repos/o/r/issues/"*) cat "$FX/comments.json" ;;
  "api repos/o/r/issues/"*) n=${all#api repos/o/r/issues/}; n=${n%% *}; f="$FX/issue-$n.json"
    [ -f "$f" ] || { echo "HTTP 404" >&2; exit 1; }; cat "$f" ;;
  "label create"*) ;;
  "pr edit 7 --repo o/r --add-label "*) l=${all##* }; jq --arg l "$l" '.labels += [{name: $l}]' "$FX/pr.json" >"$FX/t" && mv "$FX/t" "$FX/pr.json" ;;
  "pr edit 7 --repo o/r --remove-label "*) l=${all##* }; jq --arg l "$l" '.labels |= map(select(.name != $l))' "$FX/pr.json" >"$FX/t" && mv "$FX/t" "$FX/pr.json" ;;
  "api -X POST repos/o/r/issues/"*) n=${all#api -X POST repos/o/r/issues/}; n=${n%%/*}
    [ ! -f "$FX/post-fail-$n" ] || { echo "HTTP 502" >&2; exit 1; }; echo "$n ${all#*body=}" >>"$FX/posted" ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# pr_body TEXT [head] [labels-json]
pr_body() {
  jq -n --arg b "$1" --arg h "${2:-$HEAD}" --argjson l "${3:-[]}" \
    '{state: "OPEN", headRefOid: $h, body: $b, labels: $l}' >"$FX/pr.json"
}
issue() { jq -n --arg l "$2" '{state: "open", labels: [{name: $l}]}' >"$FX/issue-$1.json"; }
dr() { "$SCRIPTS/device-recheck.sh" "$1" --repo o/r --pr 7 "${@:2}"; }
labels() { jq -r '[.labels[].name] | join(",")' "$FX/pr.json"; }

@test "check: a PR closing a manual-test regression is held until a recheck is recorded" {
  run dr check
  [ "$status" -eq 3 ]
  [ "$output" = "held: PR 7 fixes device-found regression(s) #11 and no device recheck is recorded" ]
  ! grep -q "issues/13" "$FX/calls"   # "refs #13" is not a fixing reference
  ! grep -qE "label create|pr edit|POST" "$FX/calls"
}

@test "check: no regression issue and no label is clear; an unreadable PR or issue is unverified" {
  pr_body "Closes #12"
  run dr check
  [ "$status" -eq 0 ] && [ "$output" = "clear: PR 7 fixes no device-found regression and has no device hold" ]
  pr_body "Closes #99"
  run dr check
  [ "$status" -eq 4 ] && [ "$output" = "unverified: issue 99 could not be read" ]
  touch "$FX/pr-fail"
  run dr check
  [ "$status" -eq 4 ] && [ "$output" = "unverified: PR 7 could not be read" ]
}

@test "check: the hold label alone holds, and the regression labels are configurable" {
  pr_body "Closes #12" "$HEAD" '[{"name":"needs-device-recheck"}]'
  run dr check
  [ "$status" -eq 3 ] && [ "$output" = "held: PR 7 carries needs-device-recheck" ]
  pr_body "Closes #12"
  run dr check --regression-label bug
  [ "$status" -eq 3 ] && [[ "$output" == *"regression(s) #12 "* ]]
  ORCHESTRATE_DEVICE_REGRESSION_LABELS=bug,other run dr check
  [ "$status" -eq 3 ]
}

@test "scan: labels the PR, writes the record, and list shows it; a rerun stays held without duplicates" {
  run dr scan
  [ "$status" -eq 3 ]
  [[ "$output" == "held: PR 7 needs a device recheck (PR 7 fixes device-found regression(s) #11"* ]]
  [ "$(labels)" = needs-device-recheck ]
  [ "$(jq -c '[.state, .issues]' "$STATE/device-recheck/pr7.json")" = '["held",[11]]' ]
  run "$SCRIPTS/device-recheck.sh" list --repo o/r
  [ "$output" = "$(printf '7\theld\t#11\t2026-09-27T12:00:00Z')" ]
  run dr scan
  [ "$status" -eq 3 ]
  [ "$(labels)" = needs-device-recheck ]
  [ "$(grep -c 'add-label' "$FX/calls")" -eq 1 ]
}

@test "scan --dry-run writes nothing; a clear PR is left alone" {
  run dr scan --dry-run
  [ "$status" -eq 3 ] && [[ "$output" == *"(dry run)" ]]
  [ ! -f "$STATE/device-recheck/pr7.json" ] && [ -z "$(labels)" ]
  pr_body "Closes #12"
  run dr scan
  [ "$status" -eq 0 ] && [[ "$output" == clear:* ]]
  ! grep -q "pr edit" "$FX/calls"
}

@test "hold: sets the hold by hand with a reason and extra issues" {
  pr_body "Closes #12"
  run dr hold --reason "found by mt0091c on the Duo" --issue 12
  [ "$status" -eq 0 ]
  [ "$(labels)" = needs-device-recheck ]
  [ "$(jq -c '[.state, .issues, .reason]' "$STATE/device-recheck/pr7.json")" = '["held",[12],"found by mt0091c on the Duo"]' ]
  run dr hold
  [ "$status" -eq 2 ]
}

@test "pass: refused on a head that is not the PR's current head" {
  dr scan || true
  run dr pass --head 1234567890 --device "Duo emulator-5554" --evidence "sendKeys ok"
  [ "$status" -eq 3 ]
  [[ "$output" == "refused: the recheck ran on 123456789 but PR 7's head is abcdef123; recheck the current head" ]]
  [ ! -f "$FX/posted" ]
  [ "$(labels)" = needs-device-recheck ]
}

@test "pass: posts on the PR and each regression issue, lifts the hold; check is then clear" {
  dr scan || true
  run dr pass --head "${HEAD:0:9}" --device "Duo emulator-5554" --evidence "mt0091c sendKeys + systemTray pass"
  [ "$status" -eq 0 ]
  [ "$output" = "lifted: device recheck passed on abcdef123; posted on #7,#11" ]
  [ "$(awk '/^[0-9]+ [*][*]/{print $1}' "$FX/posted" | paste -sd, -)" = "7,11" ]
  grep -q "Device recheck passed\*\* on \`abcdef123456\` (PR #7, Duo emulator-5554): mt0091c" "$FX/posted"
  grep -q "waaagh:device-recheck verdict=pass head=$HEAD" "$FX/posted"
  [ -z "$(labels)" ]
  run dr check
  [ "$status" -eq 0 ] && [ "$output" = "clear: device recheck of PR 7 passed on abcdef123 (Duo emulator-5554)" ]
  run "$SCRIPTS/device-recheck.sh" list --repo o/r
  [ -z "$output" ]
}

@test "pass: a new head after the pass needs a new recheck; scan re-holds it" {
  dr scan || true
  dr pass --head "$HEAD" --device d --evidence e
  pr_body "Fixes the Duo inner panel. Closes #11" 1111111222222233333334444444555555566666
  run dr check
  [ "$status" -eq 3 ]
  [ "$output" = "held: device recheck of PR 7 passed on abcdef123, but its head is now 111111122; recheck the new head" ]
  run dr scan
  [ "$status" -eq 3 ]
  [ "$(labels)" = needs-device-recheck ]
  [ "$(jq -r .state "$STATE/device-recheck/pr7.json")" = held ]
}

@test "pass: a failed post exits 5 and the rerun posts only what is missing" {
  dr scan || true
  touch "$FX/post-fail-11"
  run dr pass --head "$HEAD" --device d --evidence e
  [ "$status" -eq 5 ] && [ "$output" = "error: could not post the result on #11; rerun" ]
  [ "$(labels)" = needs-device-recheck ]
  rm "$FX/post-fail-11"
  run dr pass --head "$HEAD" --device d --evidence e
  [ "$status" -eq 0 ]
  [ "$(awk '/^[0-9]+ [*][*]/{print $1}' "$FX/posted" | paste -sd, -)" = "7,11" ]
}

@test "fail: posts the failure and keeps the hold" {
  run dr fail --head "$HEAD" --device "Duo" --evidence "systemTray still missing"
  [ "$status" -eq 0 ]
  [ "$output" = "held: device recheck failed on abcdef123; posted on #7,#11" ]
  grep -q "Device recheck FAILED" "$FX/posted"
  [ "$(labels)" = needs-device-recheck ]
  run dr check
  [ "$status" -eq 3 ]
  run "$SCRIPTS/device-recheck.sh" list --repo o/r
  [[ "$output" == "$(printf '7\tfailed\t#11\t')"* ]]
}

@test "claim-check merged: confirmed for a merged PR, refuted for an open one" {
  run "$SCRIPTS/claim-check.sh" merged --repo o/r --pr 8
  [ "$status" -eq 0 ] && [ "$output" = "confirmed: PR 8 merged 2026-11-07T10:00:00Z as feedface1" ]
  run "$SCRIPTS/claim-check.sh" merged --repo o/r --pr 9
  [ "$status" -eq 3 ] && [ "$output" = "refuted: PR 9 is OPEN, not merged" ]
  touch "$FX/pr-fail"
  run "$SCRIPTS/claim-check.sh" merged --repo o/r --pr 7
  [ "$status" -eq 4 ] && [[ "$output" == unverified:* ]]
}

@test "claim-check closed and open: state and state reason from the issue" {
  jq -n '{state: "closed", state_reason: "completed", closed_at: "2026-11-07T11:00:00Z"}' >"$FX/issue-20.json"
  run "$SCRIPTS/claim-check.sh" closed --repo o/r --issue 20
  [ "$status" -eq 0 ] && [ "$output" = "confirmed: issue 20 is closed (completed) at 2026-11-07T11:00:00Z" ]
  run "$SCRIPTS/claim-check.sh" closed --repo o/r --issue 20 --reason not_planned
  [ "$status" -eq 3 ] && [ "$output" = "refuted: issue 20 is closed as completed, not not_planned" ]
  run "$SCRIPTS/claim-check.sh" closed --repo o/r --issue 12
  [ "$status" -eq 3 ] && [ "$output" = "refuted: issue 12 is open" ]
  run "$SCRIPTS/claim-check.sh" open --repo o/r --issue 20
  [ "$status" -eq 3 ]
  run "$SCRIPTS/claim-check.sh" closed --repo o/r --pr 20
  [ "$status" -eq 2 ]
}

@test "claim-check evidence: finds the newest matching comment, honouring --since" {
  printf '[{"body":"verified on Duo: pass","html_url":"u1","created_at":"2026-11-06T00:00:00Z"},{"body":"no","html_url":"u2","created_at":"2026-11-07T00:00:00Z"}]\n[{"body":"verified on Duo: pass again","html_url":"u3","created_at":"2026-11-07T05:00:00Z"}]\n' >"$FX/comments.json"
  run "$SCRIPTS/claim-check.sh" evidence --repo o/r --pr 7 --match "verified on Duo"
  [ "$status" -eq 0 ] && [ "$output" = "confirmed: PR 7 has the evidence comment u3 (2026-11-07T05:00:00Z)" ]
  run "$SCRIPTS/claim-check.sh" evidence --repo o/r --issue 7 --match "verified on Duo" --since 2026-11-08T00:00:00Z
  [ "$status" -eq 3 ] && [ "$output" = 'refuted: no comment on issue 7 contains "verified on Duo" since 2026-11-08T00:00:00Z' ]
}

@test "claim-check device-clear: 'no device check needed' is refuted for a device-regression fix" {
  run "$SCRIPTS/claim-check.sh" device-clear --repo o/r --pr 7
  [ "$status" -eq 3 ] && [ "$output" = "refuted: PR 7 fixes device-found regression(s) #11 and no device recheck is recorded" ]
  pr_body "Closes #12"
  run "$SCRIPTS/claim-check.sh" device-clear --repo o/r --pr 7
  [ "$status" -eq 0 ] && [[ "$output" == "confirmed: PR 7 fixes no device-found regression"* ]]
}

@test "help covers exactly the header" {
  for s in device-recheck claim-check; do
    run "$SCRIPTS/$s.sh" -h
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "^# Exit:"
    ! printf '%s\n' "$output" | grep -q "set -euo"
  done
}

@test "doctrine: regression gates are documented and pointed at (#75)" {
  f="$ROOT/regression-gates.md"
  grep -q "regression of existing behaviour" "$f"
  grep -q "device-recheck.sh" "$f" && grep -q "needs-device-recheck" "$f"
  grep -q "claim-check.sh" "$f"
  grep -q "regression-gates.md" "$ROOT/SKILL.md"
  grep -q "regression" "$ROOT/roles/review.md"
  grep -q "device-recheck.sh check" "$ROOT/roles/merge-bot.md"
  grep -q "regression-gates.md" "$ROOT/roles/pr-doctor.md"
  grep -q "claim-check.sh" "$ROOT/reporting.md"
}
