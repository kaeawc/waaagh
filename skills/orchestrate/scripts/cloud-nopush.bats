#!/usr/bin/env bats
# A cloud run can keep emitting events (retrying a cold dependency download) while a finished commit
# sits unpushed (#216). cloud-dispatch.sh stalled --no-push judges the saved list_runs JSON offline:
# an active run older than --nopush-minutes is "nopush", an idle end is "ended ... unpushed".
# gh must never be called. Run: bats cloud-nopush.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "unexpected gh call: $*" >&2\nexit 9\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  unset ORCHESTRATE_RUN_STALL_MINUTES ORCHESTRATE_RUN_NOPUSH_MINUTES
  RUNS="$BATS_TEST_TMPDIR/runs.json"
  cat >"$RUNS" <<'JSON'
[{"id":"old","status":"active","worker_status":"running","started_at":"2026-09-27T11:00:00Z","last_event_at":"2026-09-27T11:58:00Z"},
 {"id":"young","status":"active","worker_status":"running","created_at":"2026-09-27T11:50:00Z","last_event_at":"2026-09-27T11:59:00Z"},
 {"id":"nostart","status":"active","worker_status":"running","last_event_at":"2026-09-27T11:59:00Z"},
 {"id":"done","status":"completed","worker_status":"idle","last_event_at":"2026-09-27T11:00:00Z"}]
JSON
}
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r; }

@test "without --no-push the old output is unchanged" {
  run cd_ stalled --runs "$RUNS" --issue 9
  [ "$status" -eq 0 ]
  [ "$output" = "ended #9 run=done status=completed/idle last_event=2026-09-27T11:00:00Z" ]
}

@test "--no-push flags an active run past the minutes and marks an idle end unpushed" {
  run cd_ stalled --runs "$RUNS" --issue 9 --no-push
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "nopush #9 run=old status=active/running age=60m" ]
  [ "${lines[1]}" = "ended #9 run=done status=completed/idle last_event=2026-09-27T11:00:00Z unpushed" ]
}

@test "--nopush-minutes and ORCHESTRATE_RUN_NOPUSH_MINUTES move the line; silence still wins" {
  run cd_ stalled --runs "$RUNS" --issue 9 --no-push --nopush-minutes 5
  [ "${lines[0]}" = "nopush #9 run=old status=active/running age=60m" ]
  [ "${lines[1]}" = "nopush #9 run=young status=active/running age=10m" ]
  ORCHESTRATE_RUN_NOPUSH_MINUTES=90 run cd_ stalled --runs "$RUNS" --issue 9 --no-push
  [ "${#lines[@]}" -eq 1 ]
  run cd_ stalled --runs "$RUNS" --issue 9 --no-push --minutes 1
  [ "${lines[0]}" = "stalled #9 run=old status=active/running last_event=2026-09-27T11:58:00Z silent=2m" ]
}

@test "a bad --nopush-minutes is a usage error before any gh call" {
  run cd_ stalled --runs "$RUNS" --no-push --nopush-minutes soon
  [ "$status" -eq 2 ]
}

@test "the briefs carry the local test time budget" {
  B="$(cd "$SCRIPTS/../briefs" && pwd)"
  [ "$(grep -c 'budget of 10 minutes' "$B/implement.md")" -eq 1 ]
  [ "$(grep -c 'budget of 10 minutes' "$B/repair.md")" -eq 1 ]
}
