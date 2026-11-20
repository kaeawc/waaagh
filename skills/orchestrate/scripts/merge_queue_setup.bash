# Setup and helpers shared by merge-queue.bats and merge-queue-recovery.bats
# (split for a shorter parallel run, #112).
# Loaded at file level by both; not a suite itself.

# The bare origin and its seed clone with one commit, built once per file and copied into each
# test (seed_origin_template and seed_origin_copy in test_helper.bash, #112).
setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE
  seed_origin_copy
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
  "api repos/o/r/actions/runs?"*) jq '{workflow_runs: map({name: .workflowName, status, conclusion, head_sha: .headSha, id: .databaseId, created_at: .createdAt})}' "$FX/runs.json" ;;
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
