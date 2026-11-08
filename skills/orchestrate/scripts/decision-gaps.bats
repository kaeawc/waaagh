#!/usr/bin/env bats
# decision.sh paths the other suites do not reach: an unknown subcommand, record --dry-run, and the
# record failures: the issue unreadable (exit 9), the comment sent but not read back (exit 9), and
# the comment missing on readback (exit 5). Stubbed gh. Run: bats scripts/decision-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Switches in $FX: view-fails (every read), view-fails-after (reads after the first),
  # comment-fails.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "issue view"*)
    n=$(grep -c '^issue view' "$FX/calls")
    if [ -f "$FX/view-fails" ] || { [ -f "$FX/view-fails-after" ] && [ "$n" -gt 1 ]; }; then echo "HTTP 404: Not Found" >&2; exit 1; fi
    echo '{"labels":[{"name":"needs-decision"}],"comments":[]}' ;;
  "issue comment"*) [ ! -f "$FX/comment-fails" ] || { echo "HTTP 502" >&2; exit 1; } ;;
  "issue edit"*) ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

rec() { run "$SCRIPTS/decision.sh" record --repo o/r --issue 4 --text "ship it" "$@"; }
calls() { grep -c "^$1" "$FX/calls" 2>/dev/null || true; }

@test "an unknown subcommand is a usage error (exit 2) and reads nothing" {
  run "$SCRIPTS/decision.sh" decide --repo o/r
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: decision.sh record"* ]]
  [ ! -e "$FX/calls" ]
}

@test "record --dry-run prints the comment and the label, and calls nothing" {
  rec --dry-run --date 2026-11-08 --step "rotate the key"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'would record on 4 (and remove needs-decision):\nOwner decision (2026-11-08): ship it\n\nOwner steps:\n- [ ] rotate the key')" ]
  [ ! -e "$FX/calls" ]
  [ ! -e "$STATE/decisions.log" ]
}

@test "an unreadable issue is unverified (exit 9): nothing posted or logged" {
  touch "$FX/view-fails"
  rec
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: issue 4 could not be read" ]
  [ "$(calls 'issue comment')" -eq 0 ]
  [ ! -e "$STATE/decisions.log" ]
}

@test "a comment sent but not read back is unverified (exit 9): the label stays" {
  touch "$FX/view-fails-after"
  rec
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: decision comment on 4 sent (exit 0) but not read back; rerun to reconcile" ]
  [ "$(calls 'issue comment')" -eq 1 ]
  [ "$(calls 'issue edit')" -eq 0 ]
  [ ! -e "$STATE/decisions.log" ]
}

@test "a comment that is missing on readback failed (exit 5): the label stays" {
  touch "$FX/comment-fails"
  rec
  [ "$status" -eq 5 ]
  [ "$output" = "decision comment on 4 failed (exit 1)" ]
  [ "$(calls 'issue edit')" -eq 0 ]
  [ ! -e "$STATE/decisions.log" ]
}
