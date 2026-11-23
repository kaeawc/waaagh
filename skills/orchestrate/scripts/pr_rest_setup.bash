# Setup and helpers shared by pr-rest.bats and pr-rest-parity.bats
# (split for a shorter parallel run, #112). Loaded at file level by both; not a suite itself.

setup() {
  load test_helper
  load selftest_helper
  load rest_stub
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  stub_gh_router
  rest_wrap
}

# both ARGS...: pr-ready.sh over GraphQL, then over REST (refused GraphQL, own state dir). The exit
# code, every row and the summary must match; only draft and fork rows may differ in their
# mergeable and passed columns (REST does not read them), and REST adds " api=rest". Leaves the
# REST run in $output and $status.
both() {
  local gq rs gs rss
  rm -f "$FX/rest-mode"
  gq=$(ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state-gq" "$SCRIPTS/pr-ready.sh" "$@" 2>"$FX/gq.err") && gs=0 || gs=$?
  touch "$FX/rest-mode"
  rs=$(ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state-rest" "$SCRIPTS/pr-ready.sh" "$@" 2>"$FX/rs.err") && rss=0 || rss=$?
  norm() { awk -F'\t' -v OFS='\t' '$2 == "SKIP" && ($6 == "draft" || $6 == "fork") { $4 = "-"; $5 = "-" } { print }'; }
  sum() { tail -1 "$1" | sed -E 's/ diagnostics=[^ ]*//; s/ api=rest//'; }
  [ "$gs" = "$rss" ] || { echo "exit: graphql=$gs rest=$rss"; cat "$FX/rs.err"; return 1; }
  [ "$(norm <<<"$gq")" = "$(norm <<<"$rs")" ] || { echo "rows differ:"; diff <(norm <<<"$gq") <(norm <<<"$rs") || true; cat "$FX/rs.err"; return 1; }
  [ "$(sum "$FX/gq.err")" = "$(sum "$FX/rs.err")" ] || { echo "summary: $(tail -1 "$FX/gq.err") | $(tail -1 "$FX/rs.err")"; return 1; }
  if [ "$gs" = 0 ]; then grep -q 'api=rest' "$FX/rs.err" || { echo "no api=rest"; return 1; }; fi
  output="$rs"$'\n'"$(<"$FX/rs.err")"
  status=$rss
}

verdict_both() { # checks... -> both paths agree; prints the REST verdict and detail
  printf '%s\n' "$@" | jq -s . >"$FX/checks.json"
  pr_row 1 me false false MERGEABLE "$(<"$FX/checks.json")" | jq -s . >"$FX/prs.json"
  both --repo o/r --no-threads >/dev/null || return 1
  printf '%s\n' "$output" | awk -F'\t' '$1 == 1 { print $2 "\t" $6 }'
}

# --- the selftest-pr fixtures, through both paths -------------------------------------------
