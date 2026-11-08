#!/usr/bin/env bats
# bench.sh CASE... (#188): only the picked cases run, plus the earlier cases each declares it needs,
# and every picked row matches the full run's row for that case.

setup_file() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  "$SCRIPTS/bench.sh" >"$BATS_FILE_TMPDIR/full.tsv"
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FULL="$BATS_FILE_TMPDIR/full.tsv"
}

@test "each case run alone prints the header and the full run's row for it" {
  # All at once (each run has its own work dir): a case that reads an earlier case's state without
  # declaring the need shows up here as a different row.
  d="$BATS_TEST_TMPDIR/alone"; mkdir -p "$d"
  cases=$(awk 'NR > 1 { print $1 }' "$FULL")
  [ "$(printf '%s\n' "$cases" | wc -l | tr -d ' ')" -ge 13 ]
  for c in $cases; do "$SCRIPTS/bench.sh" "$c" >"$d/$c" & done
  wait
  bad=""
  for c in $cases; do
    [ "$(cat "$d/$c")" = "$(sed -n 1p "$FULL"; awk -F'\t' -v c="$c" '$1 == c' "$FULL")" ] || bad+=" $c"
  done
  [ -z "$bad" ] || { echo "rows differ from the full run:$bad"; false; }
}

@test "picked cases print in the full run's order, and a need runs without printing its row" {
  run "$SCRIPTS/bench.sh" lane-wait-unchanged pr-ready-rest-100-ready excerpt-1mb-line
  [ "$status" -eq 0 ]
  [ "$output" = "$(sed -n 1p "$FULL"; awk -F'\t' '$1 ~ /^(excerpt-1mb-line|pr-ready-rest-100-ready|lane-wait-unchanged)$/' "$FULL")" ]
  # pr-ready-rest-100-ready reads the refusal pr-ready-rest-20-ready remembered: without that pass
  # its gh call count would be one higher.
  [ "$(grep -c '^pr-ready-rest-20-ready' <<<"$output" || true)" -eq 0 ]
}

@test "--timing works with picked cases" {
  run "$SCRIPTS/bench.sh" excerpt-1mb-line --timing
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<<"$output")" = "$(printf 'case\tstdout_bytes\trows\tgh_calls\tseconds\tjq_calls')" ]
  [ "$(sed -n 2p <<<"$output" | cut -f1-4)" = "$(awk -F'\t' '$1 == "excerpt-1mb-line"' "$FULL")" ]
  [ "$(wc -l <<<"$output" | tr -d ' ')" -eq 2 ]
}

@test "an unknown case name exits 2 with a message and runs nothing" {
  run "$SCRIPTS/bench.sh" excerpt-1mb-line no-such-case
  [ "$status" -eq 2 ]
  [ "$output" = "bench.sh: unknown case: no-such-case" ]
  run "$SCRIPTS/bench.sh" '*'
  [ "$status" -eq 2 ]
  [ "$output" = "bench.sh: unknown case: *" ]
  run "$SCRIPTS/bench.sh" ''
  [ "$status" -eq 2 ]
}

@test "-h documents CASE and its needs" {
  run "$SCRIPTS/bench.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: bench.sh [--timing] [CASE...]"* ]]
  [[ "$output" == *"cases each declares it needs"* ]]
}

@test "every need names an earlier case" {
  # bench_case refuses a need that is not declared before it, so a typo cannot silently drop one.
  run grep -cE '^bench_case [a-z0-9-]+ [a-z0-9-]+' "$SCRIPTS/bench.sh"
  [ "$output" -ge 1 ]
  awk '/^bench_case / { for (i = 3; i <= NF; i++) if (!($i in seen)) { print "bad need: " $i; bad = 1 } seen[$2] = 1 }
    END { exit bad }' "$SCRIPTS/bench.sh"
}
