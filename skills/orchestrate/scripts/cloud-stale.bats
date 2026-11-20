#!/usr/bin/env bats
# Stale cloud dispatches (#259): a dispatch that never produced a PR must not hide its issue
# forever. cloud-dispatch.sh stale / expire and the ledger's "expired" rows, and the triage tick's
# dispatch-stale line. gh is stubbed: issue N and its timeline come from $FX. Run: bats cloud-stale.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FX"
  # api repos/o/r/issues/N -> $FX/issue-N.json, its timeline -> $FX/tl-N.json ([] when absent);
  # a missing issue file is a 404. The tick's list reads come from $FX/prs.json and issues.json.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  *"repos/o/r/issues/"*"/timeline"*)
    a="$*"; n=${a#*repos/o/r/issues/}; n=${n%%/*}
    if [ -f "$FX/tl-$n.json" ]; then cat "$FX/tl-$n.json"; else echo '[]'; fi ;;
  *"repos/o/r/issues/"*)
    a="$*"; n=${a#*repos/o/r/issues/}; n=${n%% *}
    [ -f "$FX/issue-$n.json" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    cat "$FX/issue-$n.json" ;;
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-09-27T01:00:00Z"}]}' ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "issue list"*) cat "$FX/issues.json" ;;
  "api graphql"*) echo '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_JITTER=0   # 2026-09-27T12:00:00Z
  unset ORCHESTRATE_DISPATCH_STALE_HOURS ORCHESTRATE_DISPATCH_CAP ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_HOST_LOAD
  stub_spectra   # an idle host: host-load.sh reads it through spectra (#330)
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  touch "$FX/calls"
}
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r --no-blocker-check; }
open_issue() { echo "{\"number\":$1,\"state\":\"${2:-open}\"}" >"$FX/issue-$1.json"; }
pr_ref() { # issue N gets a cross-reference from a PR: open | merged | closed
  jq -n --arg s "$2" '[{event: "cross-referenced", source: {issue: {html_url: "https://github.com/o/r/pull/90",
    state: (if $s == "open" then "open" else "closed" end),
    pull_request: {merged_at: (if $s == "merged" then "2026-09-27T09:00:00Z" else null end)}}}}]' >"$FX/tl-$1.json"
}
record() { cd_ record --issue "$1" --trigger "trig_$1" --run-at "$2" >/dev/null; }
calls_for() { awk -v n="issues/$1" 'index($0, n)' "$FX/calls" | awk 'END { print NR }'; }
has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "stale names a dispatch past the hours with no PR; young, closed and PR'd ones are quiet" {
  cd_ queue add 5 6 7 8 9 >/dev/null
  for n in 5 6 7 9; do record "$n" 2026-09-27T02:00:00Z; done   # 10 h ago
  record 8 2026-09-27T09:00:00Z                                 # 3 h ago
  open_issue 5; open_issue 6; open_issue 7 closed; open_issue 8; open_issue 9
  pr_ref 6 open; pr_ref 9 closed
  run cd_ stale
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'stale #5 dispatches=1/3 since=2026-09-27T02:00:00Z age=10h\nstale #9 dispatches=1/3 since=2026-09-27T02:00:00Z age=10h')" ]
  [ "$(calls_for 8)" -eq 0 ]                 # under the hours: no read at all
  [ "$(calls_for 7)" -eq 1 ]                 # closed: the timeline is not read
  pr_ref 9 merged
  run cd_ stale 9 5
  [ "$output" = "stale #5 dispatches=1/3 since=2026-09-27T02:00:00Z age=10h" ]
  # --hours moves the line; ORCHESTRATE_DISPATCH_STALE_HOURS is the default
  run cd_ stale 8 --hours 2
  [ "$output" = "stale #8 dispatches=1/3 since=2026-09-27T09:00:00Z age=3h" ]
  ORCHESTRATE_DISPATCH_STALE_HOURS=12 run cd_ stale 5
  [ "$output" = "" ]
}

@test "an unreadable issue or timeline is unknown (exit 7), never stale" {
  record 5 2026-09-27T02:00:00Z; record 6 2026-09-27T02:00:00Z
  open_issue 6; echo 'not json' >"$FX/tl-6.json"
  run cd_ stale
  [ "$status" -eq 7 ]
  [ "$output" = "$(printf 'unknown #5 issue\nunknown #6 timeline')" ]
  run cd_ expire --issue 5
  [ "$status" -eq 7 ]
  [[ "$output" == *"could not read the issue; do not expire it"* ]]
  [ "$(grep -c expired "$ST/cloud-sessions.tsv" || true)" -eq 0 ]
}

@test "expire ends a stale dispatch: queued again, recorded again, counted toward the cap" {
  cd_ queue add 5 6 >/dev/null
  record 5 2026-09-27T02:00:00Z
  open_issue 5
  run cd_ next --count 5
  [ "$output" = "6" ]
  run cd_ expire --issue 5
  [ "$status" -eq 0 ]
  [ "$output" = "expired #5 dispatch 1/3 (trigger trig_5); queued again" ]
  [ "$(awk -F'\t' '$5 == "expired"' "$ST/cloud-sessions.tsv")" = "$(printf '5\ttrig_5\t2026-09-27T02:00:00Z\t2026-09-27T12:00:00Z\texpired')" ]
  run cd_ next --count 5
  [ "$output" = "$(printf '5\n6')" ]
  run cd_ status
  [[ "$output" == *$'\n'"dispatched 1"$'\n'* ]]
  [[ "$output" == *$'\n'"expired 1"$'\n'* ]]
  [[ "$output" == *"last #5 trig_5 2026-09-27T02:00:00Z"* ]]
  # an expiry is not a create: pace counts only the one create in the last minute
  run cd_ pace --per-minute 2
  [ "$output" = "wait 0" ]
  run cd_ stale
  [ "$output" = "" ]
  # the second dispatch records; the issue is live again and counts 2 of 3
  run cd_ record --issue 5 --trigger trig_5b --run-at 2026-09-27T02:30:00Z
  [ "$status" -eq 0 ]
  run cd_ stale
  [ "$output" = "stale #5 dispatches=2/3 since=2026-09-27T02:30:00Z age=9h" ]
  run cd_ record --issue 5 --trigger trig_5c --run-at 2026-09-27T02:31:00Z
  [ "$status" -eq 3 ]
  # an expired issue dropped from the queue is put back on it
  cd_ queue drop 5 >/dev/null
  run cd_ expire --issue 5
  [ "$status" -eq 0 ]
  [ "$(grep -cx 5 "$ST/cloud-queue.txt")" -eq 1 ]
}

@test "expire refuses at the cap, before it is stale, with a PR, when closed, or with no live dispatch" {
  record 5 2026-09-27T02:00:00Z; open_issue 5
  run cd_ expire --issue 5 --cap 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"#5 reached the dispatch cap (1/1)"* ]]
  run cd_ stale --cap 1
  [ "$output" = "capped #5 dispatches=1/1 since=2026-09-27T02:00:00Z age=10h" ]
  ORCHESTRATE_DISPATCH_CAP=1 run cd_ stale
  [[ "$output" == "capped #5 "* ]]
  run cd_ expire --issue 5 --hours 11
  [ "$status" -eq 3 ]
  [[ "$output" == *"under 11h ago; not stale yet"* ]]
  pr_ref 5 open
  run cd_ expire --issue 5
  [ "$status" -eq 3 ]
  [[ "$output" == *"has a PR (https://github.com/o/r/pull/90); repair that instead"* ]]
  open_issue 5 closed
  run cd_ expire --issue 5
  [ "$status" -eq 3 ]
  [[ "$output" == *"#5 is closed"* ]]
  # --force skips the stale check, never the cap
  run cd_ expire --issue 5 --force --hours 11
  [ "$status" -eq 0 ]
  run cd_ expire --issue 5
  [ "$status" -eq 3 ]
  [[ "$output" == *"#5 has no live dispatch in the ledger"* ]]
  run cd_ expire
  [ "$status" -eq 2 ]
  run cd_ stale --cap 0
  [ "$status" -eq 2 ]
  run cd_ stale --hours x
  [ "$status" -eq 2 ]
}

@test "repair rows are neither dispatches nor expiries" {
  record 5 2026-09-27T02:00:00Z; open_issue 5
  printf '5\ttrig_r\t2026-09-27T03:00:00Z\t2026-09-27T03:00:00Z\trepair\n' >>"$ST/cloud-sessions.tsv"
  run cd_ stale
  [ "$output" = "stale #5 dispatches=1/3 since=2026-09-27T02:00:00Z age=10h" ]
}

tick_fixtures() {
  echo '[{"number":70,"closingIssuesReferences":[{"number":6}]}]' >"$FX/prs.json"
  echo '[{"number":5,"labels":[]},{"number":6,"labels":[]},{"number":8,"labels":[]},{"number":9,"labels":[]},{"number":11,"labels":[]}]' >"$FX/issues.json"
}
snap() { "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main "$@"; }

@test "the tick leaves live dispatches out of dispatch and names stale ones in their own line" {
  tick_fixtures
  echo "beat=$ORCHESTRATE_NOW deadline=$((ORCHESTRATE_NOW + 3600)) pid=0" >"$ST/merge-loop.beat"
  run snap
  [ "$(snap_line dispatch)" = "dispatch 4 next=#5,#8,#9" ]
  [ "$(grep -c '^dispatch-stale' <<<"$output" || true)" -eq 0 ]
  # 5 and 9: stale; 6: in an open PR (no read); 8: young (no read); 10: closed, not in the list
  for n in 5 6 9 10; do record "$n" 2026-09-27T02:00:00Z; done
  record 8 2026-09-27T09:00:00Z
  printf '9\ttrig_9\t2026-09-27T02:00:00Z\t2026-09-27T02:00:00Z\texpired\n9\ttrig_9b\t2026-09-27T02:10:00Z\t2026-09-27T02:10:00Z\n' >>"$ST/cloud-sessions.tsv"
  open_issue 5; open_issue 9
  : >"$FX/calls"
  run snap
  [ "$status" -eq 0 ]
  [ "$(snap_line dispatch)" = "dispatch 1 next=#11" ]
  [ "$(snap_line dispatch-stale)" = "dispatch-stale redispatch=#5,#9 capped=- unknown=-" ]
  [[ "${lines[0]}" == "verdict act "*"dispatch-stale=2"* ]]
  required_snapshot_lines
  for n in 6 8 10; do [ "$(calls_for "$n")" -eq 0 ]; done
  # at the cap it is named capped; an unreadable one is unknown, never stale
  rm "$FX/issue-5.json"
  ORCHESTRATE_DISPATCH_CAP=2 run snap
  [ "$(snap_line dispatch-stale)" = "dispatch-stale redispatch=- capped=#9 unknown=#5" ]
  [[ "${lines[0]}" == *"dispatch-capped=1"* ]]
  [[ "${lines[0]}" != *"dispatch-stale="* ]]
  # expired, the issue waits for dispatch again
  open_issue 5
  cd_ expire --issue 5 >/dev/null
  run snap
  [ "$(snap_line dispatch)" = "dispatch 2 next=#5,#11" ]
  [ "$(snap_line dispatch-stale)" = "dispatch-stale redispatch=#9 capped=- unknown=-" ]
}

@test "the tick reads 1000 issues and says when the list may be cut short" {
  tick_fixtures
  jq -n '[range(1; 1001) | {number: (. + 100), labels: []}]' >"$FX/issues.json"
  run snap
  [ "$status" -eq 0 ]
  grep -q -- "issue list .*--limit 1000" "$FX/calls"
  [ "$(snap_line dispatch)" = "dispatch 1000 next=#101,#102,#103 list=truncated@1000" ]
  [[ "${lines[0]}" == *"issue-list-truncated"* ]]
  tick_fixtures
  run snap
  [[ "${lines[0]}" != *"issue-list-truncated"* ]]
}

@test "stale-dispatch doctrine: the procedure says when to expire and re-dispatch (#259)" {
  R="$ROOT/skills/orchestrate/roles/cloud-dispatch.md"
  has "$R" "cloud-dispatch.sh stale"
  has "$R" "cloud-dispatch.sh expire --issue N"
  has "$R" "ORCHESTRATE_DISPATCH_STALE_HOURS"
  has "$R" "ORCHESTRATE_DISPATCH_CAP"
  has "$ROOT/skills/orchestrate/roles/triage-tick.md" "dispatch-stale"
  has "$ROOT/README.md" "expire"
}
