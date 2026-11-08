#!/usr/bin/env bats
# issue-route.sh paths the other suites do not reach: unreadable labels (exit 4), a label create
# that fails (exit 5, the others still created), and a route that is still wrong on readback
# (exit 5, nothing logged). Stubbed gh. Run: bats scripts/issue-route-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Switches in $FX: labels-fail, create-fails (a label name whose create fails). The issue keeps
  # its needs-local:research label whatever is sent (edits are accepted and ignored).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "label list"*) [ ! -f "$FX/labels-fail" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }; echo '[{"name":"cloud-ready"}]' ;;
  "label create"*) [[ "$*" != "label create $(cat "$FX/create-fails" 2>/dev/null) "* ]] || exit 1 ;;
  "issue view 8 "*) echo '{"state":"OPEN","labels":[{"name":"needs-local:research"}],"comments":[]}' ;;
  "issue edit"*) ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

@test "labels that cannot be read: exit 4 and nothing created" {
  touch "$FX/labels-fail"
  run "$SCRIPTS/issue-route.sh" labels --repo o/r
  [ "$status" -eq 4 ]
  [ "$output" = "issue-route.sh: labels could not be read" ]
  [ "$(grep -c '^label create' "$FX/calls" || true)" -eq 0 ]
}

@test "a label create that fails is reported and exits 5; the other labels are still created" {
  echo needs-local:ios-simulator >"$FX/create-fails"
  run "$SCRIPTS/issue-route.sh" labels --repo o/r
  [ "$status" -eq 5 ]
  [ "${lines[0]}" = "exists cloud-ready" ]
  [[ "$output" == *"failed needs-local:ios-simulator"* ]]
  [[ "$output" == *"created needs-local:macos-xcode"* ]]
  [ "$(grep -c 'label-create	needs-local:ios-simulator' "$STATE/route-actions.log" || true)" -eq 0 ]
  grep -q 'label-create	needs-local:macos-xcode' "$STATE/route-actions.log"
}

@test "a route still wrong on readback is incomplete (exit 5) and not logged" {
  run "$SCRIPTS/issue-route.sh" set --repo o/r --issue 8 --route cloud-ready
  [ "$status" -eq 5 ]
  [ "$output" = "route of issue 8 incomplete (routes now: needs-local:research; exit 0); rerun to finish" ]
  grep -q '^issue edit 8 --repo o/r --add-label cloud-ready --remove-label needs-local:research$' "$FX/calls"
  [ ! -e "$STATE/route-actions.log" ]
}
