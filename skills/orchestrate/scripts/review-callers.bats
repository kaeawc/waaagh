#!/usr/bin/env bats
# Callers of changed functions (#211): when a PR changes what an input means, the reviewer's
# verdict must list every caller. review-ledger.sh record --findings checks a ship verdict's
# findings file for the `input-meaning:` line and, for `changed`, the callers section; an
# incomplete ship is recorded as `incomplete`, holds the PR, and exits 6. The review brief and
# SKILL.md carry the rule. No gh calls. Run: bats scripts/review-callers.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ORCH="$(cd "$SCRIPTS/.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  F="$BATS_TEST_TMPDIR/findings.md"
}

rl() { "$SCRIPTS/review-ledger.sh" "$1" --repo o/r "${@:2}"; }
verdict_of() { rl latest --pr "$1" | cut -f3; }

@test "a ship with input-meaning unchanged is recorded as ship" {
  printf 'input-meaning: unchanged\n\nNo findings.\n' >"$F"
  run rl record --pr 5 --verdict ship --head abc --findings "$F"
  [ "$status" -eq 0 ]
  [ "$(verdict_of 5)" = ship ]
  [ ! -s "$ST/holds" ]
}

@test "a ship with input-meaning changed and a callers section listing callers is recorded as ship" {
  cat >"$F" <<'EOF'
- Input-Meaning: Changed

## Callers of changed functions
- `explore.ts:88` -> `tapAt`: passes screenshot pixels — correct

## Findings
No findings.
EOF
  run rl record --pr 5 --verdict ship --findings "$F"
  [ "$status" -eq 0 ]
  [ "$(verdict_of 5)" = ship ]
}

@test "a ship whose findings declare no input-meaning line is incomplete: recorded, held, exit 6" {
  printf 'No findings.\n' >"$F"
  run rl record --pr 5 --verdict ship --head abc --note looks-good --findings "$F"
  [ "$status" -eq 6 ]
  [[ "$output" == *"incomplete ship: no input-meaning: changed|unchanged line; looks-good"* ]]
  [ "$(verdict_of 5)" = incomplete ]
  run grep -c '^5 until:review-ship .*review incomplete: incomplete ship' "$ST/holds"
  [ "$output" -eq 1 ]
  run rl blocked
  [ "$output" = $'5\tincomplete' ]
  # A complete ship afterwards releases the hold.
  printf 'input-meaning: unchanged\n' >"$F"
  run rl record --pr 5 --verdict ship --findings "$F"
  [ "$status" -eq 0 ]
  [ ! -s "$ST/holds" ]
}

@test "input-meaning changed without the callers section is incomplete" {
  printf 'input-meaning: changed\n\n## Findings\nNo findings.\n' >"$F"
  run rl record --pr 5 --verdict ship --findings "$F"
  [ "$status" -eq 6 ]
  [[ "$output" == *"input meaning changed but no Callers of changed functions section"* ]]
  [ "$(verdict_of 5)" = incomplete ]
}

@test "input-meaning changed with an empty callers section is incomplete" {
  printf 'input-meaning: changed\n\n## Callers of changed functions\n\n## Findings\nNone.\n' >"$F"
  run rl record --pr 5 --verdict ship --findings "$F"
  [ "$status" -eq 6 ]
  [[ "$output" == *"the Callers of changed functions section lists no caller"* ]]
}

@test "an incomplete ship on a PR held already keeps the hold and still exits 6" {
  rl record --pr 5 --verdict fix-first >/dev/null
  printf 'input-meaning: maybe\n' >"$F"
  run rl record --pr 5 --verdict ship --findings "$F"
  [ "$status" -eq 6 ]
  [[ "$output" == *"already held:"* ]]
  [ "$(verdict_of 5)" = incomplete ]
}

@test "--findings: unreadable file is exit 4 and records nothing; non-ship verdicts skip the check" {
  run rl record --pr 5 --verdict ship --findings "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 4 ]
  [[ "$output" == *"could not read findings"* ]]
  [ ! -e "$ST/reviews.tsv" ]
  printf 'nothing\n' >"$F"
  run rl record --pr 5 --verdict fix-first --findings "$F"
  [ "$status" -eq 0 ]
  [ "$(verdict_of 5)" = fix-first ]
  run rl fix --pr 5 --findings "$F"
  [ "$status" -eq 2 ]
}

@test "the review brief requires the input-meaning line and the callers section; SKILL.md points to it" {
  b=$(cat "$ORCH/roles/review.md")
  [[ "$b" == *"## Callers of changed functions"* ]]
  [[ "$b" == *"input-meaning: changed"* ]]
  [[ "$b" == *"input-meaning: unchanged"* ]]
  [[ "$b" == *"internal ones included"* ]]
  [[ "$b" == *"record --findings"* ]]
  [[ "$b" == *'records it as `incomplete`'* ]]
  s=$(cat "$ORCH/SKILL.md")
  [[ "$s" == *"Callers of changed functions"* ]]
  [[ "$s" == *"--findings <file>"* ]]
}
