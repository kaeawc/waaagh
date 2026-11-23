# Helpers shared by the selftest-*.bats suites. Each suite loads this file from setup().
# It is the whole kit: the gh stubs (selftest_stubs.bash: stub_gh, stub_gh_router,
# stub_gh_merge_path; built on test_helper.bash's gh_stub_args like stub_gh_routes) and the data
# fixtures (selftest_fixtures.bash: pr_row, check, OKC, ...) plus the helpers below that need both.
# A suite that wants only the fixtures loads selftest_fixtures instead and defines no stub, so the
# stubs' names cannot collide with its own (#310).
# shellcheck source=selftest_stubs.bash
source "${BASH_SOURCE[0]%/*}/selftest_stubs.bash"
# shellcheck source=selftest_fixtures.bash
source "${BASH_SOURCE[0]%/*}/selftest_fixtures.bash"

fp() { "$SCRIPTS/fingerprint.sh" --dir "$REPO" "$@"; }

# --- PR takeover: claims and intake -------------------------------------------------------
claim() { ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" "$SCRIPTS/pr-claim.sh" "$@" --repo o/r --pr 7; }

intake() {
  cd "$REPO"
  ORCHESTRATE_AUTHOR=octocat ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 \
    "$SCRIPTS/pr-intake.sh" --repo o/r --owner ME "$@"
}

# --- campaign scripts: readiness, merge, main health, issues, lanes, device lock ---------------

verdict_of() { # checks... -> the verdict and detail of one PR built from them
  printf '%s\n' "$@" | jq -s . >"$FX/checks.json"
  pr_row 1 me false false MERGEABLE "$(<"$FX/checks.json")" | jq -s . >"$FX/prs.json"
  "$SCRIPTS/pr-ready.sh" --repo o/r --no-threads 2>/dev/null | cut -f2,6
}

merge_fixture() {
  stub_gh_router
  echo '{"state":"OPEN","isDraft":false,"isCrossRepository":false,"headRefOid":"abcdef0123456789abcdef0123456789abcdef01","author":{"login":"me"},"mergeable":"MERGEABLE"}' >"$FX/pr.json"
  echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}' >"$FX/pr-merged.json"
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
}

# --- validation receipts ---------------------------------------------------------------------
val() { ORCHESTRATE_VALIDATE_DIR="$BATS_TEST_TMPDIR/store" "$SCRIPTS/validate.sh" "$@" --dir "$REPO"; }
