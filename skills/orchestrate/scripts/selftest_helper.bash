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

# Many verdict_of cases in one pr-ready.sh run (#112): `expect VERDICT<TAB>DETAIL CHECK...` adds a
# case (its own PR, numbered in order), and verdicts_match runs pr-ready once over every case and
# fails naming each case whose PR's verdict and detail differ. Each PR is classified on its own
# checks alone, so this asserts what one verdict_of call per case would.
expect() { want+=("$1"); shift; cases+=("$(printf '%s\n' "$@" | jq -cs .)"); }
verdicts_match() {
  local i got bad=""
  for i in "${!cases[@]}"; do pr_row "$((i + 1))" me false false MERGEABLE "${cases[i]}"; done | jq -s . >"$FX/prs.json"
  got=$("$SCRIPTS/pr-ready.sh" --repo o/r --no-threads 2>/dev/null | awk -F'\t' '$1 ~ /^[0-9]+$/ { print $1 "\t" $2 "\t" $6 }' | sort -n)
  [ "$(grep -c . <<<"$got")" -eq "${#cases[@]}" ] || { echo "want ${#cases[@]} rows, got: $got"; return 1; }
  for i in "${!cases[@]}"; do
    [ "$(sed -n "$((i + 1))p" <<<"$got")" = "$((i + 1))"$'\t'"${want[i]}" ] ||
      bad+=$'\n'"case $((i + 1)): want ${want[i]}, got $(sed -n "$((i + 1))p" <<<"$got" | cut -f2-) for ${cases[i]}"
  done
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}

merge_fixture() {
  stub_gh_router
  echo '{"state":"OPEN","isDraft":false,"isCrossRepository":false,"headRefOid":"abcdef0123456789abcdef0123456789abcdef01","author":{"login":"me"},"mergeable":"MERGEABLE"}' >"$FX/pr.json"
  echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}' >"$FX/pr-merged.json"
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
}

# --- validation receipts ---------------------------------------------------------------------
val() { ORCHESTRATE_VALIDATE_DIR="$BATS_TEST_TMPDIR/store" "$SCRIPTS/validate.sh" "$@" --dir "$REPO"; }
