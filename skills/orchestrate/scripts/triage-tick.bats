#!/usr/bin/env bats
# triage-tick.sh against a stubbed gh: the one-call snapshot, flake reruns, merge-loop heartbeat,
# cron expiry, and the doctrine that goes with them. Run: bats triage-tick.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "run list"*) cat "$FX/runs.json" ;;
  "run view "*) a="$*"; id=${a#run view }; id=${id%% *}; cat "$FX/run-$id.json" ;;
  "pr list"*) [ -f "$FX/prs-fail" ] && { echo "HTTP 404: Not Found" >&2; exit 1; }; cat "$FX/prs.json" ;;
  "issue list"*) cat "$FX/issues.json" ;;
  "api graphql"*) echo '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
  "run rerun"*) [ -f "$FX/rerun-fails" ] && { echo "HTTP 403: cannot rerun" >&2; exit 1; }; echo ok ;;
  "issue comment"*) [ -f "$FX/comment-fails" ] && { echo "HTTP 403" >&2; exit 1; }; echo url ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  cat >"$BATS_TEST_TMPDIR/bin/classify" <<'STUB'
#!/usr/bin/env bash
# classify --repo R --run ID -> the verdict written for that run id
cat "$FX/class-$4"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/classify"
  green_runs
  echo '[{"number":70,"closingIssuesReferences":[{"number":5}]},{"number":71,"closingIssuesReferences":[]}]' >"$FX/prs.json"
  echo '[{"number":5,"labels":[]},{"number":6,"labels":[{"name":"cloud-ready"}]},{"number":7,"labels":[{"name":"blocked"}]},{"number":8,"labels":[]},{"number":9,"labels":[{"name":"cloud-ready"}]}]' >"$FX/issues.json"
}

green_runs() {
  echo '[{"workflowName":"Test","status":"completed","conclusion":"success","headSha":"aaaaaaaaaaaa","databaseId":10,"createdAt":"2026-09-27T01:00:00Z"}]' >"$FX/runs.json"
}
red_runs() { # newest Test run 11 failed
  echo '[{"workflowName":"Test","status":"completed","conclusion":"success","headSha":"aaaaaaaaaaaa","databaseId":10,"createdAt":"2026-09-27T01:00:00Z"},
         {"workflowName":"Test","status":"completed","conclusion":"failure","headSha":"bbbbbbbbbbbb","databaseId":11,"createdAt":"2026-09-27T02:00:00Z"}]' >"$FX/runs.json"
}
snap() { "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main "$@"; }

@test "a quiet campaign is one ok verdict with every part present" {
  echo "beat=$((ORCHESTRATE_NOW - 60)) deadline=$((ORCHESTRATE_NOW + 3600)) pid=0" >"$ST/merge-loop.beat"
  printf '2026-09-25T10:00:00Z\tpr=50\thead=abc\tmerged x\n2026-09-27T10:00:00Z\tpr=60\thead=abc\tmerged deadbeef method=squash admin=no\n2026-09-27T11:00:00Z\tpr=61\thead=abc\trefused not ready\n' >"$ST/merges.log"
  printf 'wt1\tb1\t6,8\tsrc/\tandroid:codex\tactive\nwt2\tb2\t9\tios/\tios:codex\tactive\n' >"$ST/lanes.tsv"
  run snap --device-slots android=1,ios=2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "verdict ok" ]
  [ "${lines[1]}" = "main green aaaaaaaaa Test@aaaaaaaaa" ]
  [ "${lines[2]}" = "prs open=2" ]
  [[ "${lines[3]}" == "merge_loop alive beat_age=60 deadline=2026-09-27T13:00:00Z last_merge=2026-09-27T10:00:00Z pr=60 merges_24h=1" ]]
  [ "${lines[4]}" = "dispatch 0 next=-" ]
  [ "${lines[5]}" = "slots android=1/1,ios=1/2" ]
  [ "${lines[6]}" = "cron none" ]
  [ "${#lines[@]}" -eq 8 ]
  [ "${lines[7]}" = "threads unresolved=0 answered=0 resolve-now=- repair=-" ]
}

@test "the dispatch queue skips issues in an open PR, in an active lane, or excluded" {
  printf 'wt1\tb1\t8\tsrc/\tcodex\tactive\nwt2\tb2\t9\tx/\tcodex\tmerged\n' >"$ST/lanes.tsv"
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  run snap
  [ "${lines[0]}" = "verdict act dispatch=2" ]
  [[ "$output" == *$'\n'"dispatch 2 next=#6,#9"$'\n'* ]]
  run snap --ready-label cloud-ready
  [[ "$output" == *$'\n'"dispatch 2 next=#6,#9"$'\n'* ]]
  # every device slot taken: the queue is reported but no dispatch is asked for
  run snap --device-slots android=0
  [ "${lines[0]}" = "verdict ok" ]
  [[ "$output" == *"slots android=0/0"* ]]
}

@test "a merge loop that ended, expired, went stale or died is flagged while PRs are open" {
  echo '[]' >"$FX/issues.json"
  run snap
  [ "${lines[0]}" = "verdict act merge-loop-absent" ]
  echo "beat=$((ORCHESTRATE_NOW - 60)) deadline=$((ORCHESTRATE_NOW - 1)) pid=0" >"$ST/merge-loop.beat"
  run snap
  [ "${lines[0]}" = "verdict act merge-loop-expired" ]
  echo "beat=$((ORCHESTRATE_NOW - 4000)) deadline=$((ORCHESTRATE_NOW + 9000)) pid=0" >"$ST/merge-loop.beat"
  run snap
  [ "${lines[0]}" = "verdict act merge-loop-stale" ]
  run snap --loop-stale 5000
  [ "${lines[0]}" = "verdict ok" ]
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=999999" >"$ST/merge-loop.beat"
  run snap
  [ "${lines[0]}" = "verdict act merge-loop-dead" ]
  run "$SCRIPTS/triage-tick.sh" beat --repo o/r --end bound
  [ "$status" -eq 0 ]
  run snap
  [ "${lines[0]}" = "verdict act merge-loop-ended" ]
  [[ "${lines[3]}" == "merge_loop ended:bound beat_age=0 "* ]]
  # no open PRs: an idle merge loop is not a problem
  echo '[]' >"$FX/prs.json"
  run snap
  [ "${lines[0]}" = "verdict ok" ]
}

@test "beat writes the heartbeat the snapshot reads" {
  run "$SCRIPTS/triage-tick.sh" beat --repo o/r --deadline $((ORCHESTRATE_NOW + 28800)) --pid $$
  [ "$status" -eq 0 ]
  [ "$(cat "$ST/merge-loop.beat")" = "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 28800)) pid=$$" ]
  echo '[]' >"$FX/issues.json"
  run snap
  [ "${lines[0]}" = "verdict ok" ]
  [[ "${lines[3]}" == "merge_loop alive beat_age=0 deadline=2026-09-27T20:00:00Z"* ]]
  run "$SCRIPTS/triage-tick.sh" beat --repo o/r
  [ "$status" -eq 2 ]
}

@test "red main with a classified known flake asks for a rerun; anything else asks for a fix lane" {
  red_runs; echo '[]' >"$FX/issues.json"
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  echo "flake: known BATS timing flake" >"$FX/class-11"
  run snap --classifier classify
  [ "${lines[0]}" = "verdict act flake-rerun" ]
  [ "${lines[1]}" = "main red bbbbbbbbb runs=11:flake action=rerun" ]
  [ -f "$ST/MAIN_RED" ]
  echo "INVESTIGATE new failure" >"$FX/class-11"
  run snap --classifier classify
  [ "${lines[0]}" = "verdict act main-red" ]
  [ "${lines[1]}" = "main red bbbbbbbbb runs=11:investigate action=fix-lane" ]
  # no classifier configured: never assumed to be a flake
  run snap
  [ "${lines[1]}" = "main red bbbbbbbbb runs=11:unclassified action=fix-lane" ]
}

@test "rerun re-runs once, notes the tracking issue and holds merges until green" {
  red_runs; echo '[]' >"$FX/issues.json"
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  run "$SCRIPTS/triage-tick.sh" rerun --repo o/r --run 11 --issue 42
  [ "$status" -eq 0 ]
  grep -qx 'run rerun 11 --failed --repo o/r' "$FX/calls"
  grep -q '^issue comment 42 --repo o/r --body .*run 11' "$FX/calls"
  [ -f "$ST/MAIN_RED" ]
  grep -q 'run=11.*rerun-requested' "$ST/reruns.log"
  # never twice
  run "$SCRIPTS/triage-tick.sh" rerun --repo o/r --run 11
  [ "$status" -eq 3 ]
  [ "$(grep -c '^run rerun' "$FX/calls")" -eq 1 ]
  # the rerun is running: main-health judges the older green run, the hold stays
  green_runs; rm -f "$ST/MAIN_RED"
  echo '{"status":"in_progress"}' >"$FX/run-11.json"
  run snap
  [ "${lines[0]}" = "verdict act rerun-pending" ]
  [ "${lines[1]}" = "main held rerun-pending runs=11" ]
  [ -f "$ST/MAIN_RED" ]
  # rerun green: the hold clears
  echo '{"status":"completed"}' >"$FX/run-11.json"
  run snap
  [ "${lines[0]}" = "verdict ok" ]
  [ ! -f "$ST/MAIN_RED" ]
  # rerun failed again: a real red, not a second rerun
  red_runs
  echo "flake" >"$FX/class-11"
  run snap --classifier classify
  [ "${lines[1]}" = "main red bbbbbbbbb runs=11:rerun-failed action=fix-lane" ]
}

@test "a refused rerun is logged and can be tried again; a failed note is its own exit" {
  touch "$FX/rerun-fails"
  run "$SCRIPTS/triage-tick.sh" rerun --repo o/r --run 11 --issue 42
  [ "$status" -eq 5 ]
  [ ! -f "$ST/MAIN_RED" ]
  ! grep -q 'issue comment' "$FX/calls"
  rm "$FX/rerun-fails"; touch "$FX/comment-fails"
  run "$SCRIPTS/triage-tick.sh" rerun --repo o/r --run 11 --issue 42
  [ "$status" -eq 6 ]
  [ -f "$ST/MAIN_RED" ]
  run "$SCRIPTS/triage-tick.sh" rerun --repo o/r
  [ "$status" -eq 2 ]
}

@test "unreadable parts say unknown, never a guess" {
  touch "$FX/prs-fail"
  echo '[]' >"$FX/runs.json"
  run snap
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "verdict act main-unknown" ]
  [[ "${lines[1]}" == "main unknown no completed run"* ]]
  [ "${lines[2]}" = "prs open=unknown" ]
  [ "${lines[4]}" = "dispatch unknown next=-" ]
}

@test "cron records its creation and warns in the last day of its 7-day life" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  echo '[]' >"$FX/issues.json"
  run "$SCRIPTS/triage-tick.sh" cron --repo o/r --created $((ORCHESTRATE_NOW - 2 * 86400))
  [ "$status" -eq 0 ]
  run snap
  [ "${lines[0]}" = "verdict ok" ]
  [ "${lines[6]}" = "cron age=48h expires_in=120h" ]
  run "$SCRIPTS/triage-tick.sh" cron --repo o/r --created $((ORCHESTRATE_NOW - 6 * 86400 - 3600))
  run snap
  [ "${lines[0]}" = "verdict act cron-expiring" ]
  [ "${lines[6]}" = "cron age=145h expires_in=23h" ]
}

@test "the header is the -h text exactly" {
  run "$SCRIPTS/triage-tick.sh" -h
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "# One-call campaign snapshot"* ]]
  [[ "${lines[${#lines[@]}-1]}" == "#       6 rerun requested but the issue note failed" ]]
}

@test "the triage tick doctrine is documented (#55)" {
  has() { grep -qF -- "$2" "$1" || { echo "missing in $1: $2"; return 1; }; }
  R="$ROOT/skills/orchestrate/roles"
  has "$R/triage-tick.md" "triage-tick.sh\" snapshot"
  has "$R/triage-tick.md" "7 days"
  has "$R/triage-tick.md" "only while the REPL is idle"
  has "$R/triage-tick.md" "beat --end bound"
  has "$R/triage-tick.md" "keeps merges held until"
  has "$R/README.md" "triage-tick.md"
  has "$ROOT/skills/orchestrate/SKILL.md" "roles/triage-tick.md"
  has "$ROOT/README.md" "triage-tick.sh"
}
