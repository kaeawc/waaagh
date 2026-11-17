#!/usr/bin/env bats
# main-health.sh --auto-rerun (#297): a red run with an unknown or missing classifier verdict is read
# from its failed jobs' log tails; a package-mirror fetch failure (orch_mirror_sig, shared with
# failure-triage.sh) counts as rerunnable for the one-rerun rule. gh and the classifier are stubbed.
# Run: bats main-health-mirror.bats

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
  "api repos/o/r/actions/runs/2/jobs"*) echo 77 ;;
  "api repos/o/r/actions/jobs/77/logs") cat "$FX/joblog" ;;
  "api repos/o/r/actions/jobs/77"*)
    echo '{"id":77,"run_id":2,"run_attempt":1,"status":"completed","conclusion":"failure","completed_at":"2026-11-08T02:05:00Z"}' ;;
  "run view "*"--log-failed"*) echo "Run tests: failed" ;;
  "run view "*"--json"*) echo '{"headSha":"bbbbbbbbbbbb","workflowName":"Test"}' ;;
  "run rerun"*) echo ok ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  cat >"$BATS_TEST_TMPDIR/bin/classify" <<'STUB'
#!/usr/bin/env bash
echo unknown
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/classify"
  : >"$FX/calls"
}

rest_run() {
  jq -cn --argjson a "$1" --arg s "$2" --arg c "$3" \
    '{name: "Test", id: 2, run_attempt: $a, status: $s, conclusion: (if $c == "" then null else $c end),
      head_sha: "bbbbbbbbbbbb", created_at: "2026-11-08T02:00:00Z"}' | jq -s . >"$FX/runs.json"
}
health() { "$SCRIPTS/main-health.sh" --repo o/r --branch main "$@"; }
reruns_requested() { grep -c '^run rerun' "$FX/calls" || true; }

@test "unknown verdict plus an apt Failed to fetch log tail: exactly one rerun, then held" {
  printf 'step\nErr:1 http://archive.ubuntu.com jammy InRelease\nE: Failed to fetch http://archive.ubuntu.com/pool/x.deb\n' >"$FX/joblog"
  rest_run 1 completed failure
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=requested runs=2:failed-jobs" ]
  [ "$(reruns_requested)" -eq 1 ]
  rest_run 2 completed failure
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=held runs=2:rerun-failed" ]
  [ "$(reruns_requested)" -eq 1 ]
}

@test "no classifier at all: the mirror signature still earns the one rerun" {
  echo "E: Failed to fetch https://deb.debian.org/x" >"$FX/joblog"
  rest_run 1 completed failure
  run health --auto-rerun
  [ "$status" -eq 1 ]
  [[ "$output" == *"auto-rerun=requested runs=2:failed-jobs" ]]
  [ "$(reruns_requested)" -eq 1 ]
}

@test "unknown verdict and a log with no mirror signature stays held" {
  echo "assertion failed: expected 3 got 4" >"$FX/joblog"
  rest_run 1 completed failure
  run health --auto-rerun --classifier classify
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Test=failure(2) auto-rerun=held runs=2:unknown" ]
  [ "$(reruns_requested)" -eq 0 ]
}
