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
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD
  stub_spectra   # an idle host: host-load.sh reads it through spectra (#330)
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r/actions/runs?"*) jq '{workflow_runs: map({name: .workflowName, status, conclusion, head_sha: .headSha, id: .databaseId, created_at: .createdAt})}' "$FX/runs.json" ;;
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

@test "the required snapshot lines are each present exactly once, in the documented order (#201)" {
  run snap
  [ "$status" -eq 0 ]
  required_snapshot_lines
  # holds present: the optional lines do not disturb the required ones
  printf '70 until:main-green since:2026-09-26T03:00:00Z needs green main\n' >"$ST/holds"
  run snap --hold-hours 1
  [ "$status" -eq 0 ]
  [ "$(snap_line holds)" = "holds n=1 stale=1" ]
  [[ "$(snap_line hold-stale)" == "hold-stale #70 "* ]]
  required_snapshot_lines
  # the checker itself: a missing, repeated or misplaced line fails it
  output=$'verdict ok\nmain green x\nprs open=0\nmerge_loop absent\ndispatch 0 next=-\nslots none\ncron none\nthreads none'
  run required_snapshot_lines
  [ "$status" -eq 1 ]
  [[ "$output" == *"host: 0 times"* ]]
  output=$'verdict ok\nmain green x\nprs open=0\nmerge_loop absent\ndispatch 0 next=-\nslots none\ncron none\nthreads none\nhost unknown\nhost unknown'
  run required_snapshot_lines
  [ "$status" -eq 1 ]
  [[ "$output" == *"host: 2 times"* ]]
  output=$'verdict ok\nprs open=0\nmain green x\nmerge_loop absent\ndispatch 0 next=-\nslots none\ncron none\nthreads none\nhost unknown'
  run required_snapshot_lines
  [ "$status" -eq 1 ]
  [[ "$output" == *"prs (line 2) before main (line 3)"* ]]
  output=$'main green x\nverdict ok\nprs open=0\nmerge_loop absent\ndispatch 0 next=-\nslots none\ncron none\nthreads none\nhost unknown\nextra line'
  run required_snapshot_lines
  [ "$status" -eq 1 ]
  [[ "$output" == *"verdict is line 2"* ]]
  # an extra line anywhere is fine
  output=$'verdict ok\nmain green x\nnew-part 1\nprs open=0\nmerge_loop absent\ndispatch 0 next=-\nslots none\ncron none\nthreads none\nhost unknown\nholds n=1 stale=0'
  required_snapshot_lines
}

@test "the required snapshot lines are documented in triage-tick.sh's header, in that order (#225)" {
  run snapshot_line_names "$SCRIPTS/triage-tick.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = verdict ]
  # every required line, in order, among the documented ones (optional ones may sit between)
  [ "$(awk -v want="$REQUIRED_SNAPSHOT_LINES" 'BEGIN { n = split(want, w, " "); i = 1 }
    $1 == w[i] { i++ } END { print (i - 1 == n) ? "all" : "missing " w[i] }' <<<"$output")" = all ]
  [[ "$output" == *$'\n'holds$'\n'hold-stale* ]]
}

@test "a quiet campaign is one ok verdict with every part present" {
  echo "beat=$((ORCHESTRATE_NOW - 60)) deadline=$((ORCHESTRATE_NOW + 3600)) pid=0" >"$ST/merge-loop.beat"
  printf '2026-09-25T10:00:00Z\tpr=50\thead=abc\tmerged x\n2026-09-27T10:00:00Z\tpr=60\thead=abc\tmerged deadbeef method=squash admin=no\n2026-09-27T11:00:00Z\tpr=61\thead=abc\trefused not ready\n' >"$ST/merges.log"
  printf 'wt1\tb1\t6,8\tsrc/\tandroid:sonnet\tactive\nwt2\tb2\t9\tios/\tios:sonnet\tactive\n' >"$ST/lanes.tsv"
  run snap --device-slots android=1,ios=2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "verdict ok" ]
  [ "$(snap_line main)" = "main green aaaaaaaaa Test@aaaaaaaaa" ]
  [ "$(snap_line prs)" = "prs open=2" ]
  [[ "$(snap_line merge_loop)" == "merge_loop alive beat_age=60 deadline=2026-09-27T13:00:00Z last_merge=2026-09-27T10:00:00Z pr=60 merges_24h=1" ]]
  [ "$(snap_line dispatch)" = "dispatch 0 next=-" ]
  [ "$(snap_line slots)" = "slots android=1/1,ios=1/2" ]
  [ "$(snap_line cron)" = "cron none" ]
  required_snapshot_lines
  [ "$(snap_line threads)" = "threads unresolved=0 answered=0 resolve-now=- repair=-" ]
  [[ "$(snap_line host)" == "host ADMIT cause="*" free_gb=32.0 load=0.5 limit=12.00" ]]
}

@test "the dispatch queue skips issues in an open PR, in an active lane, or excluded" {
  printf 'wt1\tb1\t8\tsrc/\tsonnet\tactive\nwt2\tb2\t9\tx/\tsonnet\tmerged\n' >"$ST/lanes.tsv"
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
  [[ "$(snap_line merge_loop)" == "merge_loop ended:bound beat_age=0 "* ]]
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
  [[ "$(snap_line merge_loop)" == "merge_loop alive beat_age=0 deadline=2026-09-27T20:00:00Z"* ]]
  run "$SCRIPTS/triage-tick.sh" beat --repo o/r
  [ "$status" -eq 2 ]
}

@test "red main classified RERUN_DONT_FIX is a rerun candidate, like main-health (#275)" {
  red_runs; echo '[]' >"$FX/issues.json"
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  echo "RERUN_DONT_FIX: transient" >"$FX/class-11"
  run snap --classifier classify
  [ "${lines[0]}" = "verdict act flake-rerun" ]
  [ "$(snap_line main)" = "main red bbbbbbbbb runs=11:rerun-dont-fix action=rerun" ]
}

@test "red main with a classified known flake asks for a rerun; anything else asks for a fix lane" {
  red_runs; echo '[]' >"$FX/issues.json"
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  echo "flake: known BATS timing flake" >"$FX/class-11"
  run snap --classifier classify
  [ "${lines[0]}" = "verdict act flake-rerun" ]
  [ "$(snap_line main)" = "main red bbbbbbbbb runs=11:flake action=rerun" ]
  [ -f "$ST/MAIN_RED" ]
  echo "INVESTIGATE new failure" >"$FX/class-11"
  run snap --classifier classify
  [ "${lines[0]}" = "verdict act main-red" ]
  [ "$(snap_line main)" = "main red bbbbbbbbb runs=11:investigate action=fix-lane" ]
  # no classifier configured: never assumed to be a flake
  run snap
  [ "$(snap_line main)" = "main red bbbbbbbbb runs=11:unclassified action=fix-lane" ]
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
  [ "$(snap_line main)" = "main held rerun-pending runs=11" ]
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
  [ "$(snap_line main)" = "main red bbbbbbbbb runs=11:rerun-failed action=fix-lane" ]
}

@test "a refused rerun is logged and can be tried again; a failed note is its own exit" {
  touch "$FX/rerun-fails"
  run "$SCRIPTS/triage-tick.sh" rerun --repo o/r --run 11 --issue 42
  [ "$status" -eq 5 ]
  [ ! -f "$ST/MAIN_RED" ]
  run ! grep -q 'issue comment' "$FX/calls"
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
  [[ "$(snap_line main)" == "main unknown no completed run"* ]]
  [ "$(snap_line prs)" = "prs open=unknown" ]
  [ "$(snap_line dispatch)" = "dispatch unknown next=-" ]
}

@test "cron records its creation and warns in the last day of its 7-day life" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  echo '[]' >"$FX/issues.json"
  run "$SCRIPTS/triage-tick.sh" cron --repo o/r --created $((ORCHESTRATE_NOW - 2 * 86400))
  [ "$status" -eq 0 ]
  run snap
  [ "${lines[0]}" = "verdict ok" ]
  [ "$(snap_line cron)" = "cron age=48h expires_in=120h" ]
  run "$SCRIPTS/triage-tick.sh" cron --repo o/r --created $((ORCHESTRATE_NOW - 6 * 86400 - 3600))
  run snap
  [ "${lines[0]}" = "verdict act cron-expiring" ]
  [ "$(snap_line cron)" = "cron age=145h expires_in=23h" ]
}

# host_stub RC [OUTPUT]: ORCHESTRATE_HOST_LOAD prints OUTPUT (TSV, as host-load.sh does) and exits RC.
host_stub() {
  printf '%s\n' "${2-}" >"$FX/host-load.out"
  printf '#!/usr/bin/env bash\necho "$*" >>"$FX/host-load.args"\ncat "$FX/host-load.out"\nexit %s\n' "$1" >"$BATS_TEST_TMPDIR/bin/host-load"
  chmod +x "$BATS_TEST_TMPDIR/bin/host-load"
  export ORCHESTRATE_HOST_LOAD="$BATS_TEST_TMPDIR/bin/host-load"
}

@test "host ADMIT adds the host line and no reason: dispatch stands (#114)" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  run snap
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "verdict act dispatch=3" ]
  [ "$(snap_line dispatch)" = "dispatch 3 next=#6,#8,#9" ]
  [[ "$(snap_line host)" == "host ADMIT cause="* ]]
  required_snapshot_lines
}

@test "host HOLD or BACKOFF with a cause turns dispatch into host-hold; the queue is still listed (#114)" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  host_stub 3 "$(printf 'verdict\tHOLD\t1-min load 30.1 >= 12.00 (1.5 x 8 CPUs)\nload\t30.1\t8 CPUs, limit 12.00\nmemory\t20.0\tmin 8, backoff 4\ndevice-slots\t3\ncause\tindexing\tmds_stores 240%%\nhint\tremove worktrees\ntop-cpu\t9\t240\t900\tmds_stores\t-')"
  run snap
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "verdict act host-hold" ]
  [ "$(snap_line dispatch)" = "dispatch 3 next=#6,#8,#9" ]
  [ "$(snap_line host)" = "host HOLD cause=indexing free_gb=20.0 load=30.1 limit=12.00" ]
  [ "$(cat "$FX/host-load.args")" = "--top 3" ]
  host_stub 4 "$(printf 'verdict\tBACKOFF\tfree memory 2.0 GB < 4 GB\nload\t1.0\t8 CPUs, limit 12.00\nmemory\t2.0\tmin 8, backoff 4\ncause\tlanes\tjava 300%%')"
  run snap
  [ "${lines[0]}" = "verdict act host-hold" ]
  [ "$(snap_line host)" = "host BACKOFF cause=lanes free_gb=2.0 load=1.0 limit=12.00" ]
  # nothing to dispatch: a held host adds no reason
  echo '[]' >"$FX/issues.json"
  run snap
  [ "${lines[0]}" = "verdict ok" ]
  [[ "$(snap_line host)" == "host BACKOFF "* ]]
}

@test "leftover lane processes are reported from spectra orphans, by worktree; nothing is killed (#332)" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  # No worktree root: no orphans line at all.
  run snap
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\n'orphans* ]]
  export ORCHESTRATE_WORKTREE_ROOT="$BATS_TEST_TMPDIR/wt"; mkdir -p "$ORCHESTRATE_WORKTREE_ROOT"
  run snap
  [ "$(snap_line orphans)" = "orphans 0 worktrees=-" ]
  [[ "${lines[0]}" != *orphans=* ]]
  grep -qx "orphans --json --root $(cd "$ORCHESTRATE_WORKTREE_ROOT" && pwd -P)" "$BATS_TEST_TMPDIR/spectra-calls"
  # Two worktrees with leftovers (one already removed); a by-design daemon is not counted.
  jq -n '{total: 3, groups: [
      {worktree: "lane-a", worktree_removed: false, processes: [{pid: 11, command: "node"}, {pid: 12, command: "java"}]},
      {worktree: "lane-b", worktree_removed: true, processes: [{pid: 13, command: "qemu-system-aarch64"}]},
      {worktree: "lane-c", worktree_removed: false, processes: [{pid: 14, command: "watchman", daemon_by_design: true}]}]}' \
    >"$BATS_TEST_TMPDIR/spectra-orphans.json"
  run snap
  [ "$status" -eq 0 ]
  [ "$(snap_line orphans)" = "orphans 3 worktrees=lane-a(2),lane-b(removed:1)" ]
  [[ "${lines[0]}" == "verdict act "*"orphans=3"* ]]
  # spectra failing, or missing, is unknown and holds nothing.
  SPECTRA_STUB_FAIL=1 run snap
  [ "$(snap_line orphans)" = "orphans unknown" ]
  [[ "${lines[0]}" != *orphans=* ]]
  SPECTRA="$BATS_TEST_TMPDIR/none" run snap
  [ "$(snap_line orphans)" = "orphans unknown" ]
}

@test "a slot held past the stall age by an idle holder is named; a young or busy one is not (#333)" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  export ORCHESTRATE_SLOT_DIR="$BATS_TEST_TMPDIR/slots"
  sleep 60 & idle_pid=$!; sleep 60 & busy_pid=$!
  hold() { # POOL N PID LABEL MINUTES-AGO
    local d="$ORCHESTRATE_SLOT_DIR/$1/slot-$2"
    mkdir -p "$d"
    printf '%s\n%s\n%s\n' "$3" "$(ps -o lstart= -p "$3" | sed 's/^ *//; s/ *$//; s/  */ /g')" "$4" >"$d/holder"
    touch -t "$(date -v-"$5"M +%Y%m%d%H%M 2>/dev/null || date -d "-$5 min" +%Y%m%d%H%M)" "$d/holder"
  }
  hold heavy 1 "$idle_pid" lane-x 25
  hold gate 1 "$busy_pid" lane-y 25
  hold gate 2 "$$" lane-z 2
  jq -n --argjson p "$idle_pid" '{result: {holders: [{pid: $p, command: "bash"}]}}' >"$BATS_TEST_TMPDIR/spectra-idle.json"
  run snap
  kill "$idle_pid" "$busy_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$(snap_line slot-stalled)" =~ ^"slot-stalled heavy pid=$idle_pid held="2[5-9]"m label=lane-x"$ ]]
  [ "$(printf '%s\n' "$output" | grep -c '^slot-stalled')" -eq 1 ]
  [[ "${lines[0]}" == "verdict act "*"slot-stalled=1"* ]]
  # Spectra was asked about the two old holders only, with the stall age as its minimum.
  grep -qx "idle --pids $(sort -n <<<"$idle_pid"$'\n'"$busy_pid" | paste -sd, -) --min-age 10m --json" "$BATS_TEST_TMPDIR/spectra-calls" ||
    grep -qx "idle --pids $busy_pid,$idle_pid --min-age 10m --json" "$BATS_TEST_TMPDIR/spectra-calls"
}

@test "stalled-slot checks with no spectra are unknown, and a dead holder is not checked (#333)" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  export ORCHESTRATE_SLOT_DIR="$BATS_TEST_TMPDIR/slots"
  mkdir -p "$ORCHESTRATE_SLOT_DIR/heavy/slot-1"
  printf '999999\nMon Jan 1 00:00:00 1990\ngone\n' >"$ORCHESTRATE_SLOT_DIR/heavy/slot-1/holder"
  touch -t 202001010000 "$ORCHESTRATE_SLOT_DIR/heavy/slot-1/holder"
  run snap
  [[ "$output" != *slot-stalled* ]]
  mkdir -p "$ORCHESTRATE_SLOT_DIR/gate/slot-1"
  printf '%s\n%s\nme\n' "$$" "$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//; s/  */ /g')" >"$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder"
  touch -t 202001010000 "$ORCHESTRATE_SLOT_DIR/gate/slot-1/holder"
  SPECTRA="$BATS_TEST_TMPDIR/none" run snap
  [ "$(snap_line slot-stalled)" = "slot-stalled unknown pids=$$" ]
  [[ "${lines[0]}" != *slot-stalled=* ]]
}

@test "the real host-load.sh over a loaded host holds dispatch (#114)" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  SPECTRA_STUB_LOAD1=99 run snap
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "verdict act host-hold" ]
  [[ "$(snap_line host)" == "host HOLD cause="*" free_gb=32.0 load=99 limit=12.00" ]]
}

@test "a host-load failure says host unknown and blocks nothing (#114)" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  for out in "2:host-load.sh: bad --top" "0:no verdict here" "9:"; do
    host_stub "${out%%:*}" "${out#*:}"
    run snap
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "verdict act dispatch=3" ]
    [ "$(snap_line host)" = "host unknown" ]
    required_snapshot_lines
  done
  ORCHESTRATE_HOST_LOAD="$BATS_TEST_TMPDIR/no-such-command" run snap
  [ "$status" -eq 0 ]
  [ "$(snap_line host)" = "host unknown" ]
}

@test "an issue row without labels, or with labels null, is unlabelled, not a failed snapshot (#130)" {
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 60)) pid=0" >"$ST/merge-loop.beat"
  echo '[{"number":6},{"number":7,"labels":null},{"number":8,"labels":[{"name":"blocked"}]},{"number":9,"labels":[{"name":"cloud-ready"}]}]' >"$FX/issues.json"
  run snap
  [ "$status" -eq 0 ]
  required_snapshot_lines
  [ "${lines[0]}" = "verdict act dispatch=3" ]
  [ "$(snap_line dispatch)" = "dispatch 3 next=#6,#7,#9" ]
  # unlabelled: never matches a ready label
  run snap --ready-label cloud-ready
  [ "$status" -eq 0 ]
  [ "$(snap_line dispatch)" = "dispatch 1 next=#9" ]
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
  has "$R/triage-tick.md" "host-hold"
  has "$R/triage-tick.md" "host unknown"
  has "$R/README.md" "triage-tick.md"
  has "$ROOT/skills/orchestrate/SKILL.md" "roles/triage-tick.md"
  has "$ROOT/README.md" "triage-tick.sh"
}
