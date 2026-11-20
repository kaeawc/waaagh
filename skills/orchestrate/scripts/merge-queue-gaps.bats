#!/usr/bin/env bats
# merge-queue.sh paths merge-queue.bats does not reach: every pr-merge.sh exit code mapped to a queue
# outcome (driven through the real pr-merge.sh), the base-merge and PR lookup/create failure arms, a
# dirty worktree, an unreadable known PR, a SKIP readiness row, status/retry edge cases and a waiting
# front over drift. The bot-review request on exit 13 is in merge-queue-review.bats.
# Real git against a local bare origin, stubbed gh. Run: bats scripts/merge-queue-gaps.bats

load merge_queue_gaps_setup

@test "every pr-merge.sh exit code maps to its queue outcome" {
  # case | pr-merge exit | outcome | reason substring
  while IFS='|' read -r name rc want why; do
    reset_fx
    rm -rf "$ORCHESTRATE_STATE_DIR"
    unset MERGE_QUEUE_ADMIN_EVIDENCE MERGE_QUEUE_ADMIN_CHECKS ORCHESTRATE_MERGE_SENSITIVE
    case "$name" in
      admin-refused) # BLOCK on an admin-listed check, but not the fast path: pr-merge exit 6
        echo '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]' >"$FX/checks.json"
        export MERGE_QUEUE_ADMIN_EVIDENCE="sim: known flake" MERGE_QUEUE_ADMIN_CHECKS=sim ;;
      not-ready) # READY for the queue, BLOCK on pr-merge's own fresh row: exit 7
        echo '[{"name":"build","conclusion":"FAILURE"}]' >"$FX/checks-2.json" ;;
      queued) echo queued >"$FX/merge-mode" ;;                       # exit 8
      pending) echo 5xx >"$FX/merge-mode" ;;                         # exit 10, no outage
      stale) export ORCHESTRATE_MERGE_SENSITIVE='*.txt' ;;           # exit 11
      busy) export ORCHESTRATE_MERGE_SENSITIVE='*.txt'                # exit 12
        d="$ORCHESTRATE_STATE_DIR/o__r/locks/sensitive-$(printf '%s' '*.txt' | cksum | cut -d' ' -f1)"
        mkdir -p "$d"; echo 99 >"$d/pr"; echo "$ORCHESTRATE_NOW" >"$d/at" ;;
      review) mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"                  # exit 13
        echo review-at-head >"$ORCHESTRATE_STATE_DIR/o__r/review-policy" ;;
      rejected) echo reject >"$FX/merge-mode" ;;                     # exit 5: not mapped
    esac
    id="i-$name"
    wt "$id"
    enqueue "$id"
    run mq run-once
    [ "$status" -eq 0 ] || { echo "$name: exit $status: $output"; return 1; }
    got=$(outcome "$id")
    [ "$got" = "$want" ] || { echo "$name: outcome $got, want $want ($(reason "$id"))"; return 1; }
    [[ "$(reason "$id")" == *"$why"* ]] || { echo "$name: reason '$(reason "$id")' lacks '$why'"; return 1; }
    [[ "$output" == *"$id: $want ("* ]] || { echo "$name: output $output"; return 1; }
    grep -q '^pr merge' "$FX/calls" && merged_called=yes || merged_called=no
    case "$rc" in
      6 | 7 | 11 | 12 | 13) [ "$merged_called" = no ] || { echo "$name: gh pr merge ran"; return 1; } ;;
      8 | 10 | 5) [ "$merged_called" = yes ] || { echo "$name: gh pr merge did not run"; return 1; } ;;
    esac
  done <<'CASES'
admin-refused|6|blocked|admin merge refused
not-ready|7|waiting|pr-merge found it not ready
queued|8|waiting|merge queued on GitHub
pending|10|waiting|merge pending on GitHub
stale|11|waiting|base moved past a merge-sensitive path
busy|12|waiting|another merge holds a merge-sensitive path lock
review|13|waiting|waiting for a bot review
rejected|5|error|pr-merge exit 5
CASES
}

@test "a pending merge during a Pull Requests outage parks the item and stops the pass" {
  jq -n '{components: [{name: "Pull Requests", status: "major_outage", group: false}]}' >"$BATS_TEST_TMPDIR/githubstatus.json"
  echo 5xx >"$FX/merge-mode"
  wt a
  wt b
  enqueue a
  enqueue b
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [[ "$output" == *"paused: GitHub outage; pass stopped"* ]]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/GITHUB_OUTAGE" ]
  [ ! -f "$Q/b.outcome" ]
  [ "$(grep -c '^pr merge' "$FX/calls")" -eq 1 ]
}

@test "base-merge failures: a generated file that does not regenerate is conflict, any other failure is error" {
  # Generated-file conflict whose regenerate command fails: regen-merge.sh exit 5.
  wt a f.txt left
  enqueue a
  main_moves f.txt right
  printf 'f.txt\tfalse\n' >"$BATS_TEST_TMPDIR/gen.tsv"
  ORCHESTRATE_GENERATED_FILES="$BATS_TEST_TMPDIR/gen.tsv" run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = conflict ]
  [[ "$(reason a)" == "generated files did not regenerate cleanly"* ]]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/a" status --porcelain)" ]
  # A clean merge whose commit fails (a refusing commit-msg hook): regen-merge.sh exits 1.
  wt b
  main_moves g.txt other
  mkdir -p "$BATS_TEST_TMPDIR/hooks"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/hooks/commit-msg"
  chmod +x "$BATS_TEST_TMPDIR/hooks/commit-msg"
  git -C "$BATS_TEST_TMPDIR/b" config core.hooksPath "$BATS_TEST_TMPDIR/hooks"
  enqueue b
  run mq run-once
  [ "$(outcome b)" = error ]
  [[ "$(reason b)" == "base merge failed"* ]]
  ! grep -q '^pr ' "$FX/calls"
}

@test "a dirty worktree, or one on another branch, is an error and nothing is pushed" {
  wt a
  enqueue a
  echo junk >"$BATS_TEST_TMPDIR/a/untracked.txt"
  run mq run-once
  [ "$(outcome a)" = error ]
  [[ "$(reason a)" == "worktree dirty or not on a" ]]
  run ! git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/a
  rm "$BATS_TEST_TMPDIR/a/untracked.txt"
  git -C "$BATS_TEST_TMPDIR/a" switch -q -c elsewhere
  mq retry a >/dev/null
  run mq run-once
  [ "$(outcome a)" = error ]
}

@test "an item whose known PR cannot be read stays waiting and does nothing else" {
  wt a
  enqueue a
  mkdir -p "$Q"; echo 5 >"$Q/a.pr"
  echo 99 >"$FX/view-fails"
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [[ "$(reason a)" == "PR 5 unreadable (transient); will re-check" ]]
  run ! grep -qE '^pr (list|create|merge)' "$FX/calls"
  ! git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/a
}

@test "PR lookup and create failures: merged-list unreadable is waiting, a create that opened nothing is error" {
  wt a
  enqueue a
  touch "$FX/open-empty" "$FX/merged-list-fails"
  run mq run-once
  [ "$(outcome a)" = waiting ]
  [[ "$(reason a)" == "PR lookup failed (transient)" ]]
  run ! grep -q '^pr create' "$FX/calls"
  rm "$FX/merged-list-fails"
  touch "$FX/create-fails"
  run mq run-once
  [ "$(outcome a)" = error ]
  [[ "$(reason a)" == "pr create failed, see "* ]]
  grep -q '^pr create --repo o/r --head a --base main --title t a' "$FX/calls"
  grep -q 'pr create failed; checking whether it was created anyway' "$Q/logs/a.log"
  ! grep -q '^pr merge' "$FX/calls"
}

@test "a readiness verdict other than READY, WAIT or BLOCK parks the item as blocked" {
  wt a
  enqueue a
  echo '[{"name":"hold"}]' >"$FX/labels.json"
  run mq run-once
  [ "$(outcome a)" = blocked ]
  [[ "$(reason a)" == "PR 5: SKIP hold"* ]]
  ! grep -q '^pr merge' "$FX/calls"
}

@test "status lists outcomes, pending and unmet dependencies; retry of an item with no outcome is a no-op" {
  wt a
  wt b
  wt c
  enqueue a
  mq add --id b --worktree "$BATS_TEST_TMPDIR/b" --branch b --title t --body-file "$BATS_TEST_TMPDIR/body.md" --requires a >/dev/null
  enqueue c
  printf 'checkfail\nsee log\n' >"$Q/c.outcome"
  run mq status
  [ "$status" -eq 0 ]
  [ "$output" = $'a\tpending\ta\nb\tblocked:a\tb\nc\tcheckfail\tc' ]
  run mq retry a
  [ "$status" -eq 0 ]
  [ "$output" = "a has no outcome; nothing to retry" ]
  [ ! -f "$Q/a.outcome" ]
}

@test "a waiting front resumes over unrelated drift; a manifest move or MERGE_QUEUE_UPDATE_BEHIND=always merges main in (#204)" {
  echo '[{"name":"build","status":"IN_PROGRESS"}]' >"$FX/checks.json"
  wt a
  enqueue a
  run mq run-once
  [ "$(outcome a)" = waiting ]
  first=$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/a)
  main_moves docs.txt x
  run mq run-once
  [ "$(outcome a)" = waiting ]
  [ "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/a)" = "$first" ]
  grep -q "a: resuming at ${first:0:9}: main moved, but over no protected path" "$Q/logs/a.log"
  main_moves package.json '{}'
  run mq run-once
  second=$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/a)
  [ "$second" != "$first" ]
  grep -q "a: main moved over protected package.json; merging it in" "$Q/logs/a.log"
  main_moves docs.txt y
  MERGE_QUEUE_UPDATE_BEHIND=always run mq run-once
  [ "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/a)" != "$second" ]
  echo '[{"name":"build","conclusion":"SUCCESS"}]' >"$FX/checks.json"
  run mq run-once
  [ "$(outcome a)" = merged ]
}
