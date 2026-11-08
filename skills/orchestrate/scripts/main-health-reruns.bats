#!/usr/bin/env bats
# main-health.sh while a rerun is going (#115): a run is judged by its newest attempt, and a rerun
# still in progress is never replaced by an older completed run of the same workflow. The runs
# endpoint (actions/runs, REST) is stubbed with the fields GitHub returns.
# Run: bats main-health-reruns.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  ST="$BATS_TEST_TMPDIR/state/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r/actions/runs?"*) jq '{total_count: length, workflow_runs: .}' "$FX/runs.json" ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# One REST run: workflow id attempt status conclusion sha created_at run_started_at
rest_run() {
  jq -cn --arg w "$1" --argjson id "$2" --argjson a "$3" --arg s "$4" --arg c "$5" --arg h "$6" \
    --arg t "$7" --arg st "$8" \
    '{name: $w, id: $id, run_attempt: $a, status: $s, conclusion: (if $c == "" then null else $c end),
      head_sha: $h, created_at: $t, run_started_at: $st}'
}
# Reads stdin fully before writing, so a caller may feed it the current runs.json.
runs() { local all; all=$(jq -s .); printf '%s\n' "$all" >"$FX/runs.json"; }
health() { "$SCRIPTS/main-health.sh" --repo o/r --branch main "$@"; }

@test "red, then its rerun in progress keeps the hold; the rerun's success clears it" {
  { rest_run Test 1 1 completed success aaaaaaaaaaaa 2026-11-08T01:00:00Z 2026-11-08T01:00:00Z
    rest_run Test 2 1 completed failure bbbbbbbbbbbb 2026-11-08T02:00:00Z 2026-11-08T02:00:00Z; } | runs
  run health
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2)" ]
  [ -f "$ST/MAIN_RED" ]
  # Rerun of run 2 started: GitHub lists attempt 2, in progress, with the run's created_at.
  { rest_run Test 1 1 completed success aaaaaaaaaaaa 2026-11-08T01:00:00Z 2026-11-08T01:00:00Z
    rest_run Test 2 2 in_progress "" bbbbbbbbbbbb 2026-11-08T02:00:00Z 2026-11-08T03:00:00Z; } | runs
  run health
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Test(rerun-in-progress)" ]
  [ -f "$ST/MAIN_RED" ]
  # Same with the workflow selected explicitly, and while the rerun is still queued.
  jq '.[1].status = "queued"' "$FX/runs.json" >"$FX/r2" && mv "$FX/r2" "$FX/runs.json"
  run health --workflow Test
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Test(rerun-in-progress)" ]
  [ -f "$ST/MAIN_RED" ]
  # The rerun succeeded: its newest attempt is the evidence and the hold clears.
  { rest_run Test 1 1 completed success aaaaaaaaaaaa 2026-11-08T01:00:00Z 2026-11-08T01:00:00Z
    rest_run Test 2 2 completed success bbbbbbbbbbbb 2026-11-08T02:00:00Z 2026-11-08T03:00:00Z; } | runs
  run health
  [ "$status" -eq 0 ]
  [ "$output" = "green bbbbbbbbb Test@bbbbbbbbb" ]
  [ ! -f "$ST/MAIN_RED" ]
}

@test "an older green run never clears the hold while a newer red run is being rerun" {
  mkdir -p "$ST"; printf 'red bbbbbbbbb Test=failure(2)\n2026-11-08T02:30:00Z\n' >"$ST/MAIN_RED"
  { rest_run Test 1 1 completed success aaaaaaaaaaaa 2026-11-08T01:00:00Z 2026-11-08T01:00:00Z
    rest_run Lint 3 1 completed success bbbbbbbbbbbb 2026-11-08T02:00:00Z 2026-11-08T02:00:00Z
    rest_run Test 2 2 in_progress "" bbbbbbbbbbbb 2026-11-08T02:00:00Z 2026-11-08T03:00:00Z; } | runs
  run health
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Test(rerun-in-progress)" ]
  [ -f "$ST/MAIN_RED" ]
  # A newer first-attempt push run of the same workflow does not hide the rerun either.
  { jq -c '.[]' "$FX/runs.json"
    rest_run Test 4 1 in_progress "" cccccccccccc 2026-11-08T04:00:00Z 2026-11-08T04:00:00Z; } | runs
  run health
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Test(rerun-in-progress)" ]
  [ -f "$ST/MAIN_RED" ]
  # Another selected workflow that is red still turns the branch red.
  { jq -c '.[]' "$FX/runs.json"
    rest_run Lint 5 1 completed failure cccccccccccc 2026-11-08T04:00:00Z 2026-11-08T04:00:00Z; } | runs
  run health
  [ "$status" -eq 1 ]
  [ "$output" = "red ccccccccc Lint=failure(5)" ]
}

@test "a rerun older than the workflow's newest completed run is not pending" {
  { rest_run Test 2 2 in_progress "" bbbbbbbbbbbb 2026-11-08T02:00:00Z 2026-11-08T03:00:00Z
    rest_run Test 4 1 completed success cccccccccccc 2026-11-08T04:00:00Z 2026-11-08T04:00:00Z; } | runs
  run health
  [ "$status" -eq 0 ]
  [ "$output" = "green ccccccccc Test@ccccccccc" ]
  # A first attempt still running is judged as before: by the newest completed run (#37).
  { rest_run Test 4 1 completed success cccccccccccc 2026-11-08T04:00:00Z 2026-11-08T04:00:00Z
    rest_run Test 5 1 in_progress "" dddddddddddd 2026-11-08T05:00:00Z 2026-11-08T05:00:00Z; } | runs
  run health
  [ "$status" -eq 0 ]
  [ "$output" = "green ccccccccc Test@ccccccccc" ]
}
