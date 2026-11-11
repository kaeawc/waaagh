#!/usr/bin/env bats
# triage-tick.sh rerun and a needs dependency that did not succeed on the default branch (#230):
# the failed-job log goes through failure-triage.sh needs, a hit re-runs the whole run (not
# `--failed`) once per head SHA, and --needs-only leaves any other red to a fix lane.
# Run: bats scripts/triage-tick-needs.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  stub_gh_routes
  HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  jq -n --arg h "$HEAD" '{headSha: $h, workflowName: "Test"}' >"$FX/run11.json"
  jq -n --arg h "$HEAD" '{headSha: $h, workflowName: "Test"}' >"$FX/run12.json"
  printf 'gate\tcheck\tRun test "$DETECT" = success\ngate\tcheck\terror: needs.detect.result is abandoned, expected success\n' >"$FX/abandoned.log"
  printf 'unit\ttest\tFAIL src/a.test.ts\nunit\ttest\t  expected 2, got 3\n' >"$FX/real.log"
  cp "$FX/abandoned.log" "$FX/log11"
  cp "$FX/abandoned.log" "$FX/log12"
  gh_route "run view 11 --repo o/r --json *" run11.json
  gh_route "run view 12 --repo o/r --json *" run12.json
  gh_routes <<'R'
case "$a" in
  "run view "*" --log-failed") id=${a#run view }; id=${id%% *}
    [ -s "$FX/log$id" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }; cat "$FX/log$id"; exit 0 ;;
  "run rerun"*) [ ! -f "$FX/rerun-fails" ] || { echo "HTTP 403: cannot rerun" >&2; exit 1; }; echo ok; exit 0 ;;
  "issue comment"*) echo url; exit 0 ;;
esac
R
}

tick() { "$SCRIPTS/triage-tick.sh" rerun --repo o/r "$@"; }
reruns() { grep -c '^run rerun' "$FX/calls" || true; }

@test "a main run whose failure is an abandoned needs dependency gets a full rerun, not --failed" {
  run tick --run 11 --issue 42
  [ "$status" -eq 0 ]
  [[ "$output" == "rerun requested (full): run 11 head bbbbbbbbb; needs=detect result=abandoned;"* ]]
  run grep -cx 'run rerun 11 --repo o/r' "$FX/calls"
  [ "$output" = 1 ]
  [ "$(grep -c 'run rerun 11 --failed' "$FX/calls" || true)" -eq 0 ]
  run grep -c "head=$HEAD	full-rerun-requested\$" "$ST/reruns.log"
  [ "$output" = 1 ]
  [ -f "$ST/MAIN_RED" ]
  run grep '^issue comment 42 ' "$FX/calls"
  [[ "$output" == *"every job of run 11 (needs=detect result=abandoned"* ]]
}

@test "the full rerun is once per head, even across runs, and a failed-jobs rerun does not use it up" {
  # a failed-jobs rerun of run 11 first (an older tick, before the log was read)
  printf '2026-09-27T11:00:00Z\trun=11\tissue=-\tat=1790506800\trerun-requested\n' >>"$ST/reruns.log"
  run tick --run 11
  [ "$status" -eq 0 ]
  [ "$(reruns)" -eq 1 ]
  # the dependency still does not succeed: the same head is not re-run in full again
  run tick --run 11
  [ "$status" -eq 3 ]
  [[ "$output" == "refused: head bbbbbbbbb was already re-run in full"*"runner-pool"* ]]
  run tick --run 12
  [ "$status" -eq 3 ]
  [ "$(reruns)" -eq 1 ]
}

@test "a full rerun GitHub refused does not use up the head" {
  touch "$FX/rerun-fails"
  run tick --run 11
  [ "$status" -eq 5 ]
  run grep -c 'full-failed: ' "$ST/reruns.log"
  [ "$output" = 1 ]
  rm "$FX/rerun-fails"
  run tick --run 11
  [ "$status" -eq 0 ]
  [ "$(reruns)" -eq 2 ]
  run tick --run 11
  [ "$status" -eq 3 ]
}

@test "the snapshot holds merges while a full rerun is pending" {
  run tick --run 11
  [ "$status" -eq 0 ]
  rm -f "$ST/MAIN_RED"
  echo '[]' >"$FX/empty.json"
  echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-09-27T01:00:00Z"}]}' >"$FX/green.json"
  echo '{"status":"in_progress"}' >"$FX/run11.json"
  gh_route "api repos/o/r/actions/runs?*" green.json
  gh_route "pr list*" empty.json
  gh_route "issue list*" empty.json
  gh_route "api graphql*" empty.json
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [[ "$output" == *"main held rerun-pending runs=11"* ]]
  [ -f "$ST/MAIN_RED" ]
}

@test "--log FILE is read instead of GitHub; a real failure takes the failed-jobs path" {
  rm "$FX/log11"
  run tick --run 11 --log "$FX/real.log"
  [ "$status" -eq 0 ]
  [ "$output" = "rerun requested: run 11; merges held until main is green" ]
  run grep -cx 'run rerun 11 --failed --repo o/r' "$FX/calls"
  [ "$output" = 1 ]
  [ "$(grep -c -- '--log-failed' "$FX/calls" || true)" -eq 0 ]
  run tick --run 12 --log "$FX/abandoned.log"
  [ "$status" -eq 0 ]
  run grep -cx 'run rerun 12 --repo o/r' "$FX/calls"
  [ "$output" = 1 ]
  run tick --run 11 --log "$BATS_TEST_TMPDIR/missing.log"
  [ "$status" -eq 2 ]
}

@test "--needs-only re-runs only the needs case; an unread log or head changes nothing" {
  cp "$FX/real.log" "$FX/log11"
  run tick --run 11 --needs-only
  [ "$status" -eq 1 ]
  [[ "$output" == "none: run 11's failed-job log shows no needs dependency"* ]]
  rm "$FX/log11"
  run tick --run 11 --needs-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be read"* ]]
  [ "$(reruns)" -eq 0 ]
  [ ! -f "$ST/MAIN_RED" ]
  # head unreadable: no full rerun on a guess
  echo '{}' >"$FX/run12.json"
  run tick --run 12 --needs-only
  [ "$status" -eq 9 ]
  [[ "$output" == "unverified: run 12 needs a full rerun (needs=detect result=abandoned)"* ]]
  [ "$(reruns)" -eq 0 ]
}

@test "a recorded needs-dependency signature for the workflow counts too; failure-triage.sh needs alone" {
  printf 'gate\tcheck\ttest abandoned = success\n' >"$FX/log11"
  "$SCRIPTS/failure-triage.sh" record --repo o/r --check 'Te*' --pattern 'abandoned = success' --note 'needs-dependency: detect'
  run "$SCRIPTS/failure-triage.sh" needs --repo o/r --check Test --log "$FX/log11"
  [ "$status" -eq 0 ]
  [ "$output" = "needs ? ?" ]
  run "$SCRIPTS/failure-triage.sh" needs --repo o/r --check Lint --log "$FX/log11"
  [ "$status" -eq 1 ]
  [ "$output" = none ]
  run "$SCRIPTS/failure-triage.sh" needs --repo o/r --check Test
  [ "$status" -eq 2 ]
  run tick --run 11
  [ "$status" -eq 0 ]
  run grep -cx 'run rerun 11 --repo o/r' "$FX/calls"
  [ "$output" = 1 ]
  # --check overrides the workflow name
  cp "$FX/log11" "$FX/log12"
  run tick --run 12 --check Lint
  [ "$status" -eq 0 ]
  run grep -cx 'run rerun 12 --failed --repo o/r' "$FX/calls"
  [ "$output" = 1 ]
}

@test "the doctrine names the main-branch full rerun (#230)" {
  run grep -c 'needs-only' "$SCRIPTS/../roles/triage-tick.md"
  [ "$output" -ge 1 ]
  run grep -c 'triage-tick.sh rerun' "$SCRIPTS/../failure-triage.md"
  [ "$output" -ge 1 ]
}
