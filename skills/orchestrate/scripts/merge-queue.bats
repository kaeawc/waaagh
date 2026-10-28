#!/usr/bin/env bats
# Self-test for merge-queue.sh: real git against a local bare origin, stubbed gh.
# Run: bats scripts/merge-queue.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE
  git init -q --bare -b main "$BATS_TEST_TMPDIR/origin.git"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/seed" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/seed" config user.email t@example.com
  git -C "$BATS_TEST_TMPDIR/seed" config user.name t
  git -C "$BATS_TEST_TMPDIR/seed" config commit.gpgsign false
  echo base >"$BATS_TEST_TMPDIR/seed/f.txt"
  git -C "$BATS_TEST_TMPDIR/seed" add f.txt
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm init
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # An unprotected server: it accepts any merge whose --match-head-commit matches. The PR head
  # is the SHA really pushed to the local origin (or $FX/stale-head while GitHub lags).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
head_of() {
  if [ -f "$FX/stale-head" ]; then cat "$FX/stale-head"; return; fi
  git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify "refs/heads/$(cat "$FX/branch")" || echo none
}
case "$all" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) jq -n --argjson t "$(cat "$FX/threads.json")" '{data: {repository: {p5: {reviewThreads: {pageInfo: {hasNextPage: false}, nodes: $t}}}}}' ;;
  "run list"*) cat "$FX/runs.json" ;;
  "pr list"*"--state merged"*) cat "$FX/merged-prs.json" 2>/dev/null || echo '[]' ;;
  "pr list"*--head*) [ ! -f "$FX/list-fails-$(echo "$all" | sed 's/.*--head \([^ ]*\).*/\1/')" ] || { echo "HTTP 502" >&2; exit 1; }
    rm -f "$FX/merged"; b=$(echo "$all" | sed 's/.*--head \([^ ]*\).*/\1/'); echo "$b" >>"$FX/order"; echo "$b" >"$FX/branch"
    jq -n --arg h "$(head_of)" '[{number: 5, headRefOid: $h}]' ;;
  "pr list"*) jq -n --arg h "$(head_of)" --argjson c "$(cat "$FX/checks.json")" --arg m "$(cat "$FX/mergeable")" \
    '[{number: 5, author: {login: "me"}, isDraft: false, isCrossRepository: false, baseRefName: "main",
       headRefOid: $h, mergeable: $m, labels: [], statusCheckRollup: $c}]' ;;
  "pr merge"*) want=$(echo "$all" | sed -nE 's/.*--match-head-commit ([0-9a-f]+).*/\1/p')
    [ "$want" = "$(head_of)" ] || { echo "Head branch was modified"; exit 1; }
    echo MERGED >"$FX/merged"
    [ "$(cat "$FX/merge-mode" 2>/dev/null)" != no-readback ] || echo 3 >"$FX/view-fails" ;;
  "pr view"*) if [ -s "$FX/view-fails" ] && [ "$(cat "$FX/view-fails")" -gt 0 ]; then
      echo $(($(cat "$FX/view-fails") - 1)) >"$FX/view-fails"; echo "HTTP 502" >&2; exit 1; fi
    if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}';
    else jq -n --arg h "$(head_of)" --arg m "$(cat "$FX/mergeable")" '{state: "OPEN", isDraft: false, isCrossRepository: false,
      headRefOid: $h, author: {login: "me"}, mergeable: $m}'; fi ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo '[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]' >"$FX/checks.json"
  echo MERGEABLE >"$FX/mergeable"
  echo '[]' >"$FX/threads.json"
  echo '[]' >"$FX/runs.json"
  echo body >"$BATS_TEST_TMPDIR/body.md"
}

# wt NAME [FILE CONTENT]: a worktree-clone on branch NAME with one commit editing FILE.
wt() {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/$1" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/$1" config user.email t@example.com
  git -C "$BATS_TEST_TMPDIR/$1" config user.name t
  git -C "$BATS_TEST_TMPDIR/$1" config commit.gpgsign false
  git -C "$BATS_TEST_TMPDIR/$1" switch -q -c "$1"
  echo "${3:-$1}" >"$BATS_TEST_TMPDIR/$1/${2:-$1.txt}"
  git -C "$BATS_TEST_TMPDIR/$1" add -A
  git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$1"
}

mq() { "$SCRIPTS/merge-queue.sh" "$@" --repo o/r; }
mqr() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }
enqueue() { # id [requires]
  mq add --id "$1" --worktree "$BATS_TEST_TMPDIR/$1" --branch "$1" --title "t $1" \
    --body-file "$BATS_TEST_TMPDIR/body.md" --requires "${2:--}"
}
outcome() { head -1 "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/$1.outcome"; }

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
  ! grep -q 'pr merge' "$FX/calls"
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
  ! grep -q 'pr merge' "$FX/calls"
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
  ! grep -q 'pr merge' "$FX/calls"
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
  ! grep -q 'pr merge' "$FX/calls"
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
  ! grep -q 'pr create' "$FX/calls"
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
