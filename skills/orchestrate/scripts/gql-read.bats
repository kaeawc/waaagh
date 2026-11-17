#!/usr/bin/env bats
# orch_gql_read (_lib.sh): a bounded GraphQL read that reports a refusal; gh-rest-pr.sh --tries.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_FAKE_SLEEP=1 GH_READ_JITTER=0
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
mode=$(cat "$FX/mode" 2>/dev/null || true)
case "$mode" in
  refuse)
    printf 'HTTP/2.0 403 Forbidden\r\n\r\n{"message":"GitHub GraphQL is not available from Claude Code sessions"}\n'
    echo "HTTP 403: GitHub GraphQL is not available from Claude Code sessions (https://api.github.com/graphql)" >&2
    exit 1 ;;
  boom)
    printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{}\n'
    echo "gh: Bad Gateway (HTTP 502)" >&2
    exit 1 ;;
  *) echo '[{"number":1}]' ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

calls() { if [ -f "$FX/calls" ]; then wc -l <"$FX/calls" | tr -d ' '; else echo 0; fi; }
gql() { (source "$SCRIPTS/_lib.sh" && orch_gql_read "$@"); }

@test "orch_gql_read prints the body and returns 0" {
  run gql 3 --json gh pr list --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = '[{"number":1}]' ]
}

@test "orch_gql_read returns 2, prints refused and records the memo when GraphQL is refused" {
  echo refuse >"$FX/mode"
  run gql 3 gh pr list --repo o/r
  [ "$status" -eq 2 ]
  [ "$output" = refused ]
  [ "$(cat "$ORCHESTRATE_STATE_DIR/gh-no-graphql")" = 1790510400 ]
}

@test "orch_gql_read does not treat a refusal as one when ORCHESTRATE_GH_API=graphql" {
  echo refuse >"$FX/mode"
  ORCHESTRATE_GH_API=graphql run gql 3 gh pr list --repo o/r
  [ "$status" -eq 1 ]
  [ ! -e "$ORCHESTRATE_STATE_DIR/gh-no-graphql" ]
}

@test "orch_gql_read returns 1 after N attempts on another failure, with no memo" {
  echo boom >"$FX/mode"
  run gql 2 gh pr list --repo o/r
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ "$(calls)" -eq 2 ]
  [ ! -e "$ORCHESTRATE_STATE_DIR/gh-no-graphql" ]
}

@test "gh-rest-pr.sh --tries bounds its gh-read.sh retries" {
  echo boom >"$FX/mode"
  run --separate-stderr "$SCRIPTS/gh-rest-pr.sh" list --repo o/r --tries 2
  [ "$status" -eq 3 ]
  [ "$(calls)" -eq 2 ]
}

@test "gh-rest-pr.sh retries up to 4 times without --tries" {
  echo boom >"$FX/mode"
  run --separate-stderr "$SCRIPTS/gh-rest-pr.sh" list --repo o/r
  [ "$status" -eq 3 ]
  [ "$(calls)" -eq 4 ]
}

@test "gh-rest-pr.sh --tries must be a positive number" {
  run --separate-stderr "$SCRIPTS/gh-rest-pr.sh" list --repo o/r --tries 0
  [ "$status" -eq 2 ]
  [ "$(calls)" -eq 0 ]
}

@test "the REST test rows carry state and a full 40-character head" {
  load selftest_helper
  FX="$BATS_TEST_TMPDIR/fx"
  row=$(pr_row 12 me false false MERGEABLE '[]')
  [ "$(jq -r .state <<<"$row")" = OPEN ]
  [ "$(jq -r '.headRefOid | length' <<<"$row")" -eq 40 ]
  [ "$(jq -r .headRefOid <<<"$row")" = abcdef0123456789abcdef0123456789abcdef12 ]
  run pr_rows 98 101 me false false MERGEABLE '[]'
  [ "$(jq -rs 'map(.headRefOid | length) | unique | join(",")' <<<"$output")" = 40 ]
}
