#!/usr/bin/env bats
# Self-test for merge-queue.sh: real git against a local bare origin, stubbed gh. Ordering, dependencies,
# conflicts, check failures and pacing; recovery paths are in merge-queue-recovery.bats.
# Run: bats scripts/merge-queue.bats

load merge_queue_setup

@test "add rejects a duplicate id and leaves one row" {
  wt a
  enqueue a
  run enqueue a
  [ "$status" -eq 3 ]
  [[ "$output" == *"already queued"* ]]
  [ "$(wc -l <"$ORCHESTRATE_STATE_DIR/o__r/merge-queue/queue.tsv" | tr -d ' ')" = 1 ]
}

@test "run-once merges a clean item through pr-merge and records outcome merged" {
  wt a
  enqueue a
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = merged ]
  grep -q "pr merge 5 --repo o/r --squash --match-head-commit $(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/a)$" "$FX/calls"
  git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/a
}

@test "paced pushes (#219): the cap and gap leave later items waiting, unpushed, for a later pass" {
  wt a
  wt b
  enqueue a
  enqueue b
  export ORCHESTRATE_UPDATE_CAP=1 ORCHESTRATE_UPDATE_GAP=600
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = merged ]
  [ "$(outcome b)" = waiting ]
  [[ "$output" == *"b: waiting (update paced (cap: 1 of 1 updates made this pass); a later pass pushes it)"* ]]
  run ! git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/b
  [ "$(cut -f2,3 "$ORCHESTRATE_STATE_DIR/o__r/branch-updates.log")" = $'-\tmerge-queue' ]
  # a new pass inside the gap: still paced
  run mqr run-once
  [[ "$output" == *"b: waiting (update paced (gap: last update (PR -) 0s ago"* ]]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 600)) run mqr run-once
  [ "$(outcome b)" = merged ]
}

@test "a conflict records outcome conflict, is not done, and blocks its dependent" {
  wt a f.txt left
  git -C "$BATS_TEST_TMPDIR/seed" switch -q main 2>/dev/null || true
  echo right >"$BATS_TEST_TMPDIR/seed/f.txt"
  git -C "$BATS_TEST_TMPDIR/seed" commit -qam right
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
  wt b
  enqueue a
  enqueue b a
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = conflict ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/b.outcome" ]
  [[ "$output" == *"b: blocked on a"* ]]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/a" status --porcelain)" ]
  run ! grep -q 'pr merge' "$FX/calls"
  run mqr status
  [[ "$output" == *$'a\tconflict\ta'* ]]
  [[ "$output" == *$'b\tblocked:a\tb'* ]]
  # a second pass does not silently skip or re-run the parked item
  run mqr run-once
  [ "$(outcome a)" = conflict ]
}

@test "a failing check records checkfail and nothing is pushed" {
  wt a
  enqueue a
  MERGE_QUEUE_CHECK_CMD='exit 1' run mqr run-once
  [ "$(outcome a)" = checkfail ]
  ! git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/a
}

@test "retry re-arms a non-merged item, which then merges and releases its dependent" {
  wt a
  wt b
  enqueue a
  enqueue b a
  MERGE_QUEUE_CHECK_CMD='exit 1' run mqr run-once
  [ "$(outcome a)" = checkfail ]
  run mqr retry a
  [ "$status" -eq 0 ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/a.outcome" ]
  run mqr run-once
  [ "$(outcome a)" = merged ]
  [ "$(outcome b)" = merged ]
  run mqr retry a
  [ "$status" -eq 3 ]
}

@test "items run in file order and a dependent waits for its requirement" {
  wt a
  wt b
  wt c
  enqueue c
  enqueue b c
  enqueue a b
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome c)" = merged ]
  [ "$(outcome b)" = merged ]
  [ "$(outcome a)" = merged ]
  # the first PR lookup per item marks the order it was processed in
  [ "$(awk '!seen[$0]++' "$FX/order" | tr '\n' ' ')" = "c b a " ]
}

@test "a dependency queued after its dependent merges first and releases the dependent next pass" {
  wt a
  wt b
  enqueue a b
  enqueue b
  run mqr run-once
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/a.outcome" ]
  [ "$(outcome b)" = merged ]
  run mqr run-once
  [ "$(outcome a)" = merged ]
}

@test "parent of name-2 is the bare name, not name-1" {
  [ "$("$SCRIPTS/merge-queue.sh" parent feat-2)" = feat ]
  [ "$("$SCRIPTS/merge-queue.sh" parent feat-3)" = feat-2 ]
  [ "$("$SCRIPTS/merge-queue.sh" parent feat-10)" = feat-9 ]
  [ -z "$("$SCRIPTS/merge-queue.sh" parent feat)" ]
  [ -z "$("$SCRIPTS/merge-queue.sh" parent feat-1)" ]
}

@test "--requires auto resolves the queued parent branch and refuses when none is queued" {
  wt feat
  wt feat-2
  enqueue feat
  run mq add --id feat-2 --worktree "$BATS_TEST_TMPDIR/feat-2" --branch feat-2 --title t \
    --body-file "$BATS_TEST_TMPDIR/body.md" --requires auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires feat)"* ]]
  run mq add --id x --worktree w --branch other-3 --title t --body-file b --requires auto
  [ "$status" -eq 3 ]
}

@test "a red default branch stops the pass without writing an outcome" {
  wt a
  enqueue a
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red abc" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  run mqr run-once
  [ "$status" -eq 4 ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/a.outcome" ]
}

@test "pending checks leave the item waiting; the next pass resumes it without redoing the merge, check or push" {
  wt a
  wt b
  enqueue a
  enqueue b a
  echo '[{"name":"build","status":"IN_PROGRESS"}]' >"$FX/checks.json"
  export MERGE_QUEUE_CHECK_CMD='echo ran >>"$FX/check-runs"'
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [[ "$output" == *"a: waiting (PR 5: pending:build)"* ]]
  [[ "$output" == *"b: blocked on a"* ]]
  run ! grep -q 'pr merge' "$FX/calls"
  run mqr status
  [[ "$output" == *$'a\twaiting\ta'* ]]
  # Checks finish: the item resumes and merges; the check command is not run again.
  echo '[{"name":"build","conclusion":"SUCCESS"}]' >"$FX/checks.json"
  run mqr run-once
  [ "$(outcome a)" = merged ]
  [ "$(outcome b)" = merged ]
  [ "$(grep -c ran "$FX/check-runs")" -eq 2 ]   # once for a (first pass), once for b
  grep -q 'resuming at' "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/logs/a.log"
}

@test "unreported checks and unknown mergeability are waiting, not merged, on a server that would accept" {
  wt a
  enqueue a
  echo '[]' >"$FX/checks.json"
  run mqr run-once
  [ "$(outcome a)" = waiting ]
  echo '[{"name":"build","conclusion":"SUCCESS"}]' >"$FX/checks.json"
  echo UNKNOWN >"$FX/mergeable"
  run mqr run-once
  [ "$(outcome a)" = waiting ]
  run ! grep -q 'pr merge' "$FX/calls"
  echo MERGEABLE >"$FX/mergeable"
  run mqr run-once
  [ "$(outcome a)" = merged ]
}

@test "a review thread or a failed check blocks the item until retry, and nothing is merged" {
  wt a
  enqueue a
  echo '[{"isResolved":false,"isOutdated":false}]' >"$FX/threads.json"
  run mqr run-once
  [ "$(outcome a)" = blocked ]
  [[ "$output" == *"threads=1"* ]]
  echo '[]' >"$FX/threads.json"
  run mqr run-once
  [ "$(outcome a)" = blocked ]   # parked: a second pass does not pick it up
  echo '[{"name":"build","conclusion":"FAILURE"}]' >"$FX/checks.json"
  mqr retry a
  run mqr run-once
  [ "$(outcome a)" = blocked ]
  [[ "$output" == *"fail:build"* ]]
  ! grep -q 'pr merge' "$FX/calls"
}
