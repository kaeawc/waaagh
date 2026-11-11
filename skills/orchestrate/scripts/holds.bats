#!/usr/bin/env bats
# Merge-loop holds (#196): hold.sh (release conditions, since timestamps, old-format lines, the
# release that edits the file and logs together), pr-ready.sh skipping held PRs, the triage tick
# naming stale holds, and the doctrine that points at them. Run: bats scripts/holds.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_HOLD_STALE_HOURS ORCHESTRATE_DEVICE_REGRESSION_LABELS ORCHESTRATE_DEVICE_HOLD_LABEL
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
case "$all" in
  "api repos/o/r/pulls/"*) n=${all#api repos/o/r/pulls/}; f="$FX/pull-${n%% *}.json"
    [ -f "$f" ] || { echo "HTTP 404" >&2; exit 1; }; cat "$f" ;;
  "api repos/o/r/issues/"*) n=${all#api repos/o/r/issues/}; f="$FX/issue-${n%% *}.json"
    [ -f "$f" ] || { echo "HTTP 404" >&2; exit 1; }; cat "$f" ;;
  "pr view "*) n=${all#pr view }; f="$FX/prview-${n%% *}.json"
    [ -f "$f" ] || { echo "HTTP 502" >&2; exit 1; }; cat "$f" ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

h() { "$SCRIPTS/hold.sh" "$1" --repo o/r "${@:2}"; }

@test "add writes '<pr> until:<event> since:<iso> <reason>' and logs it; list, prs read old lines too" {
  printf '# holds\n\n17403 waiting on the device recheck\n#55\n' >"$ST/holds"
  run h add --pr 12 --until main-green --reason "needs green main"
  [ "$status" -eq 0 ]
  [ "$output" = "held: PR 12 until:main-green" ]
  grep -qx '12 until:main-green since:2026-09-27T12:00:00Z needs green main' "$ST/holds"
  grep -q $'^2026-09-27T12:00:00Z\tpr=12\theld until:main-green reason=needs green main$' "$ST/holds.log"
  run h list
  [ "${lines[0]}" = $'17403\tunknown\tunknown\tunknown\twaiting on the device recheck' ]
  [ "${lines[1]}" = $'55\tunknown\tunknown\tunknown\t-' ]
  [ "${lines[2]}" = $'12\tmain-green\t2026-09-27T12:00:00Z\t0\tneeds green main' ]
  run h prs
  [ "$output" = $'17403\n55\n12' ]
  # Re-adding replaces the hold (an old-format line becomes a new one) and says so in the log.
  run h add --pr 17403 --until device-recheck --reason "emulator recheck"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^17403' "$ST/holds")" -eq 1 ]
  grep -q 'pr=17403	held until:device-recheck reason=emulator recheck (replaced an earlier hold)' "$ST/holds.log"
  grep -qx '# holds' "$ST/holds"
}

@test "add refuses an unknown release condition and a bad PR, before writing anything" {
  run h add --pr 12 --until whenever
  [ "$status" -eq 2 ]
  [[ "$output" == *"--until must be"* ]]
  run h add --pr 12 --until merged:x
  [ "$status" -eq 2 ]
  run h add --pr 12 --until at:tomorrow
  [ "$status" -eq 2 ]
  run h add --pr abc --until owner
  [ "$status" -eq 2 ]
  run h stale --hours x
  [ "$status" -eq 2 ]
  run h check --pr x
  [ "$status" -eq 2 ]
  run "$SCRIPTS/hold.sh" frobnicate
  [ "$status" -eq 2 ]
  [ ! -f "$ST/holds" ]
  [ ! -f "$ST/holds.log" ]
}

@test "release removes the line and logs it in one step; a PR not held is refused with no log line" {
  printf '17403 until:device-recheck since:2026-09-26T03:00:00Z recheck\n#55 legacy\n' >"$ST/holds"
  run h release --pr 17403 --note "recheck passed on abc123"
  [ "$status" -eq 0 ]
  [ "$output" = "released: PR 17403 (until:device-recheck, held 33h)" ]
  [ "$(grep -c '^17403' "$ST/holds" || true)" -eq 0 ]
  grep -q $'pr=17403\treleased until:device-recheck since:2026-09-26T03:00:00Z held=33h note=recheck passed on abc123$' "$ST/holds.log"
  run h release --pr '#55'
  [ "$status" -eq 0 ]
  [ "$output" = "released: PR 55 (until:unknown, held unknown)" ]
  [ "$(grep -c '55' "$ST/holds" || true)" -eq 0 ]
  run h release --pr 99
  [ "$status" -eq 3 ]
  [[ "$output" == "not held: PR 99"* ]]
  [ "$(grep -c 'pr=99' "$ST/holds.log" || true)" -eq 0 ]
  [ "$(wc -l <"$ST/holds.log")" -eq 2 ]
}

@test "release waits out another writer's lock and gives up with exit 4" {
  printf '12 until:owner since:2026-09-27T11:00:00Z x\n' >"$ST/holds"
  mkdir "$ST/holds.lock"
  run h release --pr 12
  [ "$status" -eq 4 ]
  [[ "$output" == *"locked by another writer"* ]]
  grep -q '^12 ' "$ST/holds"
  [ ! -f "$ST/holds.log" ]
  rmdir "$ST/holds.lock"
  run h release --pr 12
  [ "$status" -eq 0 ]
  [ ! -d "$ST/holds.lock" ]
}

@test "stale names holds past --hours, and every hold of unknown age, with its reason" {
  printf '1 until:device-recheck since:2026-09-26T03:00:00Z device recheck on the Duo\n2 until:main-green since:2026-09-27T10:00:00Z main\n3 old free text\n' >"$ST/holds"
  run h stale
  [ "$status" -eq 3 ]
  [ "$output" = $'#1 age=33h until:device-recheck reason=device recheck on the Duo\n#3 age=unknown until:unknown reason=old free text' ]
  run h stale --hours 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"#2 age=2h until:main-green reason=main"* ]]
  ORCHESTRATE_HOLD_STALE_HOURS=40 run h stale
  [ "$output" = "#3 age=unknown until:unknown reason=old free text" ]
  printf '2 until:main-green since:2026-09-27T10:00:00Z main\n' >"$ST/holds"
  run h stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm "$ST/holds"
  run h stale
  [ "$status" -eq 0 ]
  run h list
  [ -z "$output" ]
}

@test "check evaluates each release condition; --release releases only the met ones" {
  echo '{"merged_at":"2026-09-27T09:00:00Z"}' >"$FX/pull-80.json"
  echo '{"merged_at":null}' >"$FX/pull-81.json"
  echo '{"state":"closed"}' >"$FX/issue-90.json"
  echo '{"state":"open"}' >"$FX/issue-91.json"
  echo '{"state":"OPEN","headRefOid":"abcdef1234567890","body":"","labels":[]}' >"$FX/prview-7.json"
  echo '{"state":"OPEN","headRefOid":"abcdef1234567890","body":"","labels":[{"name":"needs-device-recheck"}]}' >"$FX/prview-8.json"
  {
    echo "1 until:main-green since:2026-09-27T11:00:00Z a"
    echo "2 until:at:2026-09-27T11:00:00Z since:2026-09-27T10:00:00Z b"
    echo "3 until:at:2026-09-28T00:00:00Z since:2026-09-27T10:00:00Z c"
    echo "4 until:owner since:2026-09-27T10:00:00Z d"
    echo "5 until:merged:80 since:2026-09-27T10:00:00Z e"
    echo "6 until:merged:81 since:2026-09-27T10:00:00Z f"
    echo "9 until:closed:90 since:2026-09-27T10:00:00Z g"
    echo "10 until:closed:91 since:2026-09-27T10:00:00Z h"
    echo "11 until:closed:92 since:2026-09-27T10:00:00Z i"
    echo "7 until:device-recheck since:2026-09-27T10:00:00Z j"
    echo "8 until:device-recheck since:2026-09-27T10:00:00Z k"
    echo "12 legacy line"
  } >"$ST/holds"
  run h check
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "#1 met until:main-green no MAIN_RED" ]]
  [[ "${lines[1]}" == "#2 met until:at:2026-09-27T11:00:00Z 2026-09-27T11:00:00Z passed" ]]
  [[ "${lines[2]}" == "#3 unmet until:at:2026-09-28T00:00:00Z not before"* ]]
  [[ "${lines[3]}" == "#4 manual until:owner only the owner releases it" ]]
  [[ "${lines[4]}" == "#5 met until:merged:80 PR 80 merged" ]]
  [[ "${lines[5]}" == "#6 unmet until:merged:81 PR 81 not merged" ]]
  [[ "${lines[6]}" == "#9 met until:closed:90 #90 closed" ]]
  [[ "${lines[7]}" == "#10 unmet until:closed:91 #91 open" ]]
  [[ "${lines[8]}" == "#11 unknown until:closed:92 #92 could not be read" ]]
  [[ "${lines[9]}" == "#7 met until:device-recheck clear:"* ]]
  [[ "${lines[10]}" == "#8 unmet until:device-recheck held:"* ]]
  [[ "${lines[11]}" == "#12 manual until:unknown no release condition (legacy line)"* ]]
  [ ! -f "$ST/holds.log" ]          # a plain check changes nothing
  echo red >"$ST/MAIN_RED"
  run h check --pr 1
  [ "$output" = "#1 unmet until:main-green MAIN_RED is set" ]
  rm "$ST/MAIN_RED"
  run h check --pr 999
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run h check --release
  [ "$status" -eq 0 ]
  [[ "$output" == *"released: PR 5 (until:merged:80, held 2h)"* ]]
  run h prs
  [ "$output" = $'3\n4\n6\n10\n11\n8\n12' ]
  [ "$(grep -c 'released' "$ST/holds.log")" -eq 5 ]
  grep -q $'pr=7\treleased until:device-recheck since:2026-09-27T10:00:00Z held=2h note=condition met: clear:' "$ST/holds.log"
}

@test "pr-ready.sh skips every PR in the hold file as a hold, without --hold" {
  load selftest_helper
  stub_gh_router
  ready_prs 3
  printf '2 until:device-recheck since:2026-09-27T10:00:00Z recheck\n' >"$ORCHESTRATE_STATE_DIR/o__r/holds"
  run "$SCRIPTS/pr-ready.sh" --repo o/r --base main --author me --no-threads
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tREADY'* ]]
  [[ "$output" == *$'2\tSKIP\tabcdef012\tMERGEABLE\t1\thold ready-but-skipped'* ]]
  [[ "$output" == *$'3\tREADY'* ]]
  [[ "$output" == *"skipped-by=hold:1"* ]]
}

tick_stub() {
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-09-27T01:00:00Z"}]}' ;;
  "pr list"*) echo '[]' ;;
  "issue list"*) echo '[]' ;;
  "api graphql"*) echo '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD
  export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768
}

@test "the tick counts holds and names every stale one with its reason as hold-stale" {
  tick_stub
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$status" -eq 0 ]
  [ "$(grep -c '^holds' <<<"$output" || true)" -eq 0 ]
  printf '17403 until:device-recheck since:2026-09-26T03:00:00Z device recheck\n2 until:main-green since:2026-09-27T11:00:00Z m\n' >"$ST/holds"
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "verdict act "*"hold-stale=1"* ]]
  [ "$(snap_line holds)" = "holds n=2 stale=1" ]
  # one hold-stale line, for the stale hold only, right after holds; the required lines unchanged
  [ "$(snap_line hold-stale)" = "hold-stale #17403 age=33h until:device-recheck reason=device recheck" ]
  [ "$(awk 'p { print; exit } $1 == "holds" { p = 1 }' <<<"$output")" = "$(snap_line hold-stale)" ]
  required_snapshot_lines
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main --hold-hours 40
  [ "$(snap_line holds)" = "holds n=2 stale=0" ]
  [ "$(grep -c '^hold-stale' <<<"$output" || true)" -eq 0 ]
  [[ "${lines[0]}" != *hold-stale* ]]
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --hold-hours soon
  [ "$status" -eq 2 ]
}

@test "doctrine: the merge bot, the tick and the campaign-state table use hold.sh" {
  grep -q 'hold.sh release' "$ROOT/roles/merge-bot.md"
  grep -q 'hold-stale' "$ROOT/roles/triage-tick.md"
  grep -q 'hold.sh" check --repo {{REPO}} --release' "$ROOT/roles/triage-tick.md"
  grep -q '`holds`, `holds.log`' "$ROOT/SKILL.md"
  grep -q 'hold.sh' "$ROOT/../../README.md"
}
