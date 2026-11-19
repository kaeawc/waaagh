#!/usr/bin/env bats
# ci-backlog.sh (#315): the Actions backlog is sized from the queued and in-progress JOBS of runs
# created inside a window, never from a run listing, which returns ghosts (runs listed as queued
# that completed weeks ago). The runs and jobs endpoints are stubbed. Run: bats ci-backlog.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1795089600 GH_READ_JITTER=0 GH_READ_FAKE_SLEEP=1   # 2026-11-19T12:00:00Z
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r/actions/runs?"*) cat "$FX/runs.json" ;;
  "api repos/o/r/actions/runs/"*"/jobs?"*)
    id=${2#repos/o/r/actions/runs/}; id=${id%%/*}
    if [[ -f "$FX/jobs-$id.json" ]]; then cat "$FX/jobs-$id.json"; else echo "no fixture for run $id" >&2; exit 1; fi ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# run_ ID STATUS CREATED_AT: one REST workflow run.
run_() { jq -cn --argjson id "$1" --arg s "$2" --arg t "$3" '{id: $id, name: "CI", status: $s, created_at: $t}'; }
runs() { jq -s '{total_count: length, workflow_runs: .}' >"$FX/runs.json"; }
# jobs ID STATUS:LABELS...: the jobs of run ID (LABELS comma-separated, empty for none).
jobs() {
  local id=$1 j; shift
  for j in "$@"; do
    jq -cn --arg s "${j%%:*}" --arg l "${j#*:}" '{status: $s, labels: ($l | split(",") | map(select(. != "")))}'
  done | jq -s '{total_count: length, jobs: .}' >"$FX/jobs-$id.json"
}
backlog() { "$SCRIPTS/ci-backlog.sh" --repo o/r "$@"; }
calls() { grep -c -- "$1" "$FX/calls" || true; }

@test "jobs are counted by label; a run listed as queued whose jobs are done is a ghost" {
  { run_ 5 queued 2026-11-19T11:50:00Z        # top-level queued, yet its jobs are on runners
    run_ 4 in_progress 2026-11-19T11:00:00Z
    run_ 3 queued 2026-11-19T10:00:00Z        # a ghost: listed as queued, every job completed
    run_ 2 completed 2026-11-19T09:00:00Z; } | runs
  jobs 5 in_progress:ubuntu-latest in_progress:ubuntu-latest queued:macos-15 queued:macos-15 queued:macos-15
  jobs 4 in_progress:self-hosted,macOS,ARM64 queued:ubuntu-latest completed:ubuntu-latest queued:
  jobs 3 completed:ubuntu-latest completed:macos-15
  run backlog
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "jobs"$'\t'"macos-15"$'\t'"3"$'\t'"0" ]
  [ "${lines[1]}" = "jobs"$'\t'"ubuntu-latest"$'\t'"1"$'\t'"2" ]
  [ "${lines[2]}" = "jobs"$'\t'"-"$'\t'"1"$'\t'"0" ]
  [ "${lines[3]}" = "jobs"$'\t'"self-hosted,macOS,ARM64"$'\t'"0"$'\t'"1" ]
  [ "${lines[4]}" = "total"$'\t'"queued=5"$'\t'"in_progress=3"$'\t'"runs=2"$'\t'"ghost=1"$'\t'"unread=0"$'\t'"truncated=no" ]
  # One list request filtered by created time, one jobs request per run not completed, no `run list`.
  [ "$(calls '^api repos/o/r/actions/runs?created=%3E%3D2026-11-19T06:00:00Z&per_page=100')" -eq 1 ]
  [ "$(calls '/jobs?filter=latest')" -eq 3 ]
  [ "$(calls '^run list')" -eq 0 ]
  [ ! -e "$FX/jobs-2.json" ]
}

@test "a run older than the window is not sized, even when the server returns it" {
  { run_ 9 queued 2026-11-19T11:30:00Z
    run_ 1 queued 2026-10-01T08:00:00Z; } | runs
  jobs 9 queued:ubuntu-latest
  run backlog --window 60
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "total"$'\t'"queued=1"$'\t'"in_progress=0"$'\t'"runs=1"$'\t'"ghost=0"$'\t'"unread=0"$'\t'"truncated=no" ]
  [ "$(calls 'created=%3E%3D2026-11-19T11:00:00Z')" -eq 1 ]
  [ "$(calls 'runs/1/jobs')" -eq 0 ]
}

@test "nothing running prints the summary alone; --max-runs bounds the requests, newest first" {
  run_ 2 completed 2026-11-19T09:00:00Z | runs
  run backlog
  [ "$status" -eq 0 ]
  [ "$output" = "total"$'\t'"queued=0"$'\t'"in_progress=0"$'\t'"runs=0"$'\t'"ghost=0"$'\t'"unread=0"$'\t'"truncated=no" ]
  { run_ 6 queued 2026-11-19T11:00:00Z; run_ 7 queued 2026-11-19T11:30:00Z; run_ 8 queued 2026-11-19T11:40:00Z; } | runs
  jobs 8 queued:ubuntu-latest
  run backlog --max-runs 1
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "total"$'\t'"queued=1"$'\t'"in_progress=0"$'\t'"runs=1"$'\t'"ghost=0"$'\t'"unread=2"$'\t'"truncated=no" ]
  [ "$(calls 'runs/8/jobs')" -eq 1 ]
  [ "$(calls 'runs/7/jobs')" -eq 0 ]
}

@test "a full page of runs is reported as truncated" {
  jq -n '[range(0; 100) | {id: (. + 1), name: "CI", status: "completed", created_at: "2026-11-19T11:00:00Z"}]
    | {total_count: 400, workflow_runs: .}' >"$FX/runs.json"
  run backlog
  [ "$status" -eq 0 ]
  [[ "$output" == *"truncated=yes" ]]
}

@test "an unreadable run list or jobs list is exit 3, never a zero backlog" {
  echo 'not json' >"$FX/runs.json"
  run backlog
  [ "$status" -eq 3 ]
  [[ "$output" == "unreadable run list"* ]]
  echo '{"message":"Not Found"}' >"$FX/runs.json"
  run backlog
  [ "$status" -eq 3 ]
  run_ 4 in_progress 2026-11-19T11:00:00Z | runs
  run backlog
  [ "$status" -eq 3 ]
  [[ "$output" == *"unreadable jobs of run 4"* ]]
  echo '{"jobs":"nope"}' >"$FX/jobs-4.json"
  run backlog
  [ "$status" -eq 3 ]
}

@test "usage: bad numbers are refused before any request; the docs name the script" {
  run backlog --window 0
  [ "$status" -eq 2 ]
  run backlog --max-runs many
  [ "$status" -eq 2 ]
  [ ! -e "$FX/calls" ]
  grep -qF 'ci-backlog.sh' "$ROOT/README.md"
  grep -qF 'ci-backlog.sh' "$ROOT/skills/orchestrate/SKILL.md"
  grep -qx 'orch_gh_priority low' "$SCRIPTS/ci-backlog.sh"
}
