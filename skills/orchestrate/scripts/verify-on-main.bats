#!/usr/bin/env bats
# verify-on-main.sh (#258): open issues whose fix merged in a "Part of #N" PR are routed to a
# verify-on-main batch, not to implementation; a PASS on a default-branch SHA after the fix makes
# them closable (reported, never closed); a FAIL sends them back. Plus the dispatch and routing
# hooks (triage-tick.sh, issue-route.sh) and the doctrine. Stubbed gh, a real git checkout.
# Run: bats scripts/verify-on-main.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_GH_API=graphql
  stub_gh_routes
  # A checkout whose main holds MAIN; SIDE is a commit that never reached main.
  CO="$BATS_TEST_TMPDIR/co"
  git init -q -b main "$CO"
  git -C "$CO" commit -q --allow-empty -m base
  MAIN=$(git -C "$CO" rev-parse HEAD)
  git -C "$CO" checkout -q -b side
  git -C "$CO" commit -q --allow-empty -m side
  SIDE=$(git -C "$CO" rev-parse HEAD)
  git -C "$CO" checkout -q main
  export MAIN SIDE CO
  cat >"$FX/issues.json" <<'J'
[{"number":10,"title":"Crash on rotate","labels":[{"name":"needs-local:android-emulator"}]},
 {"number":11,"title":"Both platforms","labels":[{"name":"needs-local:android-emulator"},{"name":"needs-local:ios-simulator"}]},
 {"number":12,"title":"Fixed and checked","labels":[{"name":"needs-local:android-emulator"},{"name":"bug"}]},
 {"number":13,"title":"Still broken","labels":[{"name":"needs-local:ios-simulator"},{"name":"verify-on-main"}]},
 {"number":14,"title":"Branch-only recheck","labels":[]},
 {"number":15,"title":"Only mentioned","labels":[{"name":"cloud-ready"}]},
 {"number":17,"title":"Comments fail","labels":[]}]
J
  cat >"$FX/merged.json" <<'J'
[{"number":100,"title":"Rotate fix","body":"Part of #10","mergedAt":"2026-09-20T00:00:00Z","closingIssuesReferences":[]},
 {"number":101,"title":"Shared fix","body":"Part of #11.","mergedAt":"2026-09-20T00:00:00Z","closingIssuesReferences":[]},
 {"number":102,"title":"x","body":"Refs #12","mergedAt":"2026-09-20T00:00:00Z","closingIssuesReferences":[]},
 {"number":103,"title":"Part of #13: ios","body":"","mergedAt":"2026-09-20T00:00:00Z","closingIssuesReferences":[]},
 {"number":104,"title":"y","body":"Part of #14; see #15","mergedAt":"2026-09-20T00:00:00Z","closingIssuesReferences":[{"number":17}]}]
J
  before="2026-09-19T00:00:00Z" after="2026-09-21T00:00:00Z"
  printf '[{"body":"Device verification: PASS on android (Pixel 8, API 35) at %s","created_at":"%s","html_url":"u10"}]' "$MAIN" "$before" >"$FX/comments-10.json"
  printf '[{"body":"Device verification: PASS on android (Pixel 8) at %s","created_at":"%s","html_url":"u11"}]' "$MAIN" "$after" >"$FX/comments-11.json"
  printf '[{"body":"notes\\n**Device verification:** PASS on android (Pixel 8) at `%s`","created_at":"%s","html_url":"u12"}]' "${MAIN:0:12}" "$after" >"$FX/comments-12.json"
  printf '[{"body":"Device verification: PASS on ios at %s","created_at":"%s","html_url":"u13a"},{"body":"Device verification: FAIL on ios (iPhone 15) at %s","created_at":"%s","html_url":"u13b"}]' "$MAIN" "$after" "$MAIN" "2026-09-22T00:00:00Z" >"$FX/comments-13.json"
  printf '[{"body":"**Device recheck passed**\\n\\n<!-- waaagh:device-recheck verdict=pass head=%s -->","created_at":"%s","html_url":"u14"}]' "$SIDE" "$after" >"$FX/comments-14.json"
  gh_routes <<'R'
case "$a" in
  "issue list"*) cat "$FX/issues.json"; exit 0 ;;
  "pr list"*) [ ! -f "$FX/prs-fail" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }; cat "$FX/merged.json"; exit 0 ;;
  "api repos/o/r/issues/17/comments"*) echo "HTTP 404: Not Found" >&2; exit 1 ;;
  "api repos/o/r/issues/"*"/comments"*) n=${a#api repos/o/r/issues/}; n=${n%%/*}
    if [ -f "$FX/comments-$n.json" ]; then cat "$FX/comments-$n.json"; else echo '[]'; fi; exit 0 ;;
  "api repos/o/r") echo '{"default_branch":"main"}'; exit 0 ;;
  "api repos/o/r/compare/"*) cat "$FX/compare.json" 2>/dev/null || { echo "HTTP 404: Not Found" >&2; exit 1; }; exit 0 ;;
  "label create"*) exit 0 ;;
  "api -X POST repos/o/r/issues/"*) [ ! -f "$FX/write-fails" ] || exit 1; exit 0 ;;
  "api -X DELETE repos/o/r/issues/"*) exit 0 ;;
esac
R
}

vom() { run --separate-stderr "$SCRIPTS/verify-on-main.sh" "$@" --repo o/r --checkout "$CO" --ref main; }
row() { printf '%s\n' "$output" | awk -F'\t' -v n="$1" '$2 == n'; }

@test "scan: a merged Part-of fix with no main-SHA result is verify, not implementation" {
  vom scan
  [ "$status" -eq 0 ]
  [ "$(row 10 | cut -f1)" = verify ]
  [ "$(row 10 | cut -f3)" = android-emulator ]
  [ "$(row 10 | cut -f4)" = "#100" ]
  # The PASS before the merge does not count.
  [ "$(row 10 | cut -f6)" = "fix merged; verify on android-emulator" ]
  [ "$(row 11 | cut -f6)" = "fix merged; verify on ios-simulator" ]
  # A device-recheck PASS on a branch head that never reached main does not count either.
  [ "$(row 14 | cut -f1)" = verify ]
  [ "$(row 14 | cut -f6)" = "fix merged; verify on any" ]
  # A bare mention is no reference; a closing reference that did not close the issue is.
  [ -z "$(row 15)" ]
  [ "$(row 17 | cut -f4)" = "#104" ]
}

@test "scan: a PASS on a default-branch SHA after the fix is closable, with its link; nothing is closed" {
  vom scan
  [ "$(row 12 | cut -f1)" = closable ]
  [ "$(row 12 | cut -f5)" = u12 ]
  [ "$(grep -c 'close\|PATCH\|-X' "$FX/calls" || true)" -eq 0 ]
  [[ "${lines[${#lines[@]}-1]}" == "# verify=3 closable=1 failed=1 unknown=1; label: verify-on-main; checked: git main" ]]
}

@test "scan: the latest main result FAIL is failed; unreadable comments are unknown" {
  vom scan
  [ "$(row 13 | cut -f1)" = failed ]
  [ "$(row 13 | cut -f5)" = u13b ]
  [ "$(row 17 | cut -f1)" = unknown ]
}

@test "scan --apply labels verify and closable rows, unlabels failed ones, and logs it" {
  vom scan --apply
  [ "$status" -eq 0 ]
  for n in 10 11 12 14; do
    [ "$(grep -c "^api -X POST repos/o/r/issues/$n/labels -f labels\[\]=verify-on-main" "$FX/calls" || true)" -eq 1 ]
  done
  [ "$(grep -c '^api -X POST repos/o/r/issues/17' "$FX/calls" || true)" -eq 0 ]
  [ "$(grep -c '^api -X DELETE repos/o/r/issues/13/labels/verify-on-main' "$FX/calls" || true)" -eq 1 ]
  [ "$(grep -c '^label create verify-on-main' "$FX/calls" || true)" -eq 1 ]
  [[ "${lines[${#lines[@]}-1]}" == *"labelled=4 unlabelled=1;"* ]]
  run grep -c "add #12 verify-on-main (closable)" "$ORCHESTRATE_STATE_DIR/o__r/verify-on-main.log"
  [ "$output" -eq 1 ]
}

@test "scan --apply: a failed label write exits 5" {
  touch "$FX/write-fails"
  vom scan --apply
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"could not label #10 verify-on-main; rerun"* ]]
}

@test "batch: one row per platform for verify issues, then the closable ones" {
  vom batch
  [ "$status" -eq 0 ]
  [[ "$output" == *$'batch\tandroid-emulator\t#10\t#100'* ]]
  [[ "$output" == *$'batch\tios-simulator\t#11\t#101'* ]]
  [[ "$output" == *$'batch\tany\t#14\t#104'* ]]
  [[ "$output" == *$'closable\t#12\t-\tu12'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '#13' || true)" -eq 0 ]
  [[ "${lines[${#lines[@]}-1]}" == "# batches for 3 issues; closable=1 failed=1 unknown=1; label: verify-on-main; checked: git main" ]]
}

@test "batch: a configurable label and platform prefix" {
  printf '[{"number":20,"title":"t","labels":[{"name":"platform:web"},{"name":"check-main"}]}]' >"$FX/issues.json"
  echo '[]' >"$FX/merged.json"
  vom batch --label check-main --platform-prefix platform:
  [[ "$output" == *$'batch\tweb\t#20\t-'* ]]
  [[ "$output" == *"label: check-main"* ]]
}

@test "scan: a SHA the checkout lacks is checked with the REST compare" {
  printf '[{"number":12,"title":"t","labels":[]}]' >"$FX/issues.json"
  printf '[{"body":"Device verification: PASS on web at abcdef1234567","created_at":"2026-09-21T00:00:00Z","html_url":"u12"}]' >"$FX/comments-12.json"
  echo '{"status":"ahead"}' >"$FX/compare.json"
  vom scan
  [ "$(row 12 | cut -f1)" = closable ]
  [ "$(grep -c '^api repos/o/r/compare/abcdef1234567...main' "$FX/calls" || true)" -eq 1 ]
  [[ "${lines[${#lines[@]}-1]}" == *"checked: rest" ]]
  echo '{"status":"diverged"}' >"$FX/compare.json"
  vom scan
  [ "$(row 12 | cut -f1)" = verify ]
}

@test "scan: unreadable merged PRs exit 4 with no rows" {
  touch "$FX/prs-fail"
  vom scan
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *"merged PRs could not be read"* ]]
}

@test "usage: --apply is for scan only; a bad --since-days is refused" {
  run "$SCRIPTS/verify-on-main.sh" batch --apply
  [ "$status" -eq 2 ]
  run "$SCRIPTS/verify-on-main.sh" scan --since-days x
  [ "$status" -eq 2 ]
  run "$SCRIPTS/verify-on-main.sh"
  [ "$status" -eq 2 ]
  [ ! -s "$FX/calls" ]
}

@test "triage-tick.sh snapshot leaves verify-on-main issues out of the dispatch count, with or without --exclude-label" {
  export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD
  echo '[{"workflowName":"Test","status":"completed","conclusion":"success","headSha":"aaaaaaaaaaaa","databaseId":10,"createdAt":"2026-09-27T01:00:00Z"}]' >"$FX/runs.json"
  echo '[{"number":3,"labels":[]},{"number":4,"labels":[{"name":"verify-on-main"}]},{"number":5,"labels":[{"name":"blocked"}]},{"number":6,"labels":[{"name":"check-main"}]}]' >"$FX/issues.json"
  gh_routes <<'R'
case "$a" in
  "api repos/o/r/actions/runs?"*) jq '{workflow_runs: map({name: .workflowName, status, conclusion, head_sha: .headSha, id: .databaseId, created_at: .createdAt})}' "$FX/runs.json"; exit 0 ;;
  "pr list"*) echo '[]'; exit 0 ;;
  "issue list"*) cat "$FX/issues.json"; exit 0 ;;
  "api graphql"*) echo '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}'; exit 0 ;;
esac
R
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$(snap_line dispatch)" = "dispatch 2 next=#3,#6" ]
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main --exclude-label wontfix
  [ "$(snap_line dispatch)" = "dispatch 3 next=#3,#5,#6" ]
  ORCHESTRATE_VERIFY_ON_MAIN_LABEL=check-main run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$(snap_line dispatch)" = "dispatch 2 next=#3,#4" ]
}

@test "issue-route.sh status skips verify-on-main issues: not unrouted, not routable" {
  echo '[{"number":4,"title":"t","labels":[{"name":"verify-on-main"}]},{"number":3,"title":"u","labels":[]}]' >"$FX/issues.json"
  run "$SCRIPTS/issue-route.sh" status --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'count\tskipped\t1'* ]]
  [[ "$output" == *$'count\tunrouted\t1'* ]]
  [ -z "$(printf '%s\n' "$output" | awk -F'\t' '$1 == "unrouted" && $2 == 4')" ]
}

@test "doctrine: the tick, verification and routing name verify-on-main.sh and never close" {
  for f in roles/triage-tick.md roles/verification.md routing.md; do
    run grep -c 'verify-on-main.sh' "$SCRIPTS/../$f"
    [ "$output" -ge 1 ]
  done
  run grep -c 'verify-on-main.sh' "$ROOT/README.md"
  [ "$output" -ge 1 ]
}
