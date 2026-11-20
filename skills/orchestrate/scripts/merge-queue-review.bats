#!/usr/bin/env bats
# merge-queue.sh on pr-merge.sh exit 13 (a bot review is required): one request per head, through
# review-gate.sh's throttle, never to an out-of-quota bot, a wait for an automatic review, and a failed
# request asked again. Real git against a local bare origin, stubbed gh; setup in
# merge_queue_gaps_setup.bash. Run: bats scripts/merge-queue-review.bats

load merge_queue_gaps_setup

# review_comments: how many review requests (`gh pr comment`) the queue posted.
review_comments() { grep -c '^pr comment' "$FX/calls" || true; }
review_policy() { mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo review-at-head >"$ORCHESTRATE_STATE_DIR/o__r/review-policy"; }
WHY="waiting for a bot review (review-gate.sh policy)"

@test "exit 13 asks for one bot review per head, not per pass; a throttled ask names the next window" {
  review_policy
  wt a
  enqueue a
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [ "$(reason a)" = "$WHY: review requested from claude" ]
  [ "$(review_comments)" -eq 1 ]
  grep -q '^pr comment 5 --repo o/r --body @claude review$' "$FX/calls"
  # Two more passes at the same head: no second request, even once the window has reopened.
  run mq run-once
  ORCHESTRATE_NOW=1790520000 run mq run-once
  [ "$status" -eq 0 ]
  [ "$(review_comments)" -eq 1 ]
  [ "$(reason a)" = "$WHY: review requested from claude" ]
  # A new head asks again, but the bot's window (last request at 12:00, every 1200 s) is shut.
  echo more >"$BATS_TEST_TMPDIR/a/a.txt"
  git -C "$BATS_TEST_TMPDIR/a" commit -qam more
  ORCHESTRATE_NOW=1790510500 run mq run-once
  [ "$status" -eq 0 ]
  [ "$(reason a)" = "$WHY: review throttled until 2026-09-27T12:20:00Z (claude)" ]
  [ "$(review_comments)" -eq 1 ]
  # Still shut: the next pass only drains, so the PR is not re-queued behind itself.
  ORCHESTRATE_NOW=1790510600 run mq run-once
  [ "$(review_comments)" -eq 1 ]
  [ "$(wc -l <"$ORCHESTRATE_STATE_DIR/o__r/review-queue/claude.tsv" | tr -d ' ')" -eq 1 ]
  [ "$(grep -c 'review-gate.sh request --pr 5:' "$Q/logs/a.log" || true)" -eq 2 ]  # first head, new head
  [ "$(grep -c 'review-gate.sh request --bot claude:' "$Q/logs/a.log" || true)" -eq 1 ]
  # Window open: the queued request is posted once, and only once.
  ORCHESTRATE_NOW=1790511600 run mq run-once
  [ "$(reason a)" = "$WHY: review requested from claude" ]
  ORCHESTRATE_NOW=1790520000 run mq run-once
  [ "$(review_comments)" -eq 2 ]
}

@test "exit 13 never asks an out-of-quota bot: nothing is posted or queued" {
  review_policy
  "$SCRIPTS/review-gate.sh" notice --repo o/r --author "claude[bot]" <<<"⚠️ Code review skipped: o has reached its monthly code review spending cap" >/dev/null
  wt a
  enqueue a
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [ "$(reason a)" = "$WHY: no review requested: the review bot is out of quota" ]
  [ "$(review_comments)" -eq 0 ]
  run test -e "$ORCHESTRATE_STATE_DIR/o__r/review-queue/claude.tsv"
  [ "$status" -ne 0 ]
}

@test "exit 13 with no request phrase waits for an automatic review, once per head" {
  review_policy
  export ORCHESTRATE_REVIEW_TRIGGER=
  wt a
  enqueue a
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [ "$(reason a)" = "$WHY: waiting for an automatic review from claude" ]
  run mq run-once
  [ "$(reason a)" = "$WHY: waiting for an automatic review from claude" ]
  [ "$(review_comments)" -eq 0 ]
  [ "$(grep -c 'review-gate.sh request' "$Q/logs/a.log" || true)" -eq 1 ]
}

@test "exit 13 with a failed review request stays waiting and asks again next pass" {
  review_policy
  touch "$FX/comment-fails"
  wt a
  enqueue a
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [[ "$(reason a)" == "$WHY: review request failed (exit 5), see "* ]]
  rm "$FX/comment-fails"
  run mq run-once
  [ "$(reason a)" = "$WHY: review requested from claude" ]
  [ "$(review_comments)" -eq 2 ]
}
