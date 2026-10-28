#!/usr/bin/env bats
# job-log.sh against a stubbed gh: job resolution, outcomes, and storage. Run: bats job-log.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 JOB_LOG_RETRY_SECONDS=0   # 2026-09-27T12:00:00Z
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
case "$all" in
  "api repos/o/r/actions/jobs/"*/logs)
    id=${all#api repos/o/r/actions/jobs/}; id=${id%/logs}
    mode=$(head -1 "$FX/mode-$id" 2>/dev/null || echo ok)
    # A mode file with several lines serves them in turn (for retries).
    if [ "$(wc -l <"$FX/mode-$id" 2>/dev/null || echo 0)" -gt 1 ]; then sed -i.bak 1d "$FX/mode-$id"; fi
    case "$mode" in
      ok) cat "$FX/log-$id" ;;
      empty) : ;;
      403) echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
      sig) echo "gh: AuthenticationFailed: Signature not valid in the specified time frame (HTTP 403)" >&2; exit 1 ;;
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      410) echo "gh: Gone (HTTP 410)" >&2; exit 1 ;;
      500) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
    esac ;;
  "api repos/o/r/actions/jobs/"*) cat "$FX/job-${all#api repos/o/r/actions/jobs/}.json" ;;
  "api repos/o/r/actions/runs/"*"--jq .run_attempt") echo "${RUN_ATTEMPT:-1}" ;;
  "api --paginate repos/o/r/actions/runs/"*) # pages of jobs, one JSON object per line per page
    a=${all#*attempts/}; a=${a%%/*}; cat "$FX/jobs-attempt-$a.jsonl" ;;
  "pr view"*) cat "$FX/rollup.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

job() { # id status conclusion completed_at [attempt]
  jq -n --argjson id "$1" --arg s "$2" --arg c "$3" --arg t "$4" --argjson a "${5:-1}" \
    '{id: $id, name: "test", run_id: 900, run_attempt: $a, status: $s, conclusion: (if $c == "" then null else $c end),
      completed_at: (if $t == "" then null else $t end), html_url: "https://github.com/o/r/actions/runs/900/job/\($id)",
      steps: [{number: 1, name: "checkout", status: "completed", conclusion: "success"},
              {number: 2, name: "unit tests", status: "in_progress", conclusion: null}]}' >"$FX/job-$1.json"
}
jl() { "$SCRIPTS/job-log.sh" --repo o/r "$@"; }

@test "a completed job's log is fetched job-scoped while its parent run is still running" {
  job 11 completed failure 2026-09-27T11:50:00Z
  printf 'step 1\nError: assertion failed in foo\nstep 3\n' >"$FX/log-11"
  run jl --job 11
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "available $ORCHESTRATE_STATE_DIR/o__r/logs/900/1/11.log "* ]]
  [[ "$output" == *"2:Error: assertion failed in foo"* ]]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/logs/900/1/11.log" ]
  grep -q 'api repos/o/r/actions/jobs/11/logs' "$FX/calls"
  ! grep -q 'run view' "$FX/calls"
}

@test "a running job reports its steps and URL, and fetches nothing" {
  job 12 in_progress "" ""
  run jl --job 12
  [ "$status" -eq 10 ]
  [ "${lines[0]}" = "running in_progress" ]
  [[ "$output" == *"2. unit tests: in_progress"* ]]
  [[ "$output" == *"https://github.com/o/r/actions/runs/900/job/12"* ]]
  ! grep -q '/logs' "$FX/calls"
}

@test "delayed availability: a fresh 404 or empty body is not-yet-available and nothing is saved" {
  job 13 completed failure 2026-09-27T11:58:00Z
  echo 404 >"$FX/mode-13"
  run jl --job 13
  [ "$status" -eq 11 ]
  [ "${lines[0]}" = not-yet-available ]
  [ ! -e "$ORCHESTRATE_STATE_DIR/o__r/logs/900/1/13.log" ]
  grep -q 'HTTP 404' "$ORCHESTRATE_STATE_DIR/o__r/logs/900/1/13.diag"
  echo empty >"$FX/mode-13"
  run jl --job 13
  [ "$status" -eq 11 ]
  [ ! -e "$ORCHESTRATE_STATE_DIR/o__r/logs/900/1/13.log" ]
  grep -q 'empty response body' "$ORCHESTRATE_STATE_DIR/o__r/logs/900/1/13.diag"
}

@test "403 is forbidden, 410 and an old 404 are expired, and errors never become a log" {
  job 14 completed failure 2026-09-20T00:00:00Z
  echo 403 >"$FX/mode-14"
  run jl --job 14
  [ "$status" -eq 13 ]
  [ "${lines[0]}" = forbidden ]
  echo 410 >"$FX/mode-14"
  run jl --job 14
  [ "$status" -eq 12 ]
  echo 404 >"$FX/mode-14"
  run jl --job 14
  [ "$status" -eq 12 ]
  [ "${lines[0]}" = expired ]
  [ ! -e "$ORCHESTRATE_STATE_DIR/o__r/logs/900/1/14.log" ]
  ! ls "$ORCHESTRATE_STATE_DIR/o__r/logs/900/1/" | grep -q '\.tmp$'
}

@test "an expired signed redirect or a 5xx is retried once, then reported as transient" {
  job 15 completed failure 2026-09-27T11:50:00Z
  printf 'fatal: boom\n' >"$FX/log-15"
  printf 'sig\nok\n' >"$FX/mode-15"
  run jl --job 15
  [ "$status" -eq 0 ]
  [ "$(grep -c 'jobs/15/logs' "$FX/calls")" -eq 2 ]
  printf '500\n500\n' >"$FX/mode-15"
  : >"$FX/calls"
  run jl --job 15
  [ "$status" -eq 14 ]
  [ "${lines[0]}" = transient ]
  [ "$(grep -c 'jobs/15/logs' "$FX/calls")" -eq 2 ]
}

@test "a job is resolved by name across pages of the latest attempt, and a rerun gets its own path" {
  job 21 completed failure 2026-09-27T11:00:00Z 1
  job 31 completed failure 2026-09-27T11:50:00Z 2
  printf 'error first attempt\n' >"$FX/log-21"
  printf 'error second attempt\n' >"$FX/log-31"
  # Two pages for attempt 2: the job is on the second page.
  { jq -cn '{id: 30, name: "lint"}'; jq -cn '{id: 31, name: "test"}'; } >"$FX/jobs-attempt-2.jsonl"
  jq -cn '{id: 21, name: "test"}' >"$FX/jobs-attempt-1.jsonl"
  RUN_ATTEMPT=2 run jl --run 900 --name test
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "available $ORCHESTRATE_STATE_DIR/o__r/logs/900/2/31.log "* ]]
  run jl --run 900 --attempt 1 --name test
  [[ "${lines[0]}" == "available $ORCHESTRATE_STATE_DIR/o__r/logs/900/1/21.log "* ]]
  run jl --run 900 --attempt 1 --name nope
  [ "$status" -eq 15 ]
}

@test "a job is resolved from a PR check's details URL" {
  job 41 completed failure 2026-09-27T11:50:00Z
  printf 'not ok 3 - widget\n' >"$FX/log-41"
  echo '{"statusCheckRollup":[{"name":"build","detailsUrl":"https://github.com/o/r/actions/runs/900/job/40"},
    {"name":"test","detailsUrl":"https://github.com/o/r/actions/runs/900/job/41"},
    {"context":"ext","targetUrl":"https://ci.example.com/1"}]}' >"$FX/rollup.json"
  run jl --pr 7 --check test
  [ "$status" -eq 0 ]
  [[ "$output" == *"not ok 3 - widget"* ]]
  run jl --pr 7 --check ext
  [ "$status" -eq 15 ]
  [[ "$output" == "unresolved no Actions job for check 'ext'"* ]]
}
