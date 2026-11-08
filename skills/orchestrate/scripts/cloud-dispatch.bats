#!/usr/bin/env bats
# cloud-dispatch.sh (queue, ledger, brief, payload, pacing) and the cloud-dispatch doctrine
# contract. No gh call is made: every test passes --repo and --base. Run: bats cloud-dispatch.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Any gh call is a test failure.
  printf '#!/usr/bin/env bash\necho "unexpected gh call: $*" >&2; exit 9\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  ST="$ORCHESTRATE_STATE_DIR/o__r"
}
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r; }
has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "queue add dedupes, and next/list skip dispatched issues" {
  run cd_ queue add 5 '#7' 5 9
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'queued 5\nqueued 7\nqueued 9')" ]
  run cd_ record --issue 5 --trigger trig_a --run-at 2026-09-27T12:01:00Z
  [ "$status" -eq 0 ]
  run cd_ next --count 5
  [ "$output" = "$(printf '7\n9')" ]
  run cd_ next
  [ "$output" = "7" ]
  run cd_ queue add 5
  [ "$output" = "" ]
  run cd_ queue list
  [ "$output" = "$(printf '7\n9')" ]
}

@test "the queue and ledger survive in the state dir (compaction-proof)" {
  cd_ queue add 3 4
  cd_ record --issue 3 --trigger trig_x --run-at 2026-09-27T12:01:00Z
  [ "$(cat "$ST/cloud-queue.txt")" = "$(printf '3\n4')" ]
  [ "$(cat "$ST/cloud-sessions.tsv")" = "$(printf '3\ttrig_x\t2026-09-27T12:01:00Z\t2026-09-27T12:00:00Z')" ]
}

@test "record refuses a second dispatch of one issue and a non-ISO run time" {
  cd_ record --issue 3 --trigger trig_x --run-at 2026-09-27T12:01:00Z
  run cd_ record --issue 3 --trigger trig_y --run-at 2026-09-27T12:02:00Z
  [ "$status" -eq 3 ]
  run cd_ record --issue 4 --trigger trig_y --run-at tomorrow
  [ "$status" -eq 2 ]
  [ "$(wc -l <"$ST/cloud-sessions.tsv" | tr -d ' ')" = 1 ]
}

@test "brief fills the template and stays short" {
  run cd_ brief --issue 42 --base trunk --gates "make test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"o/r issue #42"* ]]
  [[ "$output" == *'work/42-auto'* ]]
  [[ "$output" == *'origin/trunk'* ]]
  [[ "$output" == *'Gates, all passing before you push: make test.'* ]]
  [[ "$output" == *'Closes #42'* && "$output" == *'Part of #42'* ]]
  [[ "$output" == *'Do not merge.'* ]]
  [[ "$output" != *'{{'* ]]
  [ "${#output}" -lt 1500 ]
}

@test "a state-dir cloud-brief.md overrides the template; gates text with specials is literal" {
  mkdir -p "$ST"
  printf 'Fix {{REPO}}#{{ISSUE}} on {{BASE}}: {{GATES}}\n' >"$ST/cloud-brief.md"
  run cd_ brief --issue 8 --base main --gates 'a & b \1 | c'
  [ "$output" = 'Fix o/r#8 on main: a & b \1 | c' ]
}

@test "payload builds the RemoteTrigger create object with a staggered run_once_at" {
  run cd_ payload --issue 5 --env env_1 --source https://github.com/o/r --model claude-x --base main
  [ "$status" -eq 0 ]
  jq -e '.run_once_at == "2026-09-27T12:01:00Z"
    and .job_config.ccr.environment_id == "env_1"
    and .job_config.ccr.session_context.sources == [{git_repository: {url: "https://github.com/o/r"}}]
    and .job_config.ccr.session_context.model == "claude-x"
    and (.job_config.ccr.events[0].data.message | contains("issue #5"))' <<<"$output"
  cd_ record --issue 5 --trigger trig_a --run-at 2026-09-27T12:01:00Z
  # The next run is staggered 20 s after the latest recorded run, not at now+60 again.
  run cd_ payload --issue 6 --env env_1 --source '{"repo":"o/r"}' --base main
  jq -e '.run_once_at == "2026-09-27T12:01:20Z"
    and .job_config.ccr.session_context == {sources: [{repo: "o/r"}]}' <<<"$output"
  run cd_ payload --issue 6 --env env_1 --source u --base main --at 1790510700
  jq -e '.run_once_at == "2026-09-27T12:05:00Z"' <<<"$output"
}

@test "payload refuses an issue already dispatched and requires env and source" {
  cd_ record --issue 5 --trigger trig_a --run-at 2026-09-27T12:01:00Z
  run cd_ payload --issue 5 --env e --source u --base main
  [ "$status" -eq 3 ]
  [[ "$output" == *"trig_a"* ]]
  run cd_ payload --issue 6 --base main
  [ "$status" -eq 2 ]
}

@test "pace holds creates at the per-minute cap and during a 429 backoff" {
  run cd_ pace
  [ "$output" = "wait 0" ]
  mkdir -p "$ST"
  printf '1\tt1\t2026-09-27T12:01:00Z\t2026-09-27T11:59:10Z\n2\tt2\t2026-09-27T12:01:20Z\t2026-09-27T11:59:30Z\n3\tt3\t2026-09-27T12:01:40Z\t2026-09-27T11:59:50Z\n' >"$ST/cloud-sessions.tsv"
  run cd_ pace --per-minute 5
  [ "$output" = "wait 0" ]
  # Three creates in the last minute against a cap of 3: wait for the oldest to age out (10 s).
  run cd_ pace --per-minute 3
  [ "$output" = "wait 10" ]
  run cd_ backoff --message "HTTP 429: Too many requests. Try again in 33s"
  [ "$output" = "backoff until 2026-09-27T12:00:33Z" ]
  run cd_ pace --per-minute 5
  [ "$output" = "wait 33" ]
  run cd_ backoff
  [ "$output" = "backoff until 2026-09-27T12:00:20Z" ]
  run cd_ status
  [ "$output" = "$(printf 'queued 0\ndispatched 3\nlast #3 t3 2026-09-27T12:01:40Z\nbackoff 20')" ]
}

@test "usage errors and -h cover exactly the header" {
  run cd_ bogus
  [ "$status" -eq 2 ]
  run cd_ queue add
  [ "$status" -eq 2 ]
  run cd_ brief --base main
  [ "$status" -eq 2 ]
  run "$SCRIPTS/cloud-dispatch.sh" -h
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "# Cloud dispatch bookkeeping"* ]]
  [[ "${lines[${#lines[@]}-1]}" == "# Exit: 0 ok"* ]]
}

@test "cloud dispatch doctrine: role, ledger, pacing, cloud/local split, results via PRs (#61)" {
  R="$ROOT/skills/orchestrate/roles/cloud-dispatch.md"
  has "$R" "Only the main session can dispatch"
  has "$R" "cloud-sessions.tsv"
  has "$R" "fires it twice"
  has "$R" "batches of 3 to 5"
  has "$R" "429"
  has "$R" "Runs in the cloud"
  has "$R" "Stays local"
  has "$R" "Cloud sessions cannot message the orchestrator"
  has "$R" "cannot delete"
  has "$ROOT/skills/orchestrate/roles/README.md" "cloud-dispatch.md"
  has "$ROOT/skills/orchestrate/SKILL.md" "roles/cloud-dispatch.md"
  has "$ROOT/README.md" "cloud-dispatch.sh"
}
