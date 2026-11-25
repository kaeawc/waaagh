#!/usr/bin/env bats
# merge-queue.sh: every pr-merge.sh exit code mapped to a queue outcome, driven through the real
# pr-merge.sh. Split from merge-queue-gaps.bats for a shorter parallel run (#112); setup and
# helpers: merge_queue_gaps_setup.bash. Real git against a local bare origin, stubbed gh.
# Run: bats scripts/merge-queue-exits.bats

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
