#!/usr/bin/env bats
# GitHub outage handling (#63): gh-status.sh reads a githubstatus fixture (never the network), and
# pr-merge.sh treats a 5xx or "merge already in progress" as pending, verified by the PR state.
# Run: bats scripts/github-outage.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  # Direct mode with evidence: no readiness reads, so the stub only serves the PR and the merge.
  export ORCHESTRATE_DIRECT_MERGE=1
  STATUS="$BATS_TEST_TMPDIR/githubstatus.json"
  LOG="$ORCHESTRATE_STATE_DIR/o__r/merges.log"
  J="$ORCHESTRATE_STATE_DIR/o__r/ops/merge-pr1.json"
  # $FX/replies: one reply per merge call (502 | progress | ok); $FX/merged-at: the PR reads as
  # MERGED from that `pr view` call on.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "pr merge"*)
    n=$(($(cat "$FX/merges" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FX/merges"
    case "$(sed -n "${n}p" "$FX/replies")" in
      502) echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1 ;;
      progress) echo "GraphQL: Merge already in progress (mergePullRequest)" >&2; exit 1 ;;
      *) echo 1 >"$FX/merged-at" ;;
    esac ;;
  "pr view"*)
    v=$(($(cat "$FX/views" 2>/dev/null || echo 0) + 1)); echo "$v" >"$FX/views"
    if [ -f "$FX/merged-at" ] && [ "$v" -ge "$(cat "$FX/merged-at")" ]; then
      echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"},"headRefOid":"abcdef0123456789abcdef0123456789abcdef01"}'
    else
      echo '{"state":"OPEN","isDraft":false,"isCrossRepository":false,"headRefOid":"abcdef0123456789abcdef0123456789abcdef01","author":{"login":"me"},"mergeable":"MERGEABLE","autoMergeRequest":null}'
    fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

status_fixture() { # NAME=STATUS... -> a githubstatus summary with those components
  jq -n --args '{status: {indicator: "minor"}, components: ([{name: "Visit githubstatus.com", status: "operational", group: true}]
    + [$ARGS.positional[] | split("=") | {name: .[0], status: .[1], group: false}])}' "$@" >"$STATUS"
}
merge() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --evidence "test: direct" "$@"; }
merge_calls() { grep -c '^pr merge' "$FX/calls" || true; }

@test "gh-status reports operational, other degraded components, a Pull Requests outage and an unreadable page" {
  status_fixture "Git Operations=operational" "Pull Requests=operational"
  run "$SCRIPTS/gh-status.sh"
  [ "$status" -eq 0 ]; [ "$output" = operational ]
  status_fixture "Actions=degraded_performance" "Pull Requests=operational"
  run "$SCRIPTS/gh-status.sh"
  [ "$status" -eq 0 ]; [ "$output" = "degraded Actions=degraded_performance" ]
  run "$SCRIPTS/gh-status.sh" --component Actions
  [ "$status" -eq 4 ]
  status_fixture "Pull Requests=partial_outage" "API Requests=operational"
  run "$SCRIPTS/gh-status.sh"
  [ "$status" -eq 4 ]; [ "$output" = "degraded Pull Requests=partial_outage" ]
  rm "$STATUS"
  run "$SCRIPTS/gh-status.sh"
  [ "$status" -eq 9 ]; [[ "$output" == unreadable:* ]]
  echo '<html>' >"$STATUS"
  run "$SCRIPTS/gh-status.sh"
  [ "$status" -eq 9 ]
}

@test "a 502 then 'merge already in progress' is pending until the PR reads MERGED" {
  printf '502\nprogress\n' >"$FX/replies"
  echo 4 >"$FX/merged-at" # (view 1 is the eligibility read) GitHub finishes the first merge while we wait
  merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged 1 feedface" ]]
  # The 5xx was re-sent once; "already in progress" was only re-read, never re-sent.
  [ "$(merge_calls)" -eq 2 ]
  [[ "$output" == *"pr-merge: wait 60"* && "$output" == *"pr-merge: wait 120"* ]]
  grep -q 'pending: 5xx (exit 1: HTTP 502: Bad Gateway' "$LOG"
  grep -q 'pending: in-progress' "$LOG"
  # The status page was unreadable here: logged, and the merge was still retried.
  grep -q 'githubstatus: unreadable' "$LOG"
  grep -q $'\tmerged feedface' "$LOG"
  [ "$(jq -r .state "$J")" = merged ]
}

@test "'merge already in progress' is never treated as done; a rerun reconciles from the journal" {
  printf 'progress\n' >"$FX/replies"
  status_fixture "Pull Requests=operational"
  merge
  [ "$status" -eq 10 ]
  [[ "$output" == *"pending: the merge of PR 1 got in-progress"* ]]
  [[ "$output" != *"merged 1"* ]]
  [ "$(merge_calls)" -eq 1 ]
  [ "$(jq -r .state "$J")" = pending ]
  run ! grep -q $'\tmerged' "$LOG"
  run ! grep -q 'failed:' "$LOG"
  # GitHub completes it later: the rerun sees MERGED and does not merge again.
  echo 1 >"$FX/merged-at"; rm -f "$FX/views"
  merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"(earlier attempt)"* ]]
  [ "$(merge_calls)" -eq 1 ]
}

@test "a 502 during a Pull Requests outage pauses merging until the status is operational" {
  printf '502\nok\n' >"$FX/replies"
  status_fixture "Pull Requests=partial_outage" "Git Operations=operational"
  merge
  [ "$status" -eq 10 ]
  [[ "$output" == "outage: GitHub reports degraded Pull Requests=partial_outage"* ]]
  [[ "$output" != *"pr-merge: wait"* ]]
  grep -q 'githubstatus: degraded Pull Requests=partial_outage' "$LOG"
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/GITHUB_OUTAGE" ]
  [ "$(jq -r .state "$J")" = pending ]
  # Still down: paused before any attempt, and no new log line for the pass.
  n0=$(wc -l <"$LOG")
  merge
  [ "$status" -eq 10 ]
  [[ "$output" == "outage: merging paused since 2026-09-27T12:00:00Z"* ]]
  [ "$(merge_calls)" -eq 1 ]
  [ "$(wc -l <"$LOG")" -eq "$n0" ]
  # Recovered: the marker is cleared and the merge goes through, verified by the PR state.
  status_fixture "Pull Requests=operational"
  merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged 1 feedface"* ]]
  [ "$(merge_calls)" -eq 2 ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/GITHUB_OUTAGE" ]
}

@test "a 5xx that never resolves ends pending after the bounded rounds, not failed" {
  printf '502\n502\n502\n502\n' >"$FX/replies"
  ORCHESTRATE_MERGE_TRIES=2 ORCHESTRATE_MERGE_BACKOFF=5 merge
  [ "$status" -eq 10 ]
  [[ "$output" == *"pr-merge: wait 60"* ]] # the backoff never goes below 60 s
  [[ "$output" == *"still OPEN after 2 rounds"* ]]
  [ "$(merge_calls)" -eq 2 ]
  ! grep -q 'failed:' "$LOG"
}

@test "the outage handling is documented where the merge bot and the doctrine read it" {
  grep -q 'gh-status.sh' "$SCRIPTS/../roles/merge-bot.md"
  grep -q 'Exit 10' "$SCRIPTS/../roles/merge-bot.md"
  grep -q 'merge already in progress' "$SCRIPTS/../SKILL.md"
  grep -q '`gh-status.sh`' "$SCRIPTS/../../../README.md"
}
