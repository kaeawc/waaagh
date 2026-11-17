#!/usr/bin/env bats
# Stalled cloud runs (#260): a routine run can stop producing events while it still reports
# running, stop on a permission prompt, end with no PR, or never start. cloud-dispatch.sh stalled
# judges the JSON the main session saved from RemoteTrigger list_runs, offline; payload and brief
# take --branch and --note for the redispatch. gh must never be called. Run: bats cloud-stalled.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "unexpected gh call: $*" >&2\nexit 9\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  unset ORCHESTRATE_RUN_STALL_MINUTES ORCHESTRATE_RUN_UNFIRED_MINUTES
  RUNS="$BATS_TEST_TMPDIR/runs.json"
}
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r; }
record() { cd_ record --issue "$1" --trigger "trig_$1" --run-at "$2" >/dev/null; }
has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "a running run silent past the minutes is stalled; one still producing events is quiet" {
  record 5 2026-09-27T09:00:00Z
  cat >"$RUNS" <<'JSON'
[{"id":"run_a","trigger_id":"trig_5","status":"active","worker_status":"running","last_event_at":"2026-09-27T09:56:12.345678Z"},
 {"id":"run_b","trigger_id":"trig_5","status":"active","worker_status":"running","last_event_at":"2026-09-27T11:40:00+00:00"}]
JSON
  run cd_ stalled --runs "$RUNS"
  [ "$status" -eq 0 ]
  [ "$output" = "stalled #5 run=run_a status=active/running last_event=2026-09-27T09:56:12Z silent=123m" ]
  # --minutes moves the line; ORCHESTRATE_RUN_STALL_MINUTES is the default
  run cd_ stalled --runs "$RUNS" --minutes 15
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "stalled #5 run=run_b status=active/running last_event=2026-09-27T11:40:00Z silent=20m" ]
  ORCHESTRATE_RUN_STALL_MINUTES=200 run cd_ stalled --runs "$RUNS"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "requires_action is blocked, an idle end is ended, and the issue comes from --issue or the ledger" {
  record 7 2026-09-27T09:00:00Z
  cat >"$RUNS" <<'JSON'
{"runs":[{"run_id":"r1","worker_status":"requires_action","status":"active","last_event_at":"2026-09-27T11:59:00Z"},
 {"session_id":"r2","trigger_id":"trig_7","status":"active","worker_status":"idle","last_event_at":"2026-09-27T10:00:00Z"},
 {"id":"r3","status":"completed"}]}
JSON
  run cd_ stalled --runs "$RUNS"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "blocked #? run=r1 status=active/requires_action" ]
  [ "${lines[1]}" = "ended #7 run=r2 status=active/idle last_event=2026-09-27T10:00:00Z" ]
  [ "${lines[2]}" = "ended #? run=r3 status=completed/- last_event=-" ]
  run cd_ stalled --runs "$RUNS" --issue 9
  [ "${lines[0]}" = "blocked #9 run=r1 status=active/requires_action" ]
}

@test "fields nest under session, times may be epochs, and an unjudgeable run is unknown (exit 7)" {
  cat >"$RUNS" <<'JSON'
{"data":[{"id":"r1","session":{"status":"running","last_event_at":1790503200000}},
 {"id":"r2","status":"running"},
 {"id":"r3","status":"weird"},
 "not a run"]}
JSON
  run cd_ stalled --runs "$RUNS" --issue 4
  [ "$status" -eq 7 ]
  [ "${lines[0]}" = "stalled #4 run=r1 status=running/- last_event=2026-09-27T10:00:00Z silent=120m" ]
  [ "${lines[1]}" = "unknown #4 run=r2 no last_event_at" ]
  [ "${lines[2]}" = "unknown #4 run=r3 status weird/-" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "no runs: unfired past the grace after run_at, quiet before it, unknown without a live dispatch" {
  record 5 2026-09-27T11:30:00Z
  record 6 2026-09-27T11:50:00Z
  echo '[]' >"$RUNS"
  run cd_ stalled --runs "$RUNS" --issue 5
  [ "$status" -eq 0 ]
  [ "$output" = "unfired #5 trigger=trig_5 run_at=2026-09-27T11:30:00Z late=30m" ]
  run cd_ stalled --runs "$RUNS" --issue 6
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  ORCHESTRATE_RUN_UNFIRED_MINUTES=5 run cd_ stalled --runs "$RUNS" --issue 6
  [ "$output" = "unfired #6 trigger=trig_6 run_at=2026-09-27T11:50:00Z late=10m" ]
  echo '{"runs":[]}' >"$RUNS"
  run cd_ stalled --runs "$RUNS"
  [ "$status" -eq 7 ]
  [[ "$output" == "unknown #? no runs"* ]]
  run cd_ stalled --runs "$RUNS" --issue 8
  [ "$status" -eq 7 ]
  printf '8\ttrig_8\tsoon\t2026-09-27T11:00:00Z\n' >>"$ORCHESTRATE_STATE_DIR/o__r/cloud-sessions.tsv"
  run cd_ stalled --runs "$RUNS" --issue 8
  [ "$status" -eq 7 ]
  [ "$output" = "unknown #8 no runs, unreadable run_at soon" ]
}

@test "a missing --runs is usage (exit 2); a file that is not runs JSON is exit 7" {
  run cd_ stalled
  [ "$status" -eq 2 ]
  run cd_ stalled --runs "$RUNS" --minutes x
  [ "$status" -eq 2 ]
  run cd_ stalled --runs "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 7 ]
  echo 'not json' >"$RUNS"
  run cd_ stalled --runs "$RUNS"
  [ "$status" -eq 7 ]
  echo '{"other":1}' >"$RUNS"
  run cd_ stalled --runs "$RUNS"
  [ "$status" -eq 7 ]
  [[ "$output" == *"is not list_runs JSON"* ]]
}

@test "a redispatch names a new branch and carries what the stalled run learned" {
  run cd_ brief --issue 5 --brief-ref implement --branch work/5-auto-2 --note "the target file is at its size cap; start from a separate module."
  [ "$status" -eq 0 ]
  [ "$output" = "Follow .claude/briefs/implement.md for issue #5 (branch work/5-auto-2). Note from an earlier run: the target file is at its size cap; start from a separate module." ]
  run cd_ brief --issue 5 --brief-ref implement
  [ "$output" = "Follow .claude/briefs/implement.md for issue #5 (branch work/5-auto)." ]
  run cd_ brief --issue 5 --base main --gates "make test" --branch work/5-auto-2 --note "use module B & C"
  [ "$status" -eq 0 ]
  [[ "$output" == *"work/5-auto-2"* ]]
  [ "$(grep -cE 'work/5-auto($|[^-])' <<<"$output" || true)" -eq 0 ]
  [[ "$output" == *"Note from an earlier run: use module B & C" ]]
  run cd_ brief --issue 5 --brief-ref implement --branch "a b"
  [ "$status" -eq 2 ]
}

@test "doctrine: cloud-dispatch.md and the tick name stalled runs and how to redispatch them" {
  R="$SCRIPTS/../roles"
  has "$R/cloud-dispatch.md" "cloud-dispatch.sh stalled --runs"
  has "$R/cloud-dispatch.md" "list_runs"
  has "$R/cloud-dispatch.md" "get_run_log"
  has "$R/cloud-dispatch.md" "--branch"
  has "$R/cloud-dispatch.md" "needs-decision"
  has "$R/cloud-dispatch.md" "requires_action"
  has "$R/triage-tick.md" "cloud-dispatch.sh stalled"
  has "$SCRIPTS/cloud-dispatch.sh" "ORCHESTRATE_RUN_STALL_MINUTES"
}
