#!/usr/bin/env bats
# merge-queue.sh dependencies and order: file order, --requires (named and auto), retry of a
# non-merged item and what it releases. Split from merge-queue.bats for a shorter parallel run
# (#112); setup and helpers: merge_queue_setup.bash. Real git against a local bare origin, stubbed
# gh. Run: bats scripts/merge-queue-deps.bats

load merge_queue_setup

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
