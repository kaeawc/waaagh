#!/usr/bin/env bats
# The shared gh route stub in test_helper.bash (stub_gh_routes, gh_route, gh_routes, #151): it
# drops the `--include` gh-read.sh appends to `gh api` calls, answers from the route table first and
# the case body second, and refuses anything unmatched. Also keeps the helpers' stub docs naming
# --include and the errexit gap under bats `run`.
# Run: bats stub-gh-routes.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  stub_gh_routes
}

@test "stub_gh_routes: --include and -i are dropped from gh api calls and the call is logged" {
  echo '{"n":5}' >"$FX/pull.json"
  gh_route "api repos/o/r/pulls/5" pull.json
  run gh api repos/o/r/pulls/5 --include
  [ "$status" -eq 0 ]
  [ "$output" = '{"n":5}' ]
  run gh api -i repos/o/r/pulls/5
  [ "$status" -eq 0 ]
  [ "$output" = '{"n":5}' ]
  [ "$(cat "$FX/calls")" = $'api repos/o/r/pulls/5\napi repos/o/r/pulls/5' ]
}

@test "stub_gh_routes: a read through gh-read.sh reaches an exact route on the first try" {
  echo '{"login":"me"}' >"$FX/user.json"
  gh_route "api user" user.json
  run --separate-stderr "$SCRIPTS/gh-read.sh" --json -- api user
  [ "$status" -eq 0 ] || { echo "status=$status: $output $stderr"; false; }
  [ "$output" = '{"login":"me"}' ]
  [ "$(wc -l <"$FX/calls")" -eq 1 ]
}

@test "stub_gh_routes: the first matching glob wins, and an absolute FILE is read as given" {
  echo two >"$FX/page2"; echo one >"$FX/page1"; echo abs >"$BATS_TEST_TMPDIR/abs"
  gh_route "api graphql*after=c1*" page2
  gh_route "api graphql*" page1
  gh_route "pr list*" "$BATS_TEST_TMPDIR/abs"
  [ "$(gh api graphql -f query=q -f after=c1)" = two ]
  [ "$(gh api graphql -f query=q)" = one ]
  [ "$(gh pr list --json number)" = abs ]
}

@test "stub_gh_routes: -i stays on calls other than gh api" {
  gh_route "pr list -i*" page
  echo listed >"$FX/page"
  [ "$(gh pr list -i x)" = listed ]
}

@test "stub_gh_routes: the case body answers what the table does not, and a miss exits 9" {
  echo t >"$FX/t"
  gh_route "api repos/o/r" t
  gh_routes <<'R'
case "$a" in
  "api user") echo '{"login":"me"}'; exit 0 ;;
  "api repos/o/r/pulls/9") echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
R
  [ "$(gh api repos/o/r)" = t ]
  [ "$(gh api user --include)" = '{"login":"me"}' ]
  run --separate-stderr gh api repos/o/r/pulls/9
  [ "$status" -eq 1 ]
  [ "$stderr" = "gh: Not Found (HTTP 404)" ]
  run --separate-stderr gh issue view 3
  [ "$status" -eq 9 ]
  [ "$stderr" = "unexpected gh call: issue view 3" ]
}

@test "stub_gh_routes: with no routes every call is unexpected" {
  run --separate-stderr gh api user
  [ "$status" -eq 9 ]
  [ "$stderr" = "unexpected gh call: api user" ]
}

@test "docs: the stub section names --include, and the bashcov note names the errexit gap" {
  local h="$SCRIPTS/test_helper.bash"
  [ "$(grep -c -- '--include' "$h")" -ge 2 ]
  [ "$(grep -c 'stub_gh_routes' "$SCRIPTS/selftest_helper.bash")" -ge 1 ]
  [[ "$(cat "$h")" == *"bats' \`run\` and command substitution"*"drop errexit"* ]]
}
