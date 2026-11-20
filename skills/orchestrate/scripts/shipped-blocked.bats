#!/usr/bin/env bats
# Approved PRs the merge loop passes over (#269): shipped-blocked.sh names every PR whose latest
# internal review verdict is ship but whose pr-ready.sh row is not READY, with pr-ready's reasons,
# and triage-tick.sh snapshot lists them as shipped-blocked lines with a shipped-blocked=<n> reason.
# Stubbed gh. Run: bats shipped-blocked.bats

setup() {
  load test_helper
  load selftest_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_SCRIPTS_DIR ORCHESTRATE_PR_READY_ARGS ORCHESTRATE_GH_API PR_READY_EXTRA
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  # An empty checkout: a ship verdict pinned to another head cannot be shown to cover the PR's head.
  export ORCHESTRATE_GIT_DIR="$BATS_TEST_TMPDIR/git"
  git init -q "$ORCHESTRATE_GIT_DIR"
}

rl() { "$SCRIPTS/review-ledger.sh" record --repo o/r --pr "$1" --verdict "$2" ${3:+--head "$3"} >/dev/null; }
sb() { "$SCRIPTS/shipped-blocked.sh" --repo o/r "$@"; }
head_of() { local b=abcdef0123456789abcdef0123456789abcdef01; echo "${b:0:$((40 - ${#1}))}$1"; }   # the head pr_row gives PR N
stub_pr_ready() { # a pr-ready.sh that prints $FX/rows.tsv, or exits with $FX/ready-rc
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  printf '#!/usr/bin/env bash\necho "pr-ready $*" >>"%s/ready-calls"\n[ ! -f "%s/ready-rc" ] || exit "$(cat "%s/ready-rc")"\ncat "%s/rows.tsv" 2>/dev/null || true\n' \
    "$FX" "$FX" "$FX" "$FX" >"$BATS_TEST_TMPDIR/stubs/pr-ready.sh"
  chmod +x "$BATS_TEST_TMPDIR/stubs/pr-ready.sh"
  export ORCHESTRATE_SCRIPTS_DIR="$BATS_TEST_TMPDIR/stubs"
}

@test "real pr-ready: a ship-at-head PR blocked by an unresolved thread is named with threads=1" {
  stub_gh_router
  {
    pr_row 1 me false false MERGEABLE "$OKC"     # ship at head, one unresolved thread
    pr_row 2 me false false MERGEABLE "$OKC"     # ship at head, READY
    pr_row 3 me false false MERGEABLE "$OKC"     # unresolved thread, no verdict
    pr_row 4 me false false MERGEABLE "$OKC"     # ship pinned to an older head: review:stale
    pr_row 5 me false false MERGEABLE "$OKC"     # ship, then fix-first
    pr_row 6 me false false CONFLICTING "$OKC"   # ship at head, conflict and a thread
    pr_row 7 me true false MERGEABLE "$OKC"      # ship at head, a draft
  } | jq -s . >"$FX/prs.json"
  echo '{"1":[{"isResolved":false,"isOutdated":false}],"3":[{"isResolved":false,"isOutdated":false}],"6":[{"isResolved":false,"isOutdated":false}]}' >"$FX/threads.json"
  for n in 1 2 6 7; do rl "$n" ship "$(head_of "$n")"; done
  rl 4 ship 0123456789abcdef
  rl 5 ship "$(head_of 5)"; rl 5 fix-first
  run sb
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "shipped-blocked #1 verdict=BLOCK reason=threads=1" ]
  [ "${lines[1]}" = "shipped-blocked #6 verdict=BLOCK reason=conflict,threads=1" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "real pr-ready: every ship-at-head PR READY prints nothing" {
  stub_gh_router
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  rl 1 ship "$(head_of 1)"
  run sb
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no ship verdict with a head: pr-ready.sh is not run and nothing is printed" {
  stub_gh_routes
  stub_pr_ready
  rl 8 ship
  rl 9 fix-first
  run sb
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$FX/ready-calls" ]
}

@test "--rows: WAIT, BEHIND and held rows are named; drafts, stale and READY rows are not" {
  stub_gh_routes
  for n in 10 11 12 13 14 15; do rl "$n" ship "$(head_of "$n")"; done
  printf '%s\n' \
    $'10\tWAIT\tabcdef012\tMERGEABLE\t1\tpending:build' \
    $'11\tSKIP\tabcdef012\tMERGEABLE\t1\thold ready-but-skipped' \
    $'12\tSKIP\tabcdef012\tMERGEABLE\t0\tdraft' \
    $'13\tSKIP\tabcdef012\tMERGEABLE\t1\treview:stale' \
    $'14\tREADY\tabcdef012\tMERGEABLE\t1\t-' \
    $'15\tBEHIND\tabcdef012\tMERGEABLE\t1\tbehind' \
    $'16\tBLOCK\tabcdef012\tMERGEABLE\t1\tthreads=2' >"$BATS_TEST_TMPDIR/rows.tsv"
  run sb --rows "$BATS_TEST_TMPDIR/rows.tsv"
  [ "$status" -eq 0 ]
  [ "$output" = $'shipped-blocked #10 verdict=WAIT reason=pending:build\nshipped-blocked #11 verdict=SKIP reason=hold,ready-but-skipped\nshipped-blocked #15 verdict=BEHIND reason=behind' ]
  run sb --rows - <"$BATS_TEST_TMPDIR/rows.tsv"
  [ "${#lines[@]}" -eq 3 ]
  [ "$(calls_of)" -eq 0 ]
}

calls_of() { if [ -f "$FX/calls" ]; then awk 'END { print NR }' "$FX/calls"; else echo 0; fi; }

@test "--pr: only the named PRs; one pr-ready does not list is unlisted, not silent" {
  stub_gh_routes
  stub_pr_ready
  rl 20 ship "$(head_of 20)"; rl 21 ship "$(head_of 21)"; rl 22 ship "$(head_of 22)"
  printf '%s\n' $'20\tBLOCK\tabcdef012\tMERGEABLE\t1\tthreads=1' $'21\tBLOCK\tabcdef012\tMERGEABLE\t1\tfail:build' >"$FX/rows.tsv"
  run sb --pr 20 --pr '#22' -- --author bot
  [ "$status" -eq 0 ]
  [ "$output" = $'shipped-blocked #20 verdict=BLOCK reason=threads=1\nshipped-blocked #22 verdict=unlisted reason=not-selected' ]
  [ "$(cat "$FX/ready-calls")" = "pr-ready --repo o/r --author bot" ]
}

@test "unreadable readiness is exit 3 with nothing printed; an unreadable ledger is exit 4" {
  stub_gh_routes
  stub_pr_ready
  rl 30 ship "$(head_of 30)"
  echo 3 >"$FX/ready-rc"
  run sb
  [ "$status" -eq 3 ]
  [[ "$output" == *"pr-ready.sh exit 3; readiness unknown"* ]]
  [[ "$output" != *"shipped-blocked #"* ]]
  run sb --rows "$BATS_TEST_TMPDIR/missing.tsv"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not readable"* ]]
  mv "$ST/reviews.tsv" "$ST/reviews.bak"; mkdir "$ST/reviews.tsv"
  run sb
  [ "$status" -eq 4 ]
  [[ "$output" == *"review ledger could not be read"* ]]
}

@test "usage: a bad --pr or an unknown flag is exit 2 before any read" {
  stub_gh_routes
  run sb --pr abc
  [ "$status" -eq 2 ]
  run sb --frobnicate
  [ "$status" -eq 2 ]
  [ "$(calls_of)" -eq 0 ]
}

# --- triage-tick.sh snapshot ---------------------------------------------------------------------
tick_fixture() {
  stub_gh_routes
  stub_pr_ready
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
  echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-09-27T01:00:00Z"}]}' >"$FX/runs.json"
  echo '[]' >"$FX/issues.json"
  echo '[{"number":40,"closingIssuesReferences":[]},{"number":41,"closingIssuesReferences":[]},{"number":42,"closingIssuesReferences":[]}]' >"$FX/prs.json"
  # 40 ready for review, 41 ready for review, 42 a draft: all three have a ship verdict at head.
  jq -n 'def node($n; $d): {number: $n, headRefOid: ("abcdef0123456789" + ($n | tostring)), isDraft: $d,
        commits: {nodes: [{commit: {statusCheckRollup: {state: "SUCCESS"}}}]}, reviews: {nodes: []}};
    {data: {repository: {pullRequests: {pageInfo: {hasNextPage: false}, nodes: [node(40; false), node(41; false), node(42; true)]}}}}' >"$FX/snapshot.json"
  for n in 40 41 42; do rl "$n" ship "$(head_of "$n")"; done
  printf '%s\n' $'40\tBLOCK\tabcdef012\tMERGEABLE\t1\tthreads=1' $'41\tREADY\tabcdef012\tMERGEABLE\t1\t-' >"$FX/rows.tsv"
}
snap() { "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main "$@"; }

@test "tick: a ship-at-head PR that is not READY gets a shipped-blocked line and reason" {
  tick_fixture
  run snap
  [ "$status" -eq 0 ]
  [ "$(snap_line shipped-blocked)" = "shipped-blocked #40 verdict=BLOCK reason=threads=1" ]
  [[ "$(snap_line verdict)" == *"shipped-blocked=1"* ]]
  required_snapshot_lines
  [ "$(awk '$1 == "merge_loop" { m = NR } $1 == "shipped-blocked" { s = NR } END { print s - m }' <<<"$output")" = 1 ]
  # Only the open, non-draft ship PRs are judged; the draft is the reviewed-draft line's.
  [ "$(cat "$FX/ready-calls")" = "pr-ready --repo o/r --base main" ]
}

@test "tick: ORCHESTRATE_PR_READY_ARGS reach pr-ready.sh; a PR it does not select is unlisted" {
  tick_fixture
  export ORCHESTRATE_PR_READY_ARGS="--author bot --ignore-check lint"
  printf '%s\n' $'41\tREADY\tabcdef012\tMERGEABLE\t1\t-' >"$FX/rows.tsv"
  run snap
  [ "$(snap_line shipped-blocked)" = "shipped-blocked #40 verdict=unlisted reason=not-selected" ]
  [ "$(cat "$FX/ready-calls")" = "pr-ready --repo o/r --author bot --ignore-check lint --base main" ]
}

@test "tick: all READY prints no line and no reason; unreadable readiness says unknown" {
  tick_fixture
  printf '%s\n' $'40\tREADY\tabcdef012\tMERGEABLE\t1\t-' $'41\tREADY\tabcdef012\tMERGEABLE\t1\t-' >"$FX/rows.tsv"
  run snap
  [ "$status" -eq 0 ]
  [ "$(grep -c '^shipped-blocked' <<<"$output" || true)" -eq 0 ]
  [[ "$(snap_line verdict)" != *"shipped-blocked"* ]]
  echo 3 >"$FX/ready-rc"
  run snap
  [ "$status" -eq 0 ]
  [ "$(snap_line shipped-blocked)" = "shipped-blocked unknown" ]
  [[ "$(snap_line verdict)" != *"shipped-blocked"* ]]
}

@test "tick: no open ship PR means no pr-ready.sh run" {
  tick_fixture
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 40 --verdict fix-first >/dev/null
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 41 --verdict rethink >/dev/null
  run snap
  [ "$status" -eq 0 ]
  [ ! -f "$FX/ready-calls" ]
  [ "$(grep -c '^shipped-blocked' <<<"$output" || true)" -eq 0 ]
}

@test "the shipped-blocked line and reason are documented in triage-tick.sh's usage header" {
  run snapshot_line_names "$SCRIPTS/triage-tick.sh"
  [ "$(awk '$1 == "merge_loop" { m = NR } $1 == "shipped-blocked" { s = NR } END { print s - m }' <<<"$output")" = 1 ]
  run "$SCRIPTS/triage-tick.sh" -h
  [[ "$output" == *"shipped-blocked=<n>"* ]]
}
