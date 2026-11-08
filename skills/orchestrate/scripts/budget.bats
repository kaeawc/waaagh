#!/usr/bin/env bats
# Output-budget ceilings over bench.sh's deterministic fixtures. A change that makes a helper put
# more in front of a model, or call gh more, fails here. Also bench.sh --timing (#176): seconds and
# jq process counts per case, as two extra columns; without the flag the TSV is byte-identical to the
# four-column output the ceilings read. Run: bats budget.bats

setup_file() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  # One plain run and one --timing run, side by side (#180): the ceilings read the plain TSV, the
  # --timing checks compare the two. Each run works in its own mktemp dir.
  "$SCRIPTS/bench.sh" >"$BATS_FILE_TMPDIR/bench.tsv" &
  local plain=$!
  "$SCRIPTS/bench.sh" --timing >"$BATS_FILE_TMPDIR/timing.tsv"
  wait "$plain"
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BENCH="$BATS_FILE_TMPDIR/bench.tsv" TIMING="$BATS_FILE_TMPDIR/timing.tsv"
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

@test "pr-ready over REST (GraphQL refused) makes a constant plus four gh calls per ready PR" {
  # 3 constant (rules, branch protection, the refused GraphQL list) + one list call per 100 PRs
  # (and one more when the last page is full), then per PR: pulls/<n>, check-runs, status, threads.
  within pr-ready-rest-20-ready gh_calls 84
  within pr-ready-rest-20-ready rows 20
  within pr-ready-rest-100-ready gh_calls 405
  within pr-ready-rest-100-ready rows 100
}

@test "an unchanged pr-ready --delta pass and an unchanged lane wait print one short line" {
  within pr-ready-delta-unchanged stdout_bytes 80
  within pr-ready-delta-unchanged rows 1
  within lane-wait-unchanged stdout_bytes 100
  within lane-wait-unchanged rows 1
}

@test "triage-tick snapshot with 50 open PRs takes the count and last reviews from one snapshot call" {
  # main health, gh-snapshot.sh (one GraphQL page), the PR list for closing references, the issue
  # list, then thread-sweep.sh at 25 PRs a page: 6 calls (#118).
  within triage-tick-50-open gh_calls 6
  within triage-tick-50-open rows 9
}

@test "triage-tick snapshot over REST (GraphQL refused) costs a constant plus four calls per open PR" {
  # main health, the refused snapshot GraphQL page, the REST open list, then per PR check-runs,
  # status and reviews (gh-snapshot.sh unchanged); the dispatch queue's REST PR and issue lists
  # (#136); thread-sweep.sh's REST open list, then per PR its review threads (no thread: no
  # comments or commits read).
  within triage-tick-rest-50-open gh_calls 210
  within triage-tick-rest-50-open rows 9
}

@test "review-gate check with a fresh snapshot row and no review reads only the comments" {
  within review-gate-check-cold gh_calls 3
  within review-gate-check-snapshot gh_calls 1
}

# --- bench.sh --timing (#176) ---

col() { awk -F'\t' -v c="$1" -v col="$2" 'NR == 1 { for (i = 1; i <= NF; i++) k[$i] = i; next } $1 == c { print $k[col] }' "$TIMING"; }

@test "without --timing the header keeps exactly the four budget columns" {
  [ "$(sed -n 1p "$BENCH")" = "$(printf 'case\tstdout_bytes\trows\tgh_calls')" ]
  [ "$(awk -F'\t' 'NF != 4' "$BENCH" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "--timing appends seconds and jq_calls, leaving the first four columns as they were" {
  [ "$(sed -n 1p "$TIMING")" = "$(printf 'case\tstdout_bytes\trows\tgh_calls\tseconds\tjq_calls')" ]
  [ "$(cut -f1-4 "$TIMING")" = "$(cat "$BENCH")" ]
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
