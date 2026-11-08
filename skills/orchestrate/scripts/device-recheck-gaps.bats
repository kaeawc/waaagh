#!/usr/bin/env bats
# device-recheck.sh paths the other suites do not reach: check on a held or failed record, a hold
# label that cannot be added (exit 5, no record written), and a pass whose label removal fails
# (exit 5, the record not marked passed). Stubbed gh. Run: bats scripts/device-recheck-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_DEVICE_REGRESSION_LABELS ORCHESTRATE_DEVICE_HOLD_LABEL
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"; REC="$STATE/device-recheck/pr5.json"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  HEAD=abcdef0123456789abcdef0123456789abcdef01
  pr_json '[]'
  # Switches in $FX: label-fails (gh label create), edit-fails (gh pr edit).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "pr view 5 "*) cat "$FX/pr.json" ;;
  "api repos/o/r/issues/3"*) echo '{"labels":[{"name":"device-regression"}]}' ;;
  "label create"*) [ ! -f "$FX/label-fails" ] || exit 1 ;;
  "pr edit"*) [ ! -f "$FX/edit-fails" ] || exit 1 ;;
  "api -X POST repos/o/r/issues/"*) ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

pr_json() { # labels JSON
  jq -n --arg h "$HEAD" --argjson l "$1" '{state: "OPEN", headRefOid: $h, body: "Fixes #3", labels: $l}' >"$FX/pr.json"
}
dr() { run "$SCRIPTS/device-recheck.sh" "$1" --repo o/r --pr 5 "${@:2}"; }

@test "check: a held record holds the PR and names the hold's reason" {
  mkdir -p "${REC%/*}"
  echo '{"pr":5,"state":"held","reason":"crash on rotate"}' >"$REC"
  dr check
  [ "$status" -eq 3 ]
  [ "$output" = "held: PR 5 is held for a device recheck (crash on rotate)" ]
}

@test "check: a failed record holds the PR and names the head it failed on" {
  mkdir -p "${REC%/*}"
  echo '{"pr":5,"state":"failed","head":"1111111111222222"}' >"$REC"
  dr check
  [ "$status" -eq 3 ]
  [ "$output" = "held: the device recheck of PR 5 failed on 111111111" ]
}

@test "scan: a hold label that cannot be added is a write failure (exit 5) and no record is written" {
  touch "$FX/label-fails"
  dr scan
  [ "$status" -eq 5 ]
  [ "$output" = "error: could not label PR 5 needs-device-recheck; rerun" ]
  [ ! -e "$REC" ]
  [ "$(grep -c '^pr edit' "$FX/calls" || true)" -eq 0 ]
}

@test "pass: a hold label that cannot be removed is a write failure (exit 5); the record is not passed" {
  pr_json '[{"name":"needs-device-recheck"}]'
  touch "$FX/edit-fails"
  dr pass --head "$HEAD" --device "Pixel 8" --evidence "rotate 20x, no crash"
  [ "$status" -eq 5 ]
  [ "$output" = "error: could not remove needs-device-recheck from PR 5; rerun" ]
  [ "$(jq -r '.state // "none"' "$REC")" != passed ]
  [ ! -e "$STATE/device-recheck.log" ]
}
