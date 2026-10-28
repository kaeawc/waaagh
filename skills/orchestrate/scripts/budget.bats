#!/usr/bin/env bats
# Output-budget ceilings over bench.sh's deterministic fixtures. A change that makes a helper put
# more in front of a model, or call gh more, fails here. Run: bats budget.bats

setup_file() {
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  "$SCRIPTS/bench.sh" >"$BATS_FILE_TMPDIR/bench.tsv"
  export BENCH="$BATS_FILE_TMPDIR/bench.tsv"
}

metric() { awk -F'\t' -v c="$1" -v col="$2" 'NR == 1 { for (i = 1; i <= NF; i++) k[$i] = i; next } $1 == c { print $k[col] }' "$BENCH"; }
within() { # CASE COLUMN MAX
  local v
  v=$(metric "$1" "$2")
  [ -n "$v" ] || { echo "no $2 for $1"; return 1; }
  [ "$v" -le "$3" ] || { echo "$1 $2=$v exceeds $3"; return 1; }
}

@test "excerpt of 20,000 failures stays within its 16 KiB budget" {
  within excerpt-20k-failures stdout_bytes 17000
  within excerpt-20k-failures rows 130
}

@test "excerpt of a 1 MB line stays under 1 KB" {
  within excerpt-1mb-line stdout_bytes 1000
}

@test "duplicate candidates for 400 identical titles stay small, from one gh call" {
  within dupes-400-identical stdout_bytes 2000
  within dupes-400-identical gh_calls 1
}

@test "pr-ready makes a constant number of gh calls for 20 and 100 ready PRs" {
  within pr-ready-20-ready gh_calls 4
  within pr-ready-100-ready gh_calls 5
  within pr-ready-100-ready rows 100
}

@test "an unchanged pr-ready --delta pass and an unchanged lane wait print one short line" {
  within pr-ready-delta-unchanged stdout_bytes 80
  within pr-ready-delta-unchanged rows 1
  within lane-wait-unchanged stdout_bytes 100
  within lane-wait-unchanged rows 1
}
