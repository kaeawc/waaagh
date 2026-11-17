#!/usr/bin/env bats
# One writer per PR across cloud sessions (#214): cloud-dispatch.sh record --kind repair posts one
# REPAIR-START marker on the PR (repair-writer.sh mark), the implement briefs stop before a push
# once it is there, and the triage tick flags a second writer the commit metadata shows
# (repair-writer.sh check). gh is stubbed from $FX. Run: bats repair-writer.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FX"
  # Fixtures in $FX: comments-N.json, commits-N.json, events-N.json answer PR N's reads (absent:
  # HTTP 404). A POSTed comment body goes to posted-N; post-fails makes the POST fail.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
serve() { [ -f "$FX/$1.json" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }; cat "$FX/$1.json"; }
num() { local a=${1#*/issues/}; a=${a#*/pulls/}; echo "${a%%/*}"; }
case "$*" in
  "api --paginate repos/o/r/issues/"*"/comments?per_page=100") serve "comments-$(num "$3")" ;;
  "api --paginate repos/o/r/pulls/"*"/commits?per_page=100") serve "commits-$(num "$3")" ;;
  "api --paginate repos/o/r/issues/"*"/events?per_page=100") serve "events-$(num "$3")" ;;
  "api -X POST repos/o/r/issues/"*"/comments -f body="*)
    [ ! -f "$FX/post-fails" ] || { echo "HTTP 500" >&2; exit 1; }
    printf '%s\n' "${6#body=}" >>"$FX/posted-$(num "$4")"; echo '{}' ;;
  *) echo "HTTP 404: Not Found" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_JITTER=0 ORCHESTRATE_READ_SLEEP=0   # 2026-09-27T12:00:00Z
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD ORCHESTRATE_HOLD_STALE_HOURS
  export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768
  ST="$ORCHESTRATE_STATE_DIR/o__r"
  mkdir -p "$ST"
}
rw() { "$SCRIPTS/repair-writer.sh" "$1" --repo o/r "${@:2}"; }
rl() { "$SCRIPTS/review-ledger.sh" "$1" --repo o/r "${@:2}"; }
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r --no-blocker-check; }
has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }
# commit EMAIL DATE [MESSAGE] [COMMITTER_EMAIL]: one PR commit object.
commit() {
  jq -nc --arg a "$1" --arg d "$2" --arg m "${3:-change}" --arg c "${4:-$1}" \
    '{commit: {message: $m, author: {email: $a}, committer: {email: $c, date: $d}}}'
}
commits() { local n=$1; shift; printf '%s\n' "$@" | jq -s . >"$FX/commits-$n.json"; }
calls() { cat "$FX/calls" 2>/dev/null || true; }

@test "usage: mark needs --pr and --session; bad values are exit 2" {
  run rw mark --pr 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"mark needs --pr and --session"* ]]
  run rw mark --pr x --session t
  [ "$status" -eq 2 ]
  run rw mark --pr 5 --session 'two words'
  [ "$status" -eq 2 ]
  run rw check --issue y
  [ "$status" -eq 2 ]
  run rw nope
  [ "$status" -eq 2 ]
  run rw check --pr 5 -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: repair-writer.sh mark"* ]]
  [ -z "$(calls)" ]
}

@test "mark posts one REPAIR-START marker; a rerun posts nothing; unreadable or failed is typed" {
  echo '[]' >"$FX/comments-31.json"
  run rw mark --pr 31 --session trig_r --issue 5
  [ "$status" -eq 0 ]
  [ "$output" = "marked PR #31 session trig_r" ]
  [[ "$(cat "$FX/posted-31")" == "REPAIR-START session trig_r: a repair session now owns branch work/5-auto (issue #5)."* ]]
  has "$FX/posted-31" "<!-- waaagh:repairing pr=31 session=trig_r -->"
  # The marker is on the PR now: the same session again posts nothing.
  jq -n --rawfile b "$FX/posted-31" '[{body: "unrelated"}], [{body: $b}]' >"$FX/comments-31.json"
  run rw mark --pr 31 --session trig_r --issue 5
  [ "$status" -eq 0 ]
  [ "$output" = "already marked PR #31 session trig_r" ]
  [ "$(grep -c '^REPAIR-START' "$FX/posted-31")" -eq 1 ]
  # Another session is a new marker; with no issue it names the PR's branch.
  run rw mark --pr 31 --session trig_s
  [ "$status" -eq 0 ]
  [ "$(grep -c '^REPAIR-START session trig_s: a repair session now owns this PR' "$FX/posted-31")" -eq 1 ]
  # Comments unreadable: nothing posted, exit 7.
  run rw mark --pr 32 --session trig_r
  [ "$status" -eq 7 ]
  [[ "$output" == *"no marker posted"* ]]
  [ ! -e "$FX/posted-32" ]
  echo '{"message":"x"}' >"$FX/comments-32.json"
  run rw mark --pr 32 --session trig_r
  [ "$status" -eq 7 ]
  # The POST fails: exit 5, with the line to rerun.
  echo '[]' >"$FX/comments-32.json"
  touch "$FX/post-fails"
  run rw mark --pr 32 --session trig_r
  [ "$status" -eq 5 ]
  [[ "$output" == *"rerun repair-writer.sh mark --pr 32 --session trig_r"* ]]
}

@test "cloud-dispatch.sh record --kind repair posts the marker; a failed post is exit 10 with the rest kept" {
  echo '[]' >"$FX/comments-31.json"
  run cd_ record --issue 5 --kind repair --pr 31 --trigger trig_r --run-at 2026-09-27T12:01:20Z
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recorded 5 trig_r 2026-09-27T12:01:20Z repair" ]
  [ "${lines[2]}" = "marked PR #31 session trig_r" ]
  has "$FX/posted-31" "<!-- waaagh:repairing pr=31 session=trig_r -->"
  # The marker is not posted: the row and the repairing mark stand, exit 10 names the rerun.
  touch "$FX/post-fails"
  echo '[]' >"$FX/comments-32.json"
  run cd_ record --issue 6 --kind repair --pr 32 --trigger trig_s --run-at 2026-09-27T12:02:00Z
  [ "$status" -eq 10 ]
  [[ "$output" == *"PR #32 has no REPAIR-START marker; run repair-writer.sh mark --pr 32 --session trig_s --issue 6"* ]]
  [ "$(grep -c trig_s "$ST/cloud-sessions.tsv")" -eq 1 ]
  [ "$(rl inflight --pr 32 | cut -f2)" = trig_s ]
  # A plain dispatch posts nothing.
  : >"$FX/calls"
  run cd_ record --issue 7 --trigger trig_t --run-at 2026-09-27T12:03:00Z
  [ "$status" -eq 0 ]
  [ -z "$(calls)" ]
}

@test "check flags two writers or a force-push since the dispatch; clear and unknown otherwise" {
  export ORCHESTRATE_NOW=1790506800   # 2026-09-27T11:00:00Z
  for p in 5 6 7 8 9; do rl repair --pr "$p" --session "trig_$p" >/dev/null; done
  export ORCHESTRATE_NOW=1790510400
  # 5: the original author pushed after the repair session's commit; an older commit by a third
  # author and a GitHub update-branch merge do not count.
  commits 5 "$(commit old@x 2026-09-27T10:00:00Z)" "$(commit repair@x 2026-09-27T11:10:00Z)" \
    "$(commit orig@x 2026-09-27T11:20:00Z)" "$(commit me@x 2026-09-27T11:30:00Z merge noreply@github.com)"
  # 6: one identity, two Claude-Session trailers.
  commits 6 "$(commit me@x 2026-09-27T11:10:00Z $'fix\n\nClaude-Session: https://claude.ai/code/session_A')" \
    "$(commit me@x 2026-09-27T11:20:00Z $'fix\n\nClaude-Session: https://claude.ai/code/session_B')"
  # 7: one writer, then a force-push; 8: one writer with a trailer and no event since; 9 unreadable.
  commits 7 "$(commit me@x 2026-09-27T11:10:00Z)"
  commits 8 "$(commit me@x 2026-09-27T11:10:00Z $'fix\n\nClaude-Session: https://claude.ai/code/session_A')" \
    "$(commit me@x 2026-09-27T11:15:00Z $'fix 2\n\nClaude-Session: https://claude.ai/code/session_A')"
  for p in 5 6 8; do echo '[]' >"$FX/events-$p.json"; done
  jq -n '[{event: "head_ref_force_pushed", created_at: "2026-09-27T10:00:00Z"}],
    [{event: "head_ref_force_pushed", created_at: "2026-09-27T11:40:00Z"}, {event: "labeled", created_at: "2026-09-27T11:41:00Z"}]' >"$FX/events-7.json"
  run rw check
  [ "$status" -eq 7 ]
  [ "${lines[0]}" = "two-writers #5 session:trig_5 since:2026-09-27T11:00:00Z writers=orig@x,repair@x" ]
  [ "${lines[1]}" = "two-writers #6 session:trig_6 since:2026-09-27T11:00:00Z writers=session:session_A,session:session_B" ]
  [ "${lines[2]}" = "force-push #7 session:trig_7 at:2026-09-27T11:40:00Z" ]
  [ "${lines[3]}" = "clear #8 session:trig_8 commits=2" ]
  [ "${lines[4]}" = "unknown #9 session:trig_9 commits unreadable" ]
  commits 9 "$(commit me@x 2026-09-27T11:10:00Z)"
  run rw check --pr 9
  [ "$status" -eq 7 ]
  [ "$output" = "unknown #9 session:trig_9 events unreadable" ]
  echo '[]' >"$FX/events-9.json"
  : >"$FX/calls"
  run rw check --pr 9
  [ "$status" -eq 0 ]
  [ "$output" = "clear #9 session:trig_9 commits=1" ]
  [ "$(grep -c 'pulls/5/' "$FX/calls" || true)" -eq 0 ]
  # A repair that ended is not checked.
  rl repaired --pr 9 >/dev/null
  run rw check --pr 9
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "the triage tick reports a second writer on a PR under repair" {
  export ORCHESTRATE_NOW=1790506800
  rl repair --pr 5 --session trig_5 >/dev/null
  rl repair --pr 6 --session trig_6 >/dev/null
  export ORCHESTRATE_NOW=1790510400
  echo '[]' >"$FX/comments-5.json"
  echo '[]' >"$FX/comments-6.json"
  commits 5 "$(commit repair@x 2026-09-27T11:10:00Z)" "$(commit orig@x 2026-09-27T11:20:00Z)"
  commits 6 "$(commit repair@x 2026-09-27T11:10:00Z)"
  echo '[]' >"$FX/events-5.json"
  echo '[]' >"$FX/events-6.json"
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  required_snapshot_lines
  [[ "$(snap_line verdict)" == "verdict act "*"repair-writers=1"* ]]
  [ "$(snap_line repair-writers)" = "repair-writers two-writers #5 session:trig_5 since:2026-09-27T11:00:00Z writers=orig@x,repair@x" ]
  [ "$(grep -c '^repair-writers' <<<"$output" || true)" -eq 1 ]
}

@test "doctrine: the briefs stop at REPAIR-START; the marker and the check are documented (#214)" {
  B="$SCRIPTS/../briefs/implement.md"
  has "$B" '"REPAIR-START"'
  has "$B" "Never force-push."
  has "$SCRIPTS/../roles/cloud-dispatch.md" "repair-writer.sh"
  has "$SCRIPTS/../roles/triage-tick.md" "repair-writers=<n>"
  has "$SCRIPTS/../SKILL.md" "repair-writer.sh mark"
  has "$SCRIPTS/cloud-dispatch.sh" "repair-writer.sh mark"
  has "$ROOT/README.md" '`repair-writer.sh`'
}
