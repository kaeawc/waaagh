#!/usr/bin/env bats
# Holds on every merge path (#202): pr-merge.sh refuses a PR in the hold file with exit 14 in every
# mode, including a hold set while its gates ran; merge-queue.sh parks such an item as `held`
# (before any fetch or push once its PR is known), keeps the rest of the queue moving, maps
# pr-merge.sh exit 14 to `held`, and resumes the item once hold.sh releases it. The check itself is
# one helper, orch_hold_of in _lib.sh, which reads the file through `hold.sh list`.
# Real git against a local bare origin, stubbed gh. Run: bats scripts/merge-holds.bats

setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE MERGE_QUEUE_ADMIN_CHECKS ORCHESTRATE_DIRECT_MERGE \
    ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_GENERATED_FILES ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE
  seed_origin_copy
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  Q="$ST/merge-queue"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Fixture switches in $FX:
  #   num-<branch>   the PR number of <branch> (default 5); the readiness list shows the PR of the
  #                  branch last looked up by --head
  #   merged-<n>     written by `pr merge <n>`: `pr view <n>` then reports MERGED
  #   hold-on-view   a PR number: the first `pr view` adds a hold on it (a hold set mid-merge)
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
br=$(cat "$FX/branch" 2>/dev/null || true)
head_of() { git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify "refs/heads/$br" || echo none; }
num=$(cat "$FX/num-$br" 2>/dev/null || echo 5)
case "$all" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) echo "{\"data\":{\"repository\":{\"p$num\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false},\"nodes\":[]}}}}}" ;;
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[]}' ;;
  "api --paginate repos/o/r/pulls/"*"/files"*) printf 'f.txt\n' ;;
  "api repos/o/r/pulls/"*"/reviews"*) echo '[]' ;;
  "api repos/o/r/issues/"*"/comments"*) echo '[]' ;;
  "api repos/o/r/pulls/"*) echo main ;;
  "api repos/o/r/compare/"*) echo 0 ;;
  "pr list"*"--state merged"*) echo '[]' ;;
  "pr list"*--head*) b=$(echo "$all" | sed 's/.*--head \([^ ]*\).*/\1/'); echo "$b" >"$FX/branch"; br=$b
    jq -n --arg h "$(head_of)" --argjson n "$(cat "$FX/num-$b" 2>/dev/null || echo 5)" '[{number: $n, headRefOid: $h}]' ;;
  "pr list"*"--json number") jq -n --argjson n "$num" '[{number: $n}]' ;;
  "pr list"*) jq -n --arg h "$(head_of)" --argjson n "$num" \
      '[{number: $n, author: {login: "me"}, isDraft: false, isCrossRepository: false, baseRefName: "main",
         headRefOid: $h, mergeable: "MERGEABLE", labels: [],
         statusCheckRollup: [{name: "build", conclusion: "SUCCESS", startedAt: "2026-09-27T01:00:00Z"}]}]' ;;
  "pr create"*) ;;
  "pr merge"*) n=${all#pr merge }; touch "$FX/merged-${n%% *}" ;;
  "pr view"*) n=${all#pr view }; n=${n%% *}
    if [ -f "$FX/hold-on-view" ]; then
      echo "$(cat "$FX/hold-on-view") until:owner since:2026-09-27T12:00:00Z fix pass started" >>"$ORCHESTRATE_STATE_DIR/o__r/holds"
      rm "$FX/hold-on-view"
    fi
    if [ -f "$FX/merged-$n" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}'
    else jq -n --arg h "$(head_of)" '{state: "OPEN", isDraft: false, isCrossRepository: false, headRefOid: $h,
      author: {login: "me"}, mergeable: "MERGEABLE", autoMergeRequest: null}'; fi ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo body >"$BATS_TEST_TMPDIR/body.md"
}

# wt NAME: a clone on branch NAME with one commit.
wt() {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/$1" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/$1" switch -q -c "$1"
  echo "$1" >"$BATS_TEST_TMPDIR/$1/$1.txt"
  git -C "$BATS_TEST_TMPDIR/$1" add -A
  git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$1"
}
hold() { "$SCRIPTS/hold.sh" "$1" --repo o/r "${@:2}"; }
mq() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }
enqueue() { mq add --id "$1" --worktree "$BATS_TEST_TMPDIR/$1" --branch "$1" --title "t $1" --body-file "$BATS_TEST_TMPDIR/body.md" >/dev/null; }
outcome() { sed -n 1p "$Q/$1.outcome"; }
reason() { sed -n 2p "$Q/$1.outcome"; }
calls() { grep -c "^$1" "$FX/calls" 2>/dev/null || true; }
# A pushed branch `a` whose PR is 5, for pr-merge.sh run directly.
pushed_pr() {
  wt a
  git -C "$BATS_TEST_TMPDIR/a" push -q origin a
  echo a >"$FX/branch"
  HEAD=$(git -C "$BATS_TEST_TMPDIR/a" rev-parse HEAD)
}
pm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 5 --head "$HEAD" "$@"; }

@test "orch_hold_of reads the hold file through hold.sh: the held row, not held, an old-format line" {
  hold add --pr 12 --until main-green --reason "needs green main" >/dev/null
  printf '#55\n' >>"$ST/holds"
  run bash -c 'source "$1/_lib.sh"; orch_hold_of o/r "$2"' _ "$SCRIPTS" 12
  [ "$status" -eq 0 ]
  [ "$output" = "#12 until:main-green since:2026-09-27T12:00:00Z needs green main" ]
  run bash -c 'source "$1/_lib.sh"; orch_hold_of o/r "$2"' _ "$SCRIPTS" '#55'
  [ "$status" -eq 0 ]
  [ "$output" = "#55 until:unknown since:unknown -" ]
  run bash -c 'source "$1/_lib.sh"; orch_hold_of o/r "$2"' _ "$SCRIPTS" 1
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "pr-merge.sh refuses a held PR with exit 14 in every mode, before any GitHub read; release lets it merge" {
  pushed_pr
  hold add --pr 5 --until owner --reason "owner wants a look" >/dev/null
  : >"$FX/calls"
  pm
  [ "$status" -eq 14 ]
  [ "$output" = "held: PR 5 is in the hold file (#5 until:owner since:2026-09-27T12:00:00Z owner wants a look); hold.sh release clears it" ]
  grep -q $'\trefused held: #5 until:owner' "$ST/merges.log"
  echo "red: build" >"$ST/MAIN_RED"
  pm --main-fix
  [ "$status" -eq 14 ]
  rm "$ST/MAIN_RED"
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 14 ]
  ORCHESTRATE_ADMIN_MERGE=1 pm --admin --evidence "sim: flake" --except-check sim
  [ "$status" -eq 14 ]
  [ ! -s "$FX/calls" ]
  [ ! -f "$ST/ops/merge-pr5.json" ]
  hold release --pr 5 --note "owner looked" >/dev/null
  pm
  [ "$status" -eq 0 ]
  [ "$output" = "merged 5 feedface" ]
  [ "$(calls 'pr merge 5')" -eq 1 ]
}

@test "pr-merge.sh: a hold set while the gates ran still stops the merge (exit 14) and frees its locks" {
  pushed_pr
  export ORCHESTRATE_MERGE_SENSITIVE='*.txt'
  # Direct mode: no readiness row (which would skip the held PR first), only the hold check.
  echo 5 >"$FX/hold-on-view"
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 14 ]
  [[ "$output" == "held: PR 5 is in the hold file (#5 until:owner "*"fix pass started); hold.sh release clears it" ]]
  [ "$(calls 'pr merge')" -eq 0 ]
  [ ! -f "$ST/ops/merge-pr5.json" ]
  [ -z "$(ls -A "$ST/locks")" ]
  # Another PR's hold does not stop this one.
  hold release --pr 5 >/dev/null
  hold add --pr 6 --until owner >/dev/null
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 0 ]
}

@test "merge-queue: a held PR is parked as held, the rest of the queue merges, and release resumes it" {
  wt a
  wt b
  echo 7 >"$FX/num-a"
  enqueue a
  enqueue b
  hold add --pr 7 --until closed:9 --reason "waits for #9" >/dev/null
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = held ]
  [ "$(reason a)" = "PR 7 is held: #7 until:closed:9 since:2026-09-27T12:00:00Z waits for #9; hold.sh release clears it" ]
  [[ "$output" == *"a: held (PR 7 is held: "* ]]
  [ "$(outcome b)" = merged ]
  [ "$(calls 'pr merge 7')" -eq 0 ]
  [ "$(calls 'pr merge 5')" -eq 1 ]
  run mq status
  [[ "$output" == *$'a\theld\ta'* ]]
  # Still held: the known PR is re-checked first, and nothing is fetched, looked up or pushed.
  : >"$FX/calls"
  run mq run-once
  [ "$(outcome a)" = held ]
  [ "$(calls 'pr list')" -eq 0 ]
  [ "$(calls 'pr view 7')" -eq 1 ]
  # Released: the next pass resumes it with no retry.
  hold release --pr 7 --note "#9 closed" >/dev/null
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = merged ]
  [ "$(calls 'pr merge 7')" -eq 1 ]
}

@test "merge-queue: pr-merge.sh exit 14 (a hold set mid-merge) is the held outcome, not an error" {
  wt a
  enqueue a
  echo 5 >"$FX/hold-on-view"
  ORCHESTRATE_DIRECT_MERGE=1 run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = held ]
  [[ "$(reason a)" == "PR 5 is held: #5 until:owner "*"fix pass started; hold.sh release clears it" ]]
  [ "$(calls 'pr merge')" -eq 0 ]
  [[ "$(cat "$Q/logs/a.log")" == *"held: PR 5 is in the hold file"* ]]
}

@test "doctrine: the exit code and the held outcome are documented where the merge loop reads them" {
  [[ "$(cat "$SCRIPTS/pr-merge.sh")" == *"| 14 held: the PR is in the hold file (hold.sh)"* ]]
  [[ "$(cat "$SCRIPTS/merge-queue.sh")" == *"#   held       the item's PR is in the hold file"* ]]
  [[ "$(cat "$SCRIPTS/../roles/merge-bot.md")" == *"pr-merge.sh"*"exit 14"* ]]
}
