#!/usr/bin/env bats
# The internal review verdict as a merge gate (#206): review-ledger.sh records the orchestrator's
# own review verdicts; the latest one, when it is not ship, holds the PR on every merge path
# (pr-ready.sh SKIP review:<verdict>, pr-merge.sh exit 14, merge-queue.sh `held`) until a newer
# ship row. A non-ship verdict and the start of a fix pass also add a hold.sh hold (until
# review-ship), and a ship verdict releases it. The gate is one helper, orch_review_hold_of.
# Real git against a local bare origin, stubbed gh. Run: bats scripts/review-holds.bats

setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  load selftest_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE MERGE_QUEUE_ADMIN_CHECKS ORCHESTRATE_DIRECT_MERGE \
    ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_GENERATED_FILES ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE
  seed_origin_copy
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  Q="$ST/merge-queue"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # The shared merge-path gh stub (selftest_helper.bash, #233); its fixture switches are documented there.
  stub_gh_merge_path
  echo body >"$BATS_TEST_TMPDIR/body.md"
}

wt() {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/$1" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/$1" switch -q -c "$1"
  echo "$1" >"$BATS_TEST_TMPDIR/$1/$1.txt"
  git -C "$BATS_TEST_TMPDIR/$1" add -A
  git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$1"
}
rl() { "$SCRIPTS/review-ledger.sh" "$1" --repo o/r "${@:2}"; }
hold() { "$SCRIPTS/hold.sh" "$1" --repo o/r "${@:2}"; }
mq() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }
enqueue() { mq add --id "$1" --worktree "$BATS_TEST_TMPDIR/$1" --branch "$1" --title "t $1" --body-file "$BATS_TEST_TMPDIR/body.md" >/dev/null; }
outcome() { sed -n 1p "$Q/$1.outcome"; }
reason() { sed -n 2p "$Q/$1.outcome"; }
calls() { grep -c "^$1" "$FX/calls" 2>/dev/null || true; }
gate() { run bash -c 'source "$1/_lib.sh"; orch_review_hold_of o/r "$2"' _ "$SCRIPTS" "$1"; }
pushed_pr() {
  wt a
  git -C "$BATS_TEST_TMPDIR/a" push -q origin a
  echo a >"$FX/branch"
  HEAD=$(git -C "$BATS_TEST_TMPDIR/a" rev-parse HEAD)
}
pm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 5 --head "$HEAD" "$@"; }

@test "review-ledger.sh: usage errors are exit 2; latest of a PR with no verdict is exit 3" {
  run rl record --pr 5 --verdict maybe
  [ "$status" -eq 2 ]
  [[ "$output" == *"--verdict must be ship, fix-first or rethink"* ]]
  run rl record --verdict ship
  [ "$status" -eq 2 ]
  run rl list --pr x
  [ "$status" -eq 2 ]
  run rl latest --pr 5 --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPTS/review-ledger.sh" frobnicate
  [ "$status" -eq 2 ]
  run rl latest --pr 5
  [ "$status" -eq 3 ]
  [ "$output" = "no verdict: PR 5 has no internal review recorded" ]
  run rl blocked
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "fix-first holds the PR until review-ship; a newer ship row releases the hold and the gate" {
  run rl record --pr 5 --verdict fix-first --head abc123 --note $'two\tblockers'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recorded: PR 5 fix-first at abc123" ]
  [ "${lines[1]}" = "held: PR 5 until:review-ship" ]
  grep -qx '5 until:review-ship since:2026-09-27T12:00:00Z review fix-first: two blockers' "$ST/holds"
  [ "$(cat "$ST/reviews.tsv")" = $'2026-09-27T12:00:00Z\t5\tfix-first\tabc123\ttwo blockers' ]
  run rl latest --pr '#5'
  [ "$output" = $'2026-09-27T12:00:00Z\t5\tfix-first\tabc123\ttwo blockers' ]
  gate 5
  [ "$status" -eq 0 ]
  [ "$output" = "#5 review:fix-first since:2026-09-27T12:00:00Z head:abc123 two blockers" ]
  run rl blocked
  [ "$output" = $'5\tfix-first' ]
  # The fix pass starts on a PR already held: the hold stays, the row still gates.
  run rl fix --pr 5
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "already held: #5 until:review-ship since:2026-09-27T12:00:00Z review fix-first: two blockers (kept; the verdict holds it too)" ]
  run rl blocked
  [ "$output" = $'5\tfixing' ]
  run rl record --pr 5 --verdict ship --head def456
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "released: PR 5 (until:review-ship, held 0h)" ]
  [ ! -s "$ST/holds" ]
  grep -q $'pr=5\treleased until:review-ship .* note=review ship at def456' "$ST/holds.log"
  gate 5
  [ "$status" -eq 1 ]
  run rl blocked
  [ "$output" = "" ]
  run rl list --pr 5
  [ "${#lines[@]}" -eq 3 ]
}

@test "starting a fix pass holds a PR with no verdict; another hold's condition is never replaced" {
  run rl fix --pr 8 --note "bot findings"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "recorded: PR 8 fixing" ]
  grep -qx '8 until:review-ship since:2026-09-27T12:00:00Z review fixing: bot findings' "$ST/holds"
  # PR 9 waits for a device recheck: a non-ship verdict keeps that hold, ship does not release it.
  hold add --pr 9 --until device-recheck --reason "device run" >/dev/null
  run rl record --pr 9 --verdict rethink
  [[ "$output" == *"already held: #9 until:device-recheck"* ]]
  run rl record --pr 9 --verdict ship
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "still held: #9 until:device-recheck since:2026-09-27T12:00:00Z device run" ]
  grep -q '^9 until:device-recheck' "$ST/holds"
  # Ship on a PR nobody held: only the row.
  run rl record --pr 10 --verdict ship
  [ "$output" = "recorded: PR 10 ship" ]
  gate 10
  [ "$status" -eq 1 ]
  gate 11
  [ "$status" -eq 1 ]
}

@test "orch_review_hold_of: an unreadable ledger is exit 4, so the gate says 2; review-ledger.sh fails closed on hold-file errors" {
  rl record --pr 5 --verdict fix-first >/dev/null
  mv "$ST/reviews.tsv" "$ST/rows"; mkdir "$ST/reviews.tsv"
  run rl latest --pr 5
  [ "$status" -eq 4 ]
  [[ "$output" == *"could not read"*"reviews.tsv"* ]]
  gate 5
  [ "$status" -eq 2 ]
  rmdir "$ST/reviews.tsv"; mv "$ST/rows" "$ST/reviews.tsv"
  # A hold file another writer has locked: the row is written (it gates), the hold add fails.
  mkdir "$ST/holds.lock"
  run rl record --pr 6 --verdict fix-first
  [ "$status" -eq 5 ]
  [ "$(rl latest --pr 6 | cut -f3)" = fix-first ]
  rmdir "$ST/holds.lock"
}

@test "hold.sh check: until:review-ship is met only once the latest verdict is ship" {
  hold add --pr 5 --until review-ship >/dev/null
  run hold check
  [ "$output" = "#5 unmet until:review-ship no review recorded" ]
  rl record --pr 5 --verdict fix-first >/dev/null
  run hold check --pr 5
  [ "$output" = "#5 unmet until:review-ship latest review: fix-first" ]
  # Appended by hand so the hold stays and check is what releases it.
  printf '2026-09-27T12:00:00Z\t5\tship\t-\t-\n' >>"$ST/reviews.tsv"
  run hold check --release
  [ "${lines[0]}" = "#5 met until:review-ship latest review: ship" ]
  [[ "${lines[1]}" == "released: PR 5"* ]]
  run hold add --pr 6 --until review-shipped
  [ "$status" -eq 2 ]
  [[ "$output" == *"review-ship"* ]]
}

@test "hold.sh check: an unreadable review ledger leaves a review-ship hold unknown" {
  hold add --pr 5 --until review-ship >/dev/null
  mkdir "$ST/reviews.tsv"
  run hold check
  [ "$output" = "#5 unknown until:review-ship the review ledger could not be read" ]
}

@test "pr-merge.sh: a non-ship latest verdict is exit 14 in every mode, even with the hold released" {
  pushed_pr
  rl record --pr 5 --verdict fix-first --head "${HEAD:0:9}" >/dev/null
  hold release --pr 5 >/dev/null
  : >"$FX/calls"
  pm
  [ "$status" -eq 14 ]
  [ "$output" = "held: PR 5's latest internal review is not ship (#5 review:fix-first since:2026-09-27T12:00:00Z head:${HEAD:0:9} -); a newer ship verdict (review-ledger.sh record) clears it" ]
  grep -q $'\trefused held: #5 review:fix-first' "$ST/merges.log"
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 14 ]
  ORCHESTRATE_ADMIN_MERGE=1 pm --admin --evidence "sim: flake" --except-check sim
  [ "$status" -eq 14 ]
  [ ! -s "$FX/calls" ]
  rl record --pr 5 --verdict ship >/dev/null
  pm
  [ "$status" -eq 0 ]
  [ "$output" = "merged 5 feedface" ]
}

@test "pr-merge.sh: a fix pass recorded while the gates ran still stops the merge; an unreadable ledger is exit 9" {
  pushed_pr
  echo 5 >"$FX/review-on-view"
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 14 ]
  [[ "$output" == *"#5 review:fixing since:"*"fix lane started"* ]]
  [ "$(calls 'pr merge')" -eq 0 ]
  rm "$ST/reviews.tsv"; mkdir "$ST/reviews.tsv"
  pm
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: the review ledger could not be read (review-ledger.sh latest); nothing was attempted" ]
}

@test "merge-queue: a PR held by its review is parked held, and a ship verdict resumes it" {
  wt a
  wt b
  echo 7 >"$FX/num-a"
  enqueue a
  enqueue b
  printf '2026-09-27T12:00:00Z\t7\tfix-first\t-\tblocker\n' >"$ST/reviews.tsv"
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = held ]
  [ "$(reason a)" = "PR 7 is held by its review: #7 review:fix-first since:2026-09-27T12:00:00Z head:- blocker; a newer ship verdict (review-ledger.sh record) clears it" ]
  [ "$(outcome b)" = merged ]
  [ "$(calls 'pr merge 7')" -eq 0 ]
  rl record --pr 7 --verdict ship >/dev/null
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = merged ]
  [ "$(calls 'pr merge 7')" -eq 1 ]
}

@test "merge-queue: pr-merge.sh exit 14 from a review recorded mid-merge is the held outcome" {
  wt a
  enqueue a
  echo 5 >"$FX/review-on-view"
  ORCHESTRATE_DIRECT_MERGE=1 run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = held ]
  [[ "$(reason a)" == "PR 5 is held by its review: #5 review:fixing "* ]]
}

@test "pr-ready.sh skips a PR whose latest verdict is not ship as review:<verdict>, ready-but-skipped" {
  pushed_pr
  printf '2026-09-27T12:00:00Z\t5\tfix-first\t-\t-\n' >"$ST/reviews.tsv"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'5\tSKIP\t'*$'\treview:fix-first ready-but-skipped'* ]]
  [[ "$output" == *"skipped-by=review:1"* ]]
  printf '2026-09-27T13:00:00Z\t5\tship\t-\t-\n' >>"$ST/reviews.tsv"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'5\tREADY\t'* ]]
}

@test "doctrine: the verdict gate and the open-PR push check are written where lanes read them" {
  [[ "$(cat "$SCRIPTS/pr-merge.sh")" == *"latest internal review verdict (review-ledger.sh)"* ]]
  [[ "$(cat "$ROOT/SKILL.md")" == *'review-ledger.sh" record --pr N --verdict'* ]]
  [[ "$(cat "$ROOT/SKILL.md")" == *'review-ledger.sh" fix --pr N'* ]]
  [[ "$(cat "$ROOT/roles/pr-doctor.md")" == *"review-ledger.sh fix --repo {{REPO}} --pr"* ]]
  [[ "$(cat "$ROOT/roles/_common.md")" == *"claim-check.sh open"*"--pr <n>"* ]]
  [[ "$(cat "$ROOT/roles/merge-bot.md")" == *"review:"* ]]
  [[ "$(cat "$ROOT/../../README.md")" == *"review-ledger.sh"* ]]
}
