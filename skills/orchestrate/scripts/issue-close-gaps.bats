#!/usr/bin/env bats
# issue-close.sh paths the other suites do not reach: an unknown --as, a custom --keep-label, the
# verified close policy with --platforms none, and a close that fails before any comment (exit 5).
# Stubbed gh. Run: bats scripts/issue-close-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$STATE"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  echo '{"state":"OPEN","labels":[{"name":"wip"}],"comments":[]}' >"$FX/issue.json"
  # Switches in $FX: close-fails.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "issue view 3 "*) cat "$FX/issue.json" ;;
  "pr view 9 "*) echo '{"state":"MERGED"}' ;;
  "issue close"*) [ ! -f "$FX/close-fails" ] || { echo "HTTP 502" >&2; exit 1; } ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

ic() { run "$SCRIPTS/issue-close.sh" --repo o/r --issue 3 --evidence "src/a.ts:10 no longer calls the old path" "$@"; }
closes() { grep -c '^issue close' "$FX/calls" 2>/dev/null || true; }

@test "an unknown --as is refused (exit 3) and nothing is closed" {
  ic --as wontfix
  [ "$status" -eq 3 ]
  [ "$output" = "refused: --as must be fixed, duplicate or completed" ]
  [ "$(closes)" -eq 0 ]
}

@test "--keep-label replaces the default keep labels" {
  ic --as fixed --pr 9 --keep-label wip
  [ "$status" -eq 3 ]
  [ "$output" = "refused: issue 3 is labelled wip" ]
  [ "$(closes)" -eq 0 ]
}

@test "close policy verified with --platforms none needs no device evidence" {
  echo '{"close_policy":"verified"}' >"$STATE/campaign.json"
  ic --as completed --pr 9 --platforms none --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No device-facing platform is touched."*"Close policy: verified."* ]]
  [ "$(closes)" -eq 0 ]
}

@test "a close that fails with no comment posted is a failed close (exit 5), journaled failed" {
  touch "$FX/close-fails"
  ic --as fixed --pr 9
  [ "$status" -eq 5 ]
  [ "$output" = "close failed (exit 1)" ]
  [ "$(jq -r .state "$STATE/ops/close-issue3.json")" = failed ]
  [ ! -e "$STATE/hygiene-actions.log" ]
}
