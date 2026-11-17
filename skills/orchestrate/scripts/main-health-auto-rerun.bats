#!/usr/bin/env bats
# main-health.sh --auto-rerun (#270): a red default branch whose every red run the classifier calls
# rerunnable is re-run once per run id (through triage-tick.sh rerun, logged to reruns.log) and
# stays held until the rerun is green; anything else, or a rerun that fails again, stays held and
# is named on the red line. gh (actions/runs, run view, run rerun) and the classifier are stubbed.
# Run: bats main-health-auto-rerun.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  ST="$BATS_TEST_TMPDIR/state/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  unset ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_MAIN_AUTO_RERUN
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r/actions/runs?"*) jq '{total_count: length, workflow_runs: .}' "$FX/runs.json" ;;
  "run view "*"--log-failed"*) cat "$FX/log" 2>/dev/null || true ;;
  "run view "*"--json"*) if [ -f "$FX/meta-fails" ]; then echo "HTTP 502" >&2; exit 1; fi; echo '{"headSha":"bbbbbbbbbbbb","workflowName":"Test"}' ;;
  "run rerun"*) if [ -f "$FX/rerun-fails" ]; then echo "HTTP 403: cannot rerun" >&2; exit 1; fi; echo ok ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  cat >"$BATS_TEST_TMPDIR/bin/classify" <<'STUB'
#!/usr/bin/env bash
# classify --repo R --run ID -> the verdict written for that run id
echo "$*" >>"$FX/classified"
cat "$FX/class-$4" 2>/dev/null || true
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/classify"
  echo "Run tests: assertion failed" >"$FX/log"
  : >"$FX/calls"
}

# One REST run: workflow id attempt status conclusion sha created_at
rest_run() {
  jq -cn --arg w "$1" --argjson id "$2" --argjson a "$3" --arg s "$4" --arg c "$5" --arg h "$6" --arg t "$7" \
    '{name: $w, id: $id, run_attempt: $a, status: $s, conclusion: (if $c == "" then null else $c end),
      head_sha: $h, created_at: $t}'
}
runs() { local all; all=$(jq -s .); printf '%s\n' "$all" >"$FX/runs.json"; }
red_test() { # attempt status conclusion
  { rest_run Test 1 1 completed success aaaaaaaaaaaa 2026-11-08T01:00:00Z
    rest_run Test 2 "$1" "$2" "$3" bbbbbbbbbbbb 2026-11-08T02:00:00Z; } | runs
}
health() { "$SCRIPTS/main-health.sh" --repo o/r --branch main "$@"; }
reruns_requested() { grep -c '^run rerun' "$FX/calls" || true; }

@test "a red run the classifier calls a flake is re-run once and held until the rerun is green" {
  echo "flake: network" >"$FX/class-2"
  red_test 1 completed failure
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=requested runs=2:failed-jobs" ]
  grep -qx 'run rerun 2 --failed --repo o/r' "$FX/calls"
  [ "$(grep -c $'run=2\t.*rerun-requested$' "$ST/reruns.log")" -eq 1 ]
  [ "$(sed -n 1p "$ST/MAIN_RED")" = "$output" ]
  # GitHub has not started attempt 2 yet: still red, never a second rerun.
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=held runs=2:rerun-pending" ]
  [ "$(reruns_requested)" -eq 1 ]
  # The rerun is going: no evidence, the hold stays.
  red_test 2 in_progress ""
  run health --auto-rerun --classifier classify
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Test(rerun-in-progress)" ]
  [ -f "$ST/MAIN_RED" ]
  # Green rerun: the hold clears.
  red_test 2 completed success
  run health --auto-rerun --classifier classify
  [ "$status" -eq 0 ]
  [ "$output" = "green bbbbbbbbb Test@bbbbbbbbb" ]
  [ ! -f "$ST/MAIN_RED" ]
  [ "$(reruns_requested)" -eq 1 ]
}

@test "a rerun that fails again stays held and is named, with no second rerun" {
  echo "known-flake" >"$FX/class-2"
  red_test 1 completed failure
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  red_test 2 completed failure
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=held runs=2:rerun-failed" ]
  [ -f "$ST/MAIN_RED" ]
  [ "$(reruns_requested)" -eq 1 ]
  # A run already past its first attempt (a human re-ran it) is never re-run here either.
  rm -f "$ST/reruns.log"; : >"$FX/calls"
  run health --auto-rerun --classifier classify
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=held runs=2:rerun-failed" ]
  [ "$(reruns_requested)" -eq 0 ]
}

@test "RERUN-DONT-FIX is rerunnable; a needs dependency that did not succeed re-runs the whole run" {
  echo "RERUN_DONT_FIX maven central 403" >"$FX/class-2"
  echo "Error: needs.build.result is cancelled" >"$FX/log"
  red_test 1 completed failure
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=requested runs=2:full" ]
  grep -qx 'run rerun 2 --repo o/r' "$FX/calls"
  [ "$(grep -c $'run=2\t.*full-rerun-requested$' "$ST/reruns.log")" -eq 1 ]
}

@test "a full rerun refused on this head, or unverifiable, is an error and nothing is re-run" {
  echo "flake" >"$FX/class-2"
  echo "Error: needs.build.result is skipped" >"$FX/log"
  red_test 1 completed failure
  mkdir -p "$ST"
  printf '2026-11-08T01:30:00Z\trun=9\tissue=-\tat=1\thead=bbbbbbbbbbbb\tfull-rerun-requested\n' >"$ST/reruns.log"
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=error runs=2:refused" ]
  rm "$ST/reruns.log"; touch "$FX/meta-fails"
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=error runs=2:unverified" ]
  [ "$(reruns_requested)" -eq 0 ]
}

@test "investigate, unknown or no classifier: nothing is re-run and the runs are named" {
  { rest_run Test 2 1 completed failure bbbbbbbbbbbb 2026-11-08T02:00:00Z
    rest_run Lint 3 1 completed failure bbbbbbbbbbbb 2026-11-08T02:00:00Z; } | runs
  echo "rerun" >"$FX/class-2"
  echo "INVESTIGATE: timing budget" >"$FX/class-3"
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [[ "$output" == *" auto-rerun=held runs=3:investigate" ]]
  [ "$(reruns_requested)" -eq 0 ]
  : >"$FX/class-3"
  run health --auto-rerun --classifier classify
  [[ "$output" == *" auto-rerun=held runs=3:unclassified" ]]
  # No classifier at all: every run is unclassified.
  run health --auto-rerun
  [[ "$output" == *" auto-rerun=held runs="*"2:unclassified"* ]]
  [[ "$output" == *" auto-rerun=held runs="*"3:unclassified"* ]]
  [ "$(reruns_requested)" -eq 0 ]
  [ -f "$ST/MAIN_RED" ]
}

@test "without --auto-rerun nothing is classified or re-run; ORCHESTRATE_MAIN_AUTO_RERUN=1 turns it on" {
  echo "flake" >"$FX/class-2"
  red_test 1 completed failure
  ORCHESTRATE_CLASSIFIER_CMD=classify run health
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2)" ]
  [ ! -f "$FX/classified" ]
  [ "$(reruns_requested)" -eq 0 ]
  ORCHESTRATE_CLASSIFIER_CMD=classify ORCHESTRATE_MAIN_AUTO_RERUN=1 run health
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=requested runs=2:failed-jobs" ]
}

@test "a rerun GitHub refuses is an error, logged, and tried again on the next pass" {
  echo "infra" >"$FX/class-2"
  red_test 1 completed failure
  touch "$FX/rerun-fails"
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=error runs=2:failed" ]
  [ "$(grep -c $'run=2\t.*failed: HTTP 403' "$ST/reruns.log")" -eq 1 ]
  rm "$FX/rerun-fails"
  run health --auto-rerun --classifier classify
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=requested runs=2:failed-jobs" ]
  [ "$(reruns_requested)" -eq 2 ]
}

@test "doc: the merge-bot brief and SKILL.md point at --auto-rerun" {
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  grep -q -- '--auto-rerun' "$ROOT/skills/orchestrate/roles/merge-bot.md"
  grep -q -- '--auto-rerun' "$ROOT/skills/orchestrate/SKILL.md"
}
