#!/usr/bin/env bats
# Gaps in gh-read.bats: the write refusal (api methods and fields, non-read subcommands, GraphQL
# with a non-POST method), status-less failures classified as auth or transient, and an
# unexpected HTTP status reported as a plain error. Run: bats gh-read-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_FAKE_SLEEP=1 GH_READ_JITTER=0
  # gh plays $FX/resp (a shell snippet) on every call and logs its arguments.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
if [ -f "$FX/resp" ]; then exec bash "$FX/resp"; fi
echo '{}'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

calls() { if [ -f "$FX/calls" ]; then wc -l <"$FX/calls" | tr -d ' '; else echo 0; fi; }

@test "writes are refused with exit 2 before gh runs" {
  local fails="" args
  while IFS= read -r args; do
    [ -n "$args" ] || continue
    # shellcheck disable=SC2086
    set -f; run "$SCRIPTS/gh-read.sh" -- $args; set +f
    if [ "$status" -ne 2 ] || [[ "$output" != *"refused: not a read"* ]]; then
      fails="$fails
[$args] status=$status $output"
    fi
  done <<'CASES'
api -X POST repos/o/r/issues
api -XPOST repos/o/r/issues
api -Xpatch repos/o/r/pulls/1
api --method DELETE repos/o/r/git/refs/heads/x
api --method=PUT repos/o/r/pulls/1/merge
api -X post repos/o/r/labels
api repos/o/r/issues -f title=x
api repos/o/r/issues -F body=@f
api repos/o/r/issues --field title=x
api repos/o/r/issues --raw-field title=x
api repos/o/r/issues --input body.json
api graphql -X GET -f query=q
api graphql -XPUT -f query=q
api graphql -f query=mutation{x}
api graphql --raw-field query=mutation{addComment}
pr merge 1
pr create --fill
pr comment 1 -b x
pr edit 1
issue comment 1 -b x
issue close 1
run rerun 1
repo delete o/r
label create x
release create v1
workflow run ci
secret set X
CASES
  [ -z "$fails" ] || { echo "not refused:$fails"; return 1; }
  [ "$(calls)" -eq 0 ]
}

@test "reads with explicit GET, -XGET, or a GraphQL query (POST) are run" {
  local fails="" args
  while IFS= read -r args; do
    [ -n "$args" ] || continue
    # shellcheck disable=SC2086
    set -f; run "$SCRIPTS/gh-read.sh" -- $args; set +f
    [ "$status" -eq 0 ] || fails="$fails
[$args] status=$status $output"
  done <<'CASES'
api -X GET repos/o/r/issues -f state=open
api -XGET repos/o/r/issues -F per_page=100
api --method=get repos/o/r
api graphql -f query={viewer{login}}
api graphql -X POST -f query={viewer{login}}
api graphql -XPOST -F query=@q.graphql
pr view 1
run view 2
release view v1
search prs --author x
CASES
  [ -z "$fails" ] || { echo "refused:$fails"; return 1; }
  [ "$(calls)" -eq 10 ]
}

@test "a failure with no HTTP status naming authentication is auth (exit 4), not retried" {
  printf '%s\n' "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4" >"$FX/resp"
  run "$SCRIPTS/gh-read.sh" -- pr list --repo o/r
  [ "$status" -eq 4 ]
  [[ "$output" == "gh-read: auth status=- request-id=- retry-at=- msg="*"gh auth login"* ]]
  [ "$(calls)" -eq 1 ]
  printf '%s\n' "echo 'error: Bad credentials' >&2; exit 1" >"$FX/resp"
  run "$SCRIPTS/gh-read.sh" -- issue view 3
  [ "$status" -eq 4 ]
  [[ "$output" == "gh-read: auth "* ]]
}

@test "status-less network errors and unknown errors are transient: retried, then exit 7" {
  local err fails=""
  for err in 'dial tcp: connection refused' 'read: connection reset by peer' 'could not resolve host' \
    'unexpected EOF' 'TLS handshake timeout' 'something odd happened'; do
    rm -f "$FX/calls"
    printf "echo '%s' >&2; exit 1\n" "$err" >"$FX/resp"
    run "$SCRIPTS/gh-read.sh" --tries 3 -- pr list --repo o/r
    if [ "$status" -ne 7 ] || [[ "$output" != *"gh-read: transient status=- "*"after 3 attempts"* ]] ||
      [ "$(calls)" -ne 3 ] || [[ "$output" != *"gh-read: wait 1"*"gh-read: wait 2"* ]]; then
      fails="$fails
[$err] status=$status calls=$(calls) $output"
    fi
  done
  [ -z "$fails" ] || { echo "$fails"; return 1; }
}

@test "an unexpected HTTP status is a plain error (exit 7) on the first try" {
  cat >"$FX/resp" <<'R'
printf 'HTTP/2.0 422 Unprocessable\r\nX-GitHub-Request-Id: UE:7\r\n\r\n{"message":"Validation Failed"}\n'
echo 'gh: Validation Failed (HTTP 422)' >&2; exit 1
R
  run "$SCRIPTS/gh-read.sh" -- api repos/o/r/pulls
  [ "$status" -eq 7 ]
  [[ "$output" == "gh-read: error status=422 request-id=UE:7 retry-at=- msg="*"Validation Failed"* ]]
  [ "$(calls)" -eq 1 ]
  # Without --include (a non-api read) the status comes from gh's stderr.
  rm -f "$FX/calls"
  printf '%s\n' "echo 'gh: Conflict (HTTP 409)' >&2; exit 1" >"$FX/resp"
  run "$SCRIPTS/gh-read.sh" -- pr view 1
  [ "$status" -eq 7 ]
  [[ "$output" == "gh-read: error status=409 "* ]]
  [ "$(calls)" -eq 1 ]
}

@test "a 403 without rate-limit signs is forbidden (exit 5), not retried" {
  cat >"$FX/resp" <<'R'
printf 'HTTP/2.0 403 Forbidden\r\nX-GitHub-Request-Id: FB:1\r\n\r\n{"message":"Resource not accessible by integration"}\n'
echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1
R
  run "$SCRIPTS/gh-read.sh" -- api repos/o/r/actions/secrets
  [ "$status" -eq 5 ]
  [[ "$output" == "gh-read: forbidden status=403 request-id=FB:1 "* ]]
  [ "$(calls)" -eq 1 ]
}
