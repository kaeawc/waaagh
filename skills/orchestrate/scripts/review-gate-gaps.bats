#!/usr/bin/env bats
# review-gate.sh paths review-gate.bats does not reach: an unknown policy in the state file, a
# review request that fails (exit 5), every green-only / reviewed-once verdict, an unknown bot id
# in ORCHESTRATE_REVIEW_BOTS, the empty outage listing and unknown subcommands. Stubbed gh.
# Run: bats scripts/review-gate-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1793880000
  unset ORCHESTRATE_REVIEW_BOTS ORCHESTRATE_REVIEW_EVERY ORCHESTRATE_REVIEW_PROBE_EVERY
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$STATE"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  OLD=1111111234567890abcdef1234567890abcdef12
  echo '[]' >"$FX/reviews.json"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r/pulls/"*"/reviews"*) cat "$FX/reviews.json" ;;
  "api repos/o/r/issues/"*"/comments"*) echo '[]' ;;
  "pr comment"*) [ ! -f "$FX/comment-fails" ] || { echo "HTTP 403" >&2; exit 4; }; echo "$*" >>"$FX/writes" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

rg() { "$SCRIPTS/review-gate.sh" "$@" --repo o/r; }
review() { # LOGIN COMMIT
  jq --arg l "$1" --arg c "$2" '. + [{user: {login: $l}, commit_id: $c, body: "ok", state: "COMMENTED", submitted_at: "2026-11-05T09:00:00Z"}]' \
    "$FX/reviews.json" >"$FX/r.tmp" && mv "$FX/r.tmp" "$FX/reviews.json"
}

@test "check: an unknown policy in the state file is a usage error, never ok, and reads nothing" {
  echo sometimes >"$STATE/review-policy"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 2 ]
  [[ "$output" == "review-gate.sh: unknown policy 'sometimes' in $STATE/review-policy" ]]
  [ ! -f "$FX/calls" ]
}

@test "check: green-only and reviewed-once verdicts for never, earlier and at-head reviews" {
  # policy | review commit ("" none) | exit | output
  while IFS='|' read -r policy commit want_rc want; do
    echo "$policy" >"$STATE/review-policy"
    echo '[]' >"$FX/reviews.json"
    case "$commit" in old) review coderabbitai "$OLD" ;; head) review "chatgpt-codex-connector[bot]" "$HEAD" ;; esac
    run rg check --pr 5 --head "$HEAD"
    [ "$status" -eq "$want_rc" ] && [ "$output" = "$want" ] ||
      { echo "$policy/$commit: exit $status output '$output'"; return 1; }
  done <<'CASES'
green-only|none|0|ok unreviewed green-only (never)
green-only|old|0|ok unreviewed green-only (earlier)
green-only|head|0|ok reviewed at-head
reviewed-once|none|3|wait never-reviewed
reviewed-once|old|0|ok reviewed earlier-head (reviewed-once)
reviewed-once|head|0|ok reviewed at-head
CASES
}

@test "check: a bot id with no known login in ORCHESTRATE_REVIEW_BOTS never counts anyone's review" {
  echo review-at-head >"$STATE/review-policy"
  review coderabbitai "$HEAD"
  ORCHESTRATE_REVIEW_BOTS="mystery" run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$output" = "wait never-reviewed" ]
  ORCHESTRATE_REVIEW_BOTS="mystery coderabbit" run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok reviewed at-head" ]
  ORCHESTRATE_REVIEW_BOTS="mystery" run rg notice --author mystery <<<"usage limits reached"
  [ "$output" = other ]
}

@test "request: a failed comment is exit 5, logged, kept queued, and does not start the window" {
  touch "$FX/comment-fails"
  run rg request --bot codex --pr 7
  [ "$status" -eq 5 ]
  [ "$output" = "request to codex on PR 7 failed (exit 4); still queued" ]
  grep -q $'\tcodex\tpr=7\tfailed exit=4$' "$STATE/review-requests.log"
  [ "$(cut -f1 "$STATE/review-queue/codex.tsv")" = 7 ]
  [ ! -f "$STATE/review-queue/codex.last" ]
  rm "$FX/comment-fails"
  run rg request --bot codex
  [ "$status" -eq 0 ] && [ "$output" = "requested codex pr=7 queued=0" ]
}

@test "outage with no flags says so; unknown outage and ledger subcommands and commands are usage errors" {
  run rg outage
  [ "$status" -eq 0 ]
  [ "$output" = "no reviewer out of quota" ]
  for args in "outage sometimes" "ledger sometimes" "frobnicate"; do
    # shellcheck disable=SC2086
    run rg $args
    [ "$status" -eq 2 ] || { echo "$args: exit $status"; return 1; }
  done
}
