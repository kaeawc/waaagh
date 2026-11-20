#!/usr/bin/env bats
# Self-test for merge-queue.sh, recovery paths: main health refreshed each pass, a PR lagging the pushed
# head, the admin path, a lost merge answer, a retried item already merged, a transient lookup failure.
# Real git against a local bare origin, stubbed gh; setup in merge_queue_setup.bash.
# Run: bats scripts/merge-queue-recovery.bats

load merge_queue_setup

@test "main health is refreshed each pass: stale red is cleared by green evidence, fresh red stops the pass" {
  wt a
  enqueue a
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red old" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  echo '[{"workflowName":"CI","status":"completed","conclusion":"failure","headSha":"bbbbbbbbbbbb","databaseId":2,"createdAt":"2026-09-27T02:00:00Z"}]' >"$FX/runs.json"
  run mqr run-once
  [ "$status" -eq 4 ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/a.outcome" ]
  echo '[{"workflowName":"CI","status":"completed","conclusion":"success","headSha":"cccccccccccc","databaseId":3,"createdAt":"2026-09-27T03:00:00Z"}]' >"$FX/runs.json"
  run mqr run-once
  [ "$status" -eq 0 ]
  [[ "$output" == *"main: green ccccccccc"* ]]
  [ "$(outcome a)" = merged ]
}

@test "a PR that does not yet show the pushed head is waiting, then merges at the exact head" {
  wt a
  enqueue a
  echo 1111111111111111111111111111111111111111 >"$FX/stale-head"
  run mqr run-once
  [ "$(outcome a)" = waiting ]
  [[ "$output" == *"PR 5 shows head 111111111"* ]]
  rm "$FX/stale-head"
  run mqr run-once
  [ "$(outcome a)" = merged ]
  grep -q "match-head-commit $(git -C "$BATS_TEST_TMPDIR/a" rev-parse HEAD)" "$FX/calls"
}

@test "the admin path in the queue is limited to the named checks" {
  wt a
  enqueue a
  echo '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]' >"$FX/checks.json"
  export MERGE_QUEUE_ADMIN_EVIDENCE="sim: known flake" MERGE_QUEUE_ADMIN_CHECKS=sim ORCHESTRATE_FAST_PATH_OVER=0
  echo '[{"isResolved":false,"isOutdated":false}]' >"$FX/threads.json"
  run mqr run-once
  [ "$(outcome a)" = blocked ]
  run ! grep -q 'pr merge' "$FX/calls"
  echo '[]' >"$FX/threads.json"
  mqr retry a
  run mqr run-once
  [ "$(outcome a)" = merged ]
  grep -q -- '--admin' "$FX/calls"
}

@test "a merge whose answer was lost is confirmed on the next pass, without a new push, PR or merge" {
  wt a
  wt b
  enqueue a
  enqueue b a
  echo no-readback >"$FX/merge-mode"
  run mqr run-once
  [ "$(outcome a)" = waiting ]
  [[ "$output" == *"merge outcome unknown"* ]]
  [[ "$output" == *"b: blocked on a"* ]]
  rm "$FX/merge-mode"; : >"$FX/calls"
  run mqr run-once
  [ "$(outcome a)" = merged ]
  [[ "$output" == *"a: merged (PR 5 (confirmed on re-check))"* ]]
  [ "$(outcome b)" = merged ]
  # a needed one read; the only merge in this pass was b's.
  [ "$(grep -c 'pr merge' "$FX/calls")" -eq 1 ]
}

@test "a retried item whose PR was already merged at that head is confirmed, not reopened" {
  wt a
  enqueue a
  MERGE_QUEUE_CHECK_CMD='exit 1' run mqr run-once
  [ "$(outcome a)" = checkfail ]
  git -C "$BATS_TEST_TMPDIR/a" push -q origin a
  # Someone merged it meanwhile: no open PR, a merged one at this exact head.
  jq -n --arg h "$(git -C "$BATS_TEST_TMPDIR/a" rev-parse HEAD)" '[{number: 9, headRefOid: $h}]' >"$FX/merged-prs.json"
  echo '[]' >"$FX/open-override"
  mqr retry a
  sed -i.bak 's/^  "pr list"\*--head\*) /  "pr list"*--head*) [ -f "$FX\/open-override" ] \&\& { cat "$FX\/open-override"; exit 0; }; /' "$BATS_TEST_TMPDIR/bin/gh"
  run mqr run-once
  [ "$(outcome a)" = merged ]
  [[ "$output" == *"PR 9 (already merged at"* ]]
  run ! grep -q 'pr create' "$FX/calls"
  ! grep -q 'pr merge' "$FX/calls"
}

@test "a transient lookup failure parks one item as waiting and the pass goes on" {
  wt a
  wt b
  enqueue a
  enqueue b
  touch "$FX/list-fails-a"
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [[ "$output" == *"a: waiting (PR lookup failed (transient))"* ]]
  [ "$(outcome b)" = merged ]
  rm "$FX/list-fails-a"
  run mqr run-once
  [ "$(outcome a)" = merged ]
}
