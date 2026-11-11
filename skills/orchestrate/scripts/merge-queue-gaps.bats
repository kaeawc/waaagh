#!/usr/bin/env bats
# merge-queue.sh paths merge-queue.bats does not reach: every pr-merge.sh exit code mapped to a queue
# outcome (driven through the real pr-merge.sh), the bot-review request on exit 13 (one per head,
# through review-gate.sh's throttle, never to an out-of-quota bot), the base-merge and PR lookup/create failure arms,
# a dirty worktree, an unreadable known PR, a SKIP readiness row, and status/retry edge cases.
# Real git against a local bare origin, stubbed gh. Run: bats scripts/merge-queue-gaps.bats

# The origin and seed fixture: built once per file, copied per test (test_helper.bash, #112).
setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_REVIEW_BOT_LOGIN ORCHESTRATE_REVIEW_TRIGGER ORCHESTRATE_REVIEW_CHECK ORCHESTRATE_REVIEW_QUOTA_RE ORCHESTRATE_REVIEW_EVERY ORCHESTRATE_REVIEW_PROBE_EVERY MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE MERGE_QUEUE_ADMIN_CHECKS ORCHESTRATE_DIRECT_MERGE \
    ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_GENERATED_FILES ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE
  seed_origin_copy
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Fixture switches in $FX:
  #   open-empty          `pr list --head --state open` answers [] (no open PR)
  #   merged-list-fails   `pr list --state merged` answers HTTP 502
  #   create-fails        `pr create` fails (and opens nothing)
  #   checks.json, checks-<n>.json  statusCheckRollup; the n-th readiness list uses checks-<n>.json
  #   labels.json         PR labels
  #   merge-mode          ok (default) | queued | 5xx | reject
  #   view-fails          `pr view` answers HTTP 502 this many more times
  #   files-fail, behind  merge-sensitive reads: PR files unreadable; commits behind the base
  #   reviews.json        bot reviews (review-gate.sh)
#   comment-fails       `pr comment` (a review request) answers HTTP 502
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
head_of() { git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify "refs/heads/$(cat "$FX/branch" 2>/dev/null)" || echo none; }
case "$all" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) echo '{"data":{"repository":{"p5":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' ;;
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[]}' ;;
  "api --paginate repos/o/r/pulls/5/files"*) [ ! -f "$FX/files-fail" ] || { echo "HTTP 404" >&2; exit 1; }; printf 'f.txt\n' ;;
  "api repos/o/r/pulls/5/reviews"*) cat "$FX/reviews.json" ;;
  "api repos/o/r/issues/5/comments"*) echo '[]' ;;
  "api repos/o/r/commits/"*"/check-runs"*) echo '{"check_runs":[]}' ;;
  "api repos/o/r/pulls/5 "*) echo main ;;
  "api repos/o/r/compare/"*) cat "$FX/behind" 2>/dev/null || echo 1 ;;
  "pr list"*"--state merged"*) [ ! -f "$FX/merged-list-fails" ] || { echo "HTTP 502" >&2; exit 1; }; echo '[]' ;;
  "pr list"*--head*) b=$(echo "$all" | sed 's/.*--head \([^ ]*\).*/\1/'); echo "$b" >"$FX/branch"
    if [ -f "$FX/open-empty" ]; then echo '[]'; else jq -n --arg h "$(head_of)" '[{number: 5, headRefOid: $h}]'; fi ;;
  "pr list"*"--json number") echo '[{"number":5}]' ;;
  "pr list"*) echo x >>"$FX/ready-calls"; n=$(wc -l <"$FX/ready-calls" | tr -d ' ')
    c="$FX/checks.json"; [ ! -f "$FX/checks-$n.json" ] || c="$FX/checks-$n.json"
    jq -n --arg h "$(head_of)" --argjson c "$(cat "$c")" --argjson l "$(cat "$FX/labels.json")" \
      '[{number: 5, author: {login: "me"}, isDraft: false, isCrossRepository: false, baseRefName: "main",
         headRefOid: $h, mergeable: "MERGEABLE", labels: $l, statusCheckRollup: $c}]' ;;
  "pr comment"*) [ ! -f "$FX/comment-fails" ] || { echo "HTTP 502" >&2; exit 1; } ;;
  "pr create"*) [ ! -f "$FX/create-fails" ] || { echo "GraphQL: something went wrong" >&2; exit 1; } ;;
  "pr merge"*) case "$(cat "$FX/merge-mode" 2>/dev/null)" in
      queued) touch "$FX/auto"; echo "! Pull request will be automatically merged when all requirements are met" ;;
      5xx) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
      reject) echo "Pull request is not mergeable: base branch policy prohibits the merge" >&2; exit 1 ;;
      *) echo MERGED >"$FX/merged" ;;
    esac ;;
  "pr view"*) if [ -s "$FX/view-fails" ] && [ "$(cat "$FX/view-fails")" -gt 0 ]; then
      echo $(($(cat "$FX/view-fails") - 1)) >"$FX/view-fails"; echo "HTTP 502" >&2; exit 1; fi
    if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}'
    else jq -n --arg h "$(head_of)" --arg auto "$([ -f "$FX/auto" ] && echo yes)" '{state: "OPEN", isDraft: false,
      isCrossRepository: false, headRefOid: $h, author: {login: "me"}, mergeable: "MERGEABLE",
      autoMergeRequest: (if $auto == "yes" then {enabledAt: "2026-09-27T12:00:00Z"} else null end)}'; fi ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  reset_fx
  echo body >"$BATS_TEST_TMPDIR/body.md"
  Q="$ORCHESTRATE_STATE_DIR/o__r/merge-queue"
}

reset_fx() {
  rm -rf "$FX"; mkdir -p "$FX"
  echo '[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]' >"$FX/checks.json"
  echo '[]' >"$FX/labels.json"
  echo '[]' >"$FX/reviews.json"
}

# wt NAME [FILE CONTENT]: a clone on branch NAME with one commit editing FILE.
wt() {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/$1" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/$1" switch -q -c "$1"
  echo "${3:-$1}" >"$BATS_TEST_TMPDIR/$1/${2:-$1.txt}"
  git -C "$BATS_TEST_TMPDIR/$1" add -A
  git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$1"
}
mq() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }
enqueue() { mq add --id "$1" --worktree "$BATS_TEST_TMPDIR/$1" --branch "$1" --title "t $1" --body-file "$BATS_TEST_TMPDIR/body.md" >/dev/null; }
outcome() { head -1 "$Q/$1.outcome"; }
reason() { sed -n 2p "$Q/$1.outcome"; }
main_moves() { # FILE CONTENT: a new commit on origin/main
  echo "$2" >"$BATS_TEST_TMPDIR/seed/$1"
  git -C "$BATS_TEST_TMPDIR/seed" add -A
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm "main $1"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
}

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
