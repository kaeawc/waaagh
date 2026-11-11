#!/usr/bin/env bats
# A ship verdict is pinned to the reviewed content, not the literal head SHA (#210): a ship
# recorded --head R still counts at a later head H when R is an ancestor of H and every commit in
# `git rev-list R..H --not origin/main` is a merge GitHub made from update-branch (committer
# GitHub <noreply@github.com>, one parent on main, the clean merge tree). A merge made by hand,
# any non-merge commit, or a non-ancestor holds the PR as review:stale. One shared check,
# orch_review_covers in _lib.sh, on every merge path (pr-ready.sh, pr-merge.sh, merge-queue.sh).
# Real git against a local bare origin, stubbed gh. Run: bats scripts/review-head-cover.bats

setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE MERGE_QUEUE_ADMIN_CHECKS ORCHESTRATE_DIRECT_MERGE \
    ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_GENERATED_FILES ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE
  seed_origin_copy
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  Q="$ST/merge-queue"
  O="$BATS_TEST_TMPDIR/origin.git"
  W="$BATS_TEST_TMPDIR/a"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_GIT_DIR="$W"
  # PR 5 is branch a; its head is origin's refs/heads/a.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
head_of() { git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/a || echo none; }
case "$all" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) echo '{"data":{"repository":{"p5":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' ;;
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[]}' ;;
  "api --paginate repos/o/r/pulls/"*"/files"*) printf 'f.txt\n' ;;
  "api repos/o/r/pulls/"*"/reviews"*) echo '[]' ;;
  "api repos/o/r/issues/"*"/comments"*) echo '[]' ;;
  "api repos/o/r/pulls/"*) echo main ;;
  "api repos/o/r/compare/"*) echo 0 ;;
  "pr list"*"--state merged"*) echo '[]' ;;
  "pr list"*--head*) jq -n --arg h "$(head_of)" '[{number: 5, headRefOid: $h}]' ;;
  "pr list"*"--json number") echo '[{"number":5}]' ;;
  "pr list"*) jq -n --arg h "$(head_of)" \
      '[{number: 5, author: {login: "me"}, isDraft: false, isCrossRepository: false, baseRefName: "main",
         headRefOid: $h, mergeable: "MERGEABLE", labels: [],
         statusCheckRollup: [{name: "build", conclusion: "SUCCESS", startedAt: "2026-09-27T01:00:00Z"}]}]' ;;
  "pr create"*) ;;
  "pr merge"*) touch "$FX/merged" ;;
  "pr view"*)
    if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}'
    else jq -n --arg h "$(head_of)" '{state: "OPEN", isDraft: false, isCrossRepository: false, headRefOid: $h,
      baseRefName: "main", author: {login: "me"}, mergeable: "MERGEABLE", autoMergeRequest: null}'; fi ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo body >"$BATS_TEST_TMPDIR/body.md"
  # Branch a with one reviewed commit R, pushed; then main moves on in origin.
  git clone -q "$O" "$W" 2>/dev/null
  git -C "$W" switch -q -c a
  echo a >"$W/a.txt"
  git -C "$W" add -A
  git -C "$W" commit -qm a
  git -C "$W" push -q origin a
  R=$(git -C "$W" rev-parse HEAD)
}

# main_moves NAME: a squash-like commit lands on origin's main.
main_moves() {
  echo "$1" >"$BATS_TEST_TMPDIR/seed/$1.txt"
  git -C "$BATS_TEST_TMPDIR/seed" add -A
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm "$1"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
}
# webflow_merge: what `gh pr update-branch` makes: main merged into a, committed by GitHub.
webflow_merge() {
  git -C "$W" fetch -q origin
  env GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com git -C "$W" merge -q --no-ff --no-edit origin/main
}
push_a() { git -C "$W" push -q -f origin a; H=$(git -C "$W" rev-parse HEAD); }
covers() { run bash -c 'source "$1/_lib.sh"; orch_review_covers "$2" 5 "$3" "$4" main' _ "$SCRIPTS" "$W" "$1" "$2"; }
gate() { run bash -c 'source "$1/_lib.sh"; orch_review_hold_of o/r 5 "$2" main' _ "$SCRIPTS" "$1"; }
rl() { "$SCRIPTS/review-ledger.sh" "$1" --repo o/r "${@:2}"; }
pm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 5 --head "$H" "$@"; }
mq() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }

@test "covers: the same head, and one or more GitHub update-branch merges, keep the review" {
  covers "$R" "$R"
  [ "$status" -eq 0 ]
  main_moves m1
  webflow_merge
  push_a
  covers "$R" "$H"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # Main moves again (its own squash commits are excluded by --not origin/main), update-branch again.
  main_moves m2
  main_moves m3
  webflow_merge
  push_a
  covers "$R" "$H"
  [ "$status" -eq 0 ]
}

@test "covers: a merge made by hand is never accepted, even a clean one" {
  main_moves m1
  git -C "$W" fetch -q origin
  git -C "$W" merge -q --no-ff --no-edit origin/main
  push_a
  covers "$R" "$H"
  [ "$status" -eq 1 ]
  [ "$output" = "${H:0:9} is a merge made by hand (t <t@example.com>)" ]
}

@test "covers: an extra commit after the reviewed head fails, before or after an update-branch merge" {
  echo more >"$W/a.txt"
  git -C "$W" commit -qam more
  C=$(git -C "$W" rev-parse HEAD)
  main_moves m1
  webflow_merge
  push_a
  covers "$R" "$H"
  [ "$status" -eq 1 ]
  [ "$output" = "${C:0:9} is not a merge" ]
}

@test "covers: a reviewed head that is not an ancestor fails" {
  git -C "$W" commit -q --amend -m rewritten
  git -C "$W" push -q -f origin a
  H=$(git -C "$W" rev-parse HEAD)
  covers "$R" "$H"
  [ "$status" -eq 1 ]
  [ "$output" = "${R:0:9} is not an ancestor of ${H:0:9}" ]
}

@test "covers: a GitHub-committed merge that changes more than the base, or merges no base, fails" {
  main_moves m1
  webflow_merge
  # A conflict resolution in GitHub's web editor is committed by GitHub too: its tree differs.
  echo resolved >"$W/f.txt"
  git -C "$W" add f.txt
  env GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com git -C "$W" commit -q --amend --no-edit
  push_a
  covers "$R" "$H"
  [ "$status" -eq 1 ]
  [ "$output" = "${H:0:9} changes more than the merge of main" ]
  # A GitHub-committed merge of another branch, not main.
  git -C "$W" reset -q --hard "$R"
  git -C "$W" switch -q -c side "$R~1"
  echo side >"$W/side.txt"
  git -C "$W" add side.txt
  git -C "$W" commit -qm side
  git -C "$W" switch -q a
  env GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com git -C "$W" merge -q --no-ff --no-edit side
  push_a
  covers "$R" "$H"
  [ "$status" -eq 1 ]
  [ "$output" = "${H:0:9} does not merge main" ]
}

@test "covers: a head only on origin's refs/pull/N/head is fetched; commits nowhere cannot be verified" {
  main_moves m1
  webflow_merge
  H=$(git -C "$W" rev-parse HEAD)
  git -C "$W" push -q origin "HEAD:refs/pull/5/head"
  git -C "$W" reset -q --hard "$R"
  git -C "$W" reflog expire --expire=now --all
  git -C "$W" gc -q --prune=now
  run git -C "$W" cat-file -e "$H^{commit}"
  [ "$status" -ne 0 ]
  covers "$R" "$H"
  [ "$status" -eq 0 ]
  covers "$R" 0123456789abcdef0123456789abcdef01234567
  [ "$status" -eq 1 ]
  [ "$output" = "cannot verify: 012345678 is not in $W" ]
  run bash -c 'source "$1/_lib.sh"; orch_review_covers "$2" 5 "$3" "$4" ""' _ "$SCRIPTS" "$W" "$R" "$H"
  [ "$status" -eq 1 ]
  [ "$output" = "cannot verify: no base branch" ]
}

@test "orch_review_hold_of: a pinned ship holds at an uncovered head as review:stale; unpinned or covered does not" {
  rl record --pr 5 --verdict ship --head "$R" >/dev/null
  gate "$R"
  [ "$status" -eq 1 ]
  main_moves m1
  webflow_merge
  push_a
  gate "$H"
  [ "$status" -eq 1 ]
  echo more >"$W/a.txt"
  git -C "$W" commit -qam more
  push_a
  gate "$H"
  [ "$status" -eq 0 ]
  [ "$output" = "#5 review:stale since:2026-09-27T12:00:00Z head:$R ship at ${R:0:9} does not cover ${H:0:9}: ${H:0:9} is not a merge" ]
  run rl shipped
  [ "$output" = "5"$'\t'"$R" ]
  # A ship with no head is not pinned; a newer pinned ship at H clears it.
  rl record --pr 5 --verdict ship >/dev/null
  run rl shipped
  [ "$output" = "" ]
  gate "$H"
  [ "$status" -eq 1 ]
  rl record --pr 5 --verdict ship --head "${H:0:12}" >/dev/null
  gate "$H"
  [ "$status" -eq 1 ]
}

@test "pr-merge.sh: an update-branch merge after a ship merges; a hand merge is exit 14 review:stale" {
  rl record --pr 5 --verdict ship --head "$R" >/dev/null
  main_moves m1
  git -C "$W" fetch -q origin
  git -C "$W" merge -q --no-ff --no-edit origin/main
  push_a
  pm
  [ "$status" -eq 14 ]
  [[ "$output" == "held: PR 5's ship review is for another head (#5 review:stale "*"is a merge made by hand"*"review-ledger.sh record --head)" ]]
  [ "$(grep -c '^pr merge' "$FX/calls" || true)" -eq 0 ]
  git -C "$W" reset -q --hard "$R"
  webflow_merge
  git -C "$W" push -q -f origin a
  H=$(git -C "$W" rev-parse HEAD)
  pm
  [ "$status" -eq 0 ]
  [ "$output" = "merged 5 feedface" ]
}

@test "pr-ready.sh: an uncovered pinned ship is SKIP review:stale; an update-branch merge stays READY" {
  rl record --pr 5 --verdict ship --head "$R" >/dev/null
  main_moves m1
  webflow_merge
  push_a
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'5\tREADY\t'* ]]
  echo more >"$W/a.txt"
  git -C "$W" commit -qam more
  push_a
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'5\tSKIP\t'*$'\treview:stale ready-but-skipped'* ]]
}

@test "merge-queue: the queue's own base merge is made by hand, so a ship at the old head parks it held" {
  rl record --pr 5 --verdict ship --head "$R" >/dev/null
  main_moves m1
  mq add --id a --worktree "$W" --branch a --title "t a" --body-file "$BATS_TEST_TMPDIR/body.md" >/dev/null
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$Q/a.outcome")" = held ]
  [[ "$(sed -n 2p "$Q/a.outcome")" == "PR 5 is held by its review: #5 review:stale "*"is a merge made by hand"*"review-ledger.sh record --head)" ]]
  [ "$(grep -c '^pr merge' "$FX/calls" || true)" -eq 0 ]
  # Re-reviewed at the pushed head: the next pass resumes and merges it.
  rl record --pr 5 --verdict ship --head "$(git -C "$W" rev-parse HEAD)" >/dev/null
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$Q/a.outcome")" = merged ]
}

@test "doctrine: the head pin and its exception are written where the merge loop reads them" {
  [[ "$(cat "$ROOT/SKILL.md")" == *"orch_review_covers"*"never the compare API"* ]]
  [[ "$(cat "$ROOT/roles/merge-bot.md")" == *"review:stale"* ]]
  [[ "$(cat "$SCRIPTS/pr-merge.sh")" == *"orch_review_covers"* ]]
  [[ "$(cat "$SCRIPTS/review-ledger.sh")" == *"review-ledger.sh shipped"* ]]
}
