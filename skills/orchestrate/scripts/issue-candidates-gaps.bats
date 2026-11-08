#!/usr/bin/env bats
# issue-candidates.sh paths the other suites do not reach: unreadable merged PRs (fixed, sweep) and
# an unreadable labelled-issue list (sweep) exit 4 with nothing printed, and an open-blockers.sh
# that fails outright (it crashes on a dependency list that is not an array) leaves every C row
# unverified, never clear. Stubbed gh. Run: bats scripts/issue-candidates-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/nogit"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 ORCHESTRATE_GH_API=graphql
  echo '[{"number":4,"title":"Crash on rotate","labels":[{"name":"needs-local:android-emulator"}],"comments":[]}]' >"$FX/issues.json"
  # Switches in $FX: label-fails (`issue list --label`), prs-fail (`pr list`).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"; all=${all% --include}
echo "$all" >>"$FX/calls"
case "$all" in
  "issue list"*"--label"*) [ ! -f "$FX/label-fails" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }; cat "$FX/issues.json" ;;
  "issue list"*) cat "$FX/issues.json" ;;
  "pr list"*) [ ! -f "$FX/prs-fail" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }; echo '[]' ;;
  "api repos/o/r/issues/4/dependencies/blocked_by"*) echo '{"message":"not a list"}' ;;
  "api repos/o/r/issues/4") echo '{"number":4,"state":"open","body":""}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

ic() { run "$SCRIPTS/issue-candidates.sh" "$@" --repo o/r; }

@test "fixed: merged PRs that cannot be read exit 4 and print no candidates" {
  touch "$FX/prs-fail"
  ic fixed
  [ "$status" -eq 4 ]
  [ "$(printf '%s\n' "$output" | grep -c "$(printf '\t')" || true)" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "issue-candidates.sh: merged PRs could not be read" ]
}

@test "sweep: an unreadable labelled-issue list exits 4 before merged PRs are read" {
  touch "$FX/label-fails"
  ic sweep --checkout "$BATS_TEST_TMPDIR/nogit"
  [ "$status" -eq 4 ]
  [ "$(printf '%s\n' "$output" | grep -c "$(printf '\t')" || true)" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "issue-candidates.sh: issues labelled needs-local:android-emulator could not be read" ]
  [ "$(grep -c '^pr list' "$FX/calls" || true)" -eq 0 ]
}

@test "sweep: merged PRs that cannot be read exit 4 and print no rows" {
  touch "$FX/prs-fail"
  ic sweep --checkout "$BATS_TEST_TMPDIR/nogit"
  [ "$status" -eq 4 ]
  [ "$(printf '%s\n' "$output" | grep -c "$(printf '\t')" || true)" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "issue-candidates.sh: merged PRs could not be read" ]
}

@test "sweep --drop-blocked: open-blockers.sh failing outright leaves C rows unverified, not clear" {
  ic sweep --checkout "$BATS_TEST_TMPDIR/nogit" --drop-blocked
  [ "$status" -eq 0 ]
  [[ "$output" == *"issue-candidates.sh: open-blockers.sh failed (exit 5); C rows unverified"* ]]
  row=$(printf '%s\n' "$output" | awk -F'\t' '$2 == 4')
  [ "$(cut -f1 <<<"$row")" = C ]
  [[ "$(cut -f6 <<<"$row")" == *"; blockers unverified (blocker check)"* ]]
}
