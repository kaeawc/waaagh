#!/usr/bin/env bats
# The one GraphQL-or-REST choice (#123): orch_gh_api and orch_gh_refused in _lib.sh, which
# gh-issues.sh, pr-ready.sh, gh-snapshot.sh and lane-claim.sh all use, and the one refusal memo
# (<state root>/gh-no-graphql, 12 hours) they share. The REST suites (issues-rest.bats,
# pr-rest.bats) check each script's REST answers; this suite checks the choice and the memo once.
# Run: bats gh-api.bats

setup() {
  load test_helper
  load selftest_helper
  load rest_stub
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  stub_gh_router
  rest_wrap
  MEMO="$ORCHESTRATE_STATE_DIR/gh-no-graphql"
}

lib() { (source "$SCRIPTS/_lib.sh" && "$@"); }

@test "orch_gh_api: auto starts with GraphQL, rest and graphql are fixed, anything else is exit 2" {
  [ "$(lib orch_gh_api x.sh)" = graphql ]
  [ "$(ORCHESTRATE_GH_API=auto lib orch_gh_api x.sh)" = graphql ]
  [ "$(ORCHESTRATE_GH_API=rest lib orch_gh_api x.sh)" = rest ]
  [ "$(ORCHESTRATE_GH_API=graphql lib orch_gh_api x.sh)" = graphql ]
  ORCHESTRATE_GH_API=sometimes run lib orch_gh_api x.sh
  [ "$status" -eq 2 ]
  [ "$output" = "x.sh: ORCHESTRATE_GH_API must be auto, rest or graphql" ]
  # The memo turns auto into rest for 12 hours; it never overrides an explicit graphql.
  mkdir -p "$ORCHESTRATE_STATE_DIR"; echo "$ORCHESTRATE_NOW" >"$MEMO"
  [ "$(lib orch_gh_api x.sh)" = rest ]
  [ "$(ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 43199)) lib orch_gh_api x.sh)" = rest ]
  [ "$(ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 43200)) lib orch_gh_api x.sh)" = graphql ]
  [ "$(ORCHESTRATE_GH_API=graphql lib orch_gh_api x.sh)" = graphql ]
  echo garbage >"$MEMO"
  [ "$(lib orch_gh_api x.sh)" = graphql ]
}

@test "orch_gh_refused: only gh-read.sh's forbidden exit naming GraphQL, only in auto, records the memo" {
  refusal="HTTP 403: GitHub GraphQL is not available from Claude Code sessions (https://api.github.com/graphql)"
  no() { if "$@"; then echo "accepted: $*"; return 1; fi; }
  no lib orch_gh_refused 7 "$refusal"
  no lib orch_gh_refused 5 "HTTP 403: Resource not accessible by integration (https://api.github.com/graphql)"
  ORCHESTRATE_GH_API=graphql no lib orch_gh_refused 5 "$refusal"
  ORCHESTRATE_GH_API=rest no lib orch_gh_refused 5 "$refusal"
  [ ! -e "$MEMO" ]
  lib orch_gh_refused 5 "$refusal"
  [ "$(cat "$MEMO")" = "$ORCHESTRATE_NOW" ]
  [ "$(lib orch_gh_api x.sh)" = rest ]
}

@test "one refusal, then every script on the state root reads REST until the memo expires" {
  ready_prs 2
  touch "$FX/rest-mode"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"open=2 ready=2 api=rest"* ]]
  [ "$(grep -c '^pr list' "$FX/rest-calls")" -eq 1 ]
  [ -f "$MEMO" ]
  # Issue side and PR side alike: no GraphQL attempt while the memo is fresh.
  : >"$FX/rest-calls"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *"open=2 ready=2 api=rest"* ]]
  run "$SCRIPTS/gh-snapshot.sh" --repo o/r
  [ "$status" -eq 0 ]
  run "$SCRIPTS/lane-claim.sh" check --issues 99 --repo o/r
  [ "$output" = ok ]
  run "$SCRIPTS/gh-issues.sh" prs-open --repo o/r --fields number
  [ "$output" = '[{"number":1},{"number":2}]' ]
  [ "$(grep -cE '^pr |^issue |graphql' "$FX/rest-calls")" -eq 0 ] || { cat "$FX/rest-calls"; false; }
  # 12 hours on, GraphQL is tried again (refused again here, and remembered again).
  : >"$FX/rest-calls"
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 43200)) run "$SCRIPTS/gh-snapshot.sh" --repo o/r
  [ "$status" -eq 0 ]
  [ "$(grep -c '^api graphql' "$FX/rest-calls")" -eq 1 ]
  [ "$(cat "$MEMO")" = $((ORCHESTRATE_NOW + 43200)) ]
}
