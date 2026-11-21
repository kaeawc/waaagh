#!/usr/bin/env bats
# Posting the reviewer's findings (ORCHESTRATE_REVIEW_POST=comment): review-ledger.sh record
# --findings posts them on the PR as a COMMENT review, never approve or request changes, once per
# PR, head and verdict. Off by default; a failed post warns and keeps the verdict's exit code.
# Run: bats scripts/review-post.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r" "$BATS_TEST_TMPDIR/bin"
  F="$BATS_TEST_TMPDIR/findings.md"
  # shellcheck disable=SC2016 # Markdown backticks
  printf 'input-meaning: unchanged\n\n- should-fix `a.sh:3` off by one\n' >"$F"
  export CALLS="$BATS_TEST_TMPDIR/calls" REVIEWS="$BATS_TEST_TMPDIR/reviews.json" POSTED="$BATS_TEST_TMPDIR/posted.md"
  echo '[]' >"$REVIEWS"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "${1:-} ${2:-}" in
  "api repos/o/r/pulls/5/reviews"*) cat "$REVIEWS" ;;
  "pr review")
    [[ -n "${GH_FAIL_POST:-}" ]] && exit 1
    while (($#)); do [[ "$1" == --body-file ]] && cp "$2" "$POSTED"; shift; done ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

rl() { "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 5 "$@"; }

@test "off by default: nothing is posted" {
  run rl --verdict fix-first --head abc --findings "$F"
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
}

@test "comment: posts the findings as a COMMENT review with the marker" {
  ORCHESTRATE_REVIEW_POST=comment run rl --verdict fix-first --head abc --findings "$F"
  [ "$status" -eq 0 ]
  [[ "$output" == *"posted: review comment on PR 5"* ]]
  run grep -c -- '^pr review 5 --repo o/r --comment --body-file ' "$CALLS"
  [ "$output" -eq 1 ]
  run grep -c -- '--approve\|--request-changes' "$CALLS"
  [ "$output" -eq 0 ]
  # shellcheck disable=SC2016 # Markdown backticks
  grep -qF '**waaagh review**: `fix-first` at `abc`' "$POSTED"
  grep -qF 'off by one' "$POSTED"
  grep -qF '<!-- waaagh-review pr=5 head=abc verdict=fix-first -->' "$POSTED"
}

@test "comment: the same PR, head and verdict already posted is not posted again" {
  jq -n '[{body: "x\n<!-- waaagh-review pr=5 head=abc verdict=ship -->"}]' >"$REVIEWS"
  ORCHESTRATE_REVIEW_POST=comment run rl --verdict ship --head abc --findings "$F"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review already posted: PR 5 ship at abc"* ]]
  run grep -c '^pr review' "$CALLS"
  [ "$output" -eq 0 ]
}

@test "comment: a new head is posted even when an older head was" {
  jq -n '[{body: "<!-- waaagh-review pr=5 head=abc verdict=ship -->"}]' >"$REVIEWS"
  ORCHESTRATE_REVIEW_POST=comment run rl --verdict ship --head def --findings "$F"
  [ "$status" -eq 0 ]
  [[ "$output" == *"posted: review comment on PR 5"* ]]
}

@test "comment: a failed post warns and keeps the verdict and exit code" {
  GH_FAIL_POST=1 ORCHESTRATE_REVIEW_POST=comment run rl --verdict fix-first --head abc --findings "$F"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: review not posted on PR 5"* ]]
  run "$SCRIPTS/review-ledger.sh" latest --repo o/r --pr 5
  [ "$(cut -f3 <<<"$output")" = fix-first ]
}

@test "comment: an incomplete ship is still posted and still exits 6" {
  printf 'No findings.\n' >"$F"
  ORCHESTRATE_REVIEW_POST=comment run rl --verdict ship --head abc --findings "$F"
  [ "$status" -eq 6 ]
  grep -qF 'verdict=incomplete' "$POSTED"
}

@test "an unknown ORCHESTRATE_REVIEW_POST value is a usage error" {
  ORCHESTRATE_REVIEW_POST=approve run rl --verdict ship --findings "$F"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be off or comment"* ]]
}

@test "an unknown ORCHESTRATE_REVIEW_POST value does not break the other subcommands" {
  ORCHESTRATE_REVIEW_POST=on run "$SCRIPTS/review-ledger.sh" fix --repo o/r --pr 5
  [ "$status" -eq 0 ]
  ORCHESTRATE_REVIEW_POST=on run "$SCRIPTS/review-ledger.sh" latest --repo o/r --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *fixing* ]]
}
