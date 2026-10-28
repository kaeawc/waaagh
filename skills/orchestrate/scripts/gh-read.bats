#!/usr/bin/env bats
# gh-read.sh against a scripted gh: each call plays the next response file. Fake clock: waits are
# logged, not slept. Run: bats gh-read.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_FAKE_SLEEP=1 GH_READ_JITTER=0
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
n=$(( $(cat "$FX/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FX/n"
f="$FX/r$n"; [ -f "$f" ] || f="$FX/r$(ls "$FX" | sed -n 's/^r\([0-9]*\)$/\1/p' | sort -n | tail -1)"
exec bash "$f"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

resp() { printf '%s\n' "$2" >"$FX/r$1"; }   # resp N 'shell that prints a response'
http() { # status headers... -> a script printing an --include response with a JSON body
  local s=$1; shift
  printf "cat <<'EOF'\n"
  printf 'HTTP/2.0 %s X\r\n' "$s"
  for h in "$@"; do printf '%s\r\n' "$h"; done
  printf '\r\n{"message":"m%s"}\nEOF\n' "$s"
  [ "$s" = 200 ] || printf "echo 'gh: failed (HTTP %s)' >&2; exit 1\n" "$s"
}
calls() { wc -l <"$FX/calls" | tr -d ' '; }
read_() { "$SCRIPTS/gh-read.sh" "$@"; }

@test "502 then success: retried after a backoff, headers stripped from the body" {
  resp 1 "$(http 502 'X-GitHub-Request-Id: AB:1')"
  resp 2 "$(http 200 'X-GitHub-Request-Id: AB:2')"
  run read_ --json -- api repos/o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-read: wait 1"* ]]
  [[ "$output" == *'{"message":"m200"}' ]]
  [[ "$output" != *"HTTP/2.0"* ]]
  [ "$(calls)" -eq 2 ]
  grep -q -- '--include' "$FX/calls"
}

@test "a call that hangs is cut at its timeout and reported transient after its tries" {
  resp 1 'sleep 5'
  run read_ --timeout 1 --tries 2 -- pr list --repo o/r
  [ "$status" -eq 7 ]
  [[ "$output" == *"gh-read: transient"*"timeout after 2 attempts"* ]]
  [ "$(calls)" -eq 2 ]
}

@test "429 with Retry-After waits that long and succeeds; the cooldown is shared" {
  resp 1 "$(http 429 'Retry-After: 5' 'X-GitHub-Request-Id: RL:1')"
  resp 2 "$(http 200)"
  run read_ -- api repos/o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-read: wait 5"* ]]
  [ "$(cat "$ORCHESTRATE_STATE_DIR/gh-cooldown")" -eq $((1790510400 + 5)) ]
}

@test "a secondary limit longer than the budget returns retry-at, and other lanes do not call GitHub" {
  resp 1 "$(http 403 'Retry-After: 120' 'X-GitHub-Request-Id: SL:9')"
  run read_ --budget 60 -- api repos/o/r
  [ "$status" -eq 6 ]
  [[ "$output" == "gh-read: rate-limited status=403 request-id=SL:9 retry-at=2026-09-27T12:02:00Z"* ]]
  [ "$(calls)" -eq 1 ]
  run read_ --budget 60 -- pr list --repo o/r
  [ "$status" -eq 6 ]
  [[ "$output" == *"shared cooldown"* ]]
  [ "$(calls)" -eq 1 ]
  # Within the budget, a later lane waits for the reset instead.
  resp 2 "$(http 200)"
  run read_ --budget 200 -- api repos/o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-read: wait 120"* ]]
}

@test "exhausted primary quota waits until the reset time" {
  resp 1 "$(http 403 'X-RateLimit-Remaining: 0' "X-RateLimit-Reset: $((1790510400 + 30))")"
  resp 2 "$(http 200)"
  run read_ -- api repos/o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-read: wait 30"* ]]
}

@test "server errors stop when the budget is spent" {
  resp 1 "$(http 503)"
  run read_ --budget 4 --tries 10 -- api repos/o/r
  [ "$status" -eq 7 ]
  [[ "$output" == *"gh-read: transient status=503"* ]]
  [ "$(calls)" -eq 3 ]   # waits 1 and 2 fit in 4 seconds, the next wait of 4 does not
}

@test "permission denial, auth and not-found are reported at once, not retried" {
  resp 1 "$(http 403 'X-GitHub-Request-Id: P:1')"
  run read_ -- api repos/o/r/actions/secrets
  [ "$status" -eq 5 ]
  [[ "$output" == "gh-read: forbidden status=403 request-id=P:1"* ]]
  [ "$(calls)" -eq 1 ]
  rm "$FX/r1"; : >"$FX/n"; resp 1 "$(http 401)"
  run read_ -- api user
  [ "$status" -eq 4 ]
  rm "$FX/r1"; : >"$FX/n"; resp 1 "echo 'GraphQL: Could not resolve to a PullRequest (HTTP 404)' >&2; exit 1"
  run read_ -- pr view 9 --repo o/r
  [ "$status" -eq 3 ]
  [ "$(calls)" -eq 3 ]
}

@test "malformed JSON is retried, then reported" {
  resp 1 'echo "<html>unicorn</html>"'
  run read_ --json --tries 2 -- pr list --repo o/r
  [ "$status" -eq 8 ]
  [[ "$output" == *"gh-read: malformed"* ]]
  resp 2 'echo "[]"'
  : >"$FX/n"
  run read_ --json --tries 2 -- pr list --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "gh-read: wait 1"$'\n'"[]" ]
}

@test "writes are refused without calling gh, so nothing can be replayed" {
  resp 1 'echo should-not-run'
  for args in "pr merge 1" "pr create --title t" "issue close 5" "issue comment 5 --body x" "run rerun 9" \
              "api -X POST repos/o/r/issues" "api repos/o/r/issues -f title=x" "api --method=PATCH repos/o/r" \
              "api graphql -f query=mutation{x}"; do
    # shellcheck disable=SC2086
    run read_ -- $args
    [ "$status" -eq 2 ] || { echo "not refused: $args"; false; }
  done
  [ ! -e "$FX/calls" ]
  run read_ -- api graphql -f 'query=query{viewer{login}}'
  [ "$status" -eq 0 ]
  run read_ -- api -X GET search/issues -f q=x
  [ "$status" -eq 0 ]
}

@test "tokens in error text are redacted" {
  resp 1 "echo 'bad token ghp_abcdefghijklmnopqrstuvwxyz0123 (HTTP 401)' >&2; exit 1"
  run read_ -- pr list --repo o/r
  [ "$status" -eq 4 ]
  [[ "$output" != *ghp_abcdef* ]]
  [[ "$output" == *"[REDACTED]"* ]]
}
