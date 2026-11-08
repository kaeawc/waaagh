#!/usr/bin/env bats
# One argument handling for every gh stub (#166): test_helper.bash's stub_gh_routes,
# selftest_helper.bash's stub_gh_router and rest_stub.bash's rest_wrap all read their arguments with
# gh_stub_args, so the `--include` gh-read.sh appends to a `gh api` call (or a `-i`) never changes
# which route a call reaches. Run: bats stub-gh-args.bats

setup() {
  load test_helper
  load selftest_helper
  load rest_stub
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

# read_once ROUTE BODY: one gh-read.sh read of ROUTE through the gh on PATH answers BODY on the first
# try, and the stub logged it as ROUTE (no --include).
read_once() {
  : >"$FX/calls"
  run --separate-stderr "$SCRIPTS/gh-read.sh" --json -- api "$1"
  [ "$status" -eq 0 ] || { echo "status=$status: $output $stderr"; return 1; }
  [ "$output" = "$2" ] || { echo "body: $output"; return 1; }
  [ "$(cat "$FX/calls")" = "api $1" ] || { echo "calls:"; cat "$FX/calls"; return 1; }
}

@test "gh_stub_args: drops --include and -i anywhere in a gh api call, and only there" {
  gh_stub_args api repos/o/r --include
  [ "$a" = "api repos/o/r" ]
  gh_stub_args api -i --include repos/o/r -f x=1
  [ "$a" = "api repos/o/r -f x=1" ]
  gh_stub_args pr list -i --include
  [ "$a" = "pr list -i --include" ]
  gh_stub_args
  [ "$a" = "" ]
}

@test "one gh-read.sh call matches the same route through all three stubs" {
  local body='{"default_branch":"main"}'
  stub_gh_routes
  printf '%s\n' "$body" >"$FX/repo.json"
  gh_route "api repos/o/r" repo.json
  read_once repos/o/r "$body"

  stub_gh_router
  read_once repos/o/r "$body"

  rest_wrap
  touch "$FX/rest-mode"
  read_once repos/o/r "$body"
  # rest_wrap logs the call as gh got it, and passed it on to the router underneath
  [ "$(cat "$FX/rest-calls")" = "api repos/o/r --include" ]
}

@test "a REST route rest_wrap serves itself matches with --include or -i, like stub_gh_routes" {
  stub_gh_router
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  rest_wrap
  touch "$FX/rest-mode"
  run --separate-stderr "$SCRIPTS/gh-read.sh" --json -- api repos/o/r/pulls/1
  [ "$status" -eq 0 ] || { echo "status=$status: $output $stderr"; false; }
  [ "$(jq -r .number <<<"$output")" = 1 ]
  [ "$(wc -l <"$FX/rest-calls")" -eq 1 ]
  [ "$(gh api -i repos/o/r/pulls/1 | jq -r .head.sha)" = abcdef01234567891 ]

  stub_gh_routes
  printf '%s\n' "$output" >"$FX/pull.json"
  gh_route "api repos/o/r/pulls/1" pull.json
  rm "$FX/rest-mode"
  read_once repos/o/r/pulls/1 "$output"
}
