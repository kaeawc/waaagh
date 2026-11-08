#!/usr/bin/env bats
# bench.sh --timing (#176): seconds and jq process counts per case, as two extra columns; without
# the flag the TSV is byte-identical to the four-column output budget.bats reads.

setup_file() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  "$SCRIPTS/bench.sh" >"$BATS_FILE_TMPDIR/plain.tsv"
  "$SCRIPTS/bench.sh" --timing >"$BATS_FILE_TMPDIR/timing.tsv"
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLAIN="$BATS_FILE_TMPDIR/plain.tsv" TIMING="$BATS_FILE_TMPDIR/timing.tsv"
}

col() { awk -F'\t' -v c="$1" -v col="$2" 'NR == 1 { for (i = 1; i <= NF; i++) k[$i] = i; next } $1 == c { print $k[col] }' "$TIMING"; }

@test "without --timing the header keeps exactly the four budget columns" {
  [ "$(sed -n 1p "$PLAIN")" = "$(printf 'case\tstdout_bytes\trows\tgh_calls')" ]
  [ "$(awk -F'\t' 'NF != 4' "$PLAIN" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "--timing appends seconds and jq_calls, leaving the first four columns as they were" {
  [ "$(sed -n 1p "$TIMING")" = "$(printf 'case\tstdout_bytes\trows\tgh_calls\tseconds\tjq_calls')" ]
  [ "$(cut -f1-4 "$TIMING")" = "$(cat "$PLAIN")" ]
  [ "$(awk -F'\t' 'NR > 1 && ($5 !~ /^[0-9]+\.[0-9][0-9]$/ || $6 !~ /^[0-9]+$/)' "$TIMING" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "--timing counts the scripts' jq processes, not the stub gh's" {
  # excerpt.sh and the lane waiter start no jq; issue-candidates.sh's jq calls are counted though
  # the stub serves its gh call with jq too.
  [ "$(col excerpt-20k-failures jq_calls)" -eq 0 ]
  [ "$(col lane-wait-unchanged jq_calls)" -eq 0 ]
  [ "$(col dupes-400-identical jq_calls)" -gt 0 ]
  # REST pr-ready reads per PR, so it starts more jq processes than the GraphQL path.
  [ "$(col pr-ready-rest-100-ready jq_calls)" -gt "$(col pr-ready-100-ready jq_calls)" ]
}

@test "-h prints the header, which documents --timing; an unknown argument exits 2" {
  run "$SCRIPTS/bench.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--timing"* ]]
  [[ "$output" == *"Exit: 0 done, 2 bad usage."* ]]
  run "$SCRIPTS/bench.sh" --timing --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument: --nope"* ]]
}
