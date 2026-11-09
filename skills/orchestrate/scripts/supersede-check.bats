#!/usr/bin/env bats
# supersede-check.sh (#195): a PR whose issue another merged PR closed, or whose conflict hunks
# overlap lines later merged PRs added for the same issue, is a SUPERSEDED-CANDIDATE; and
# merge-queue.sh takes such a conflict off the queue front as `superseded`, not `conflict`.
# Real git against a local bare origin, gh stubbed with stub_gh_routes.

setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_READ_SLEEP=0
  unset MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE
  stub_gh_routes
  seed_origin_copy
  S="$BATS_TEST_TMPDIR/seed" W="$BATS_TEST_TMPDIR/pr"
  printf 'a\nb\nc\nd\ne\n' >"$S/f.txt"
  printf '1\n2\n3\n' >"$S/g.txt"
  git -C "$S" add -A
  git -C "$S" commit -qm lines
  git -C "$S" push -q origin HEAD:main
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$W" 2>/dev/null
  git -C "$W" switch -q -c pr
  json pr5 '{"number":5,"state":"open","merged_at":null,"base":{"ref":"main"},"body":"Adds the b guard.\n\nFixes #7"}'
  json issue7-open '{"number":7,"state":"open"}'
  gh_route 'api repos/o/r/pulls/5' pr5.json
}

json() { printf '%s\n' "$2" >"$FX/$1.json"; }
sc() { "$SCRIPTS/supersede-check.sh" --repo o/r "$@"; }
# edit REPO FILE LINE TEXT: replace line LINE of FILE with TEXT (which may hold \n).
edit() { awk -v l="$3" -v t="$4" 'NR == l { print t; next } { print }' "$1/$2" >"$1/$2.new" && mv "$1/$2.new" "$1/$2"; }
commit() { git -C "$1" commit -qam "$2" ${3:+-m "$3"}; }
# The PR edits line 2 of f.txt and g.txt; main then rewrites both lines in later merged PRs.
conflicting_main() { # F_SUBJECT F_BODY G_SUBJECT
  edit "$W" f.txt 2 b-pr; edit "$W" g.txt 2 2-pr; commit "$W" "pr change"
  edit "$S" f.txt 2 $'b-main\nb2'; commit "$S" "$1" "$2"
  edit "$S" g.txt 2 2-main; commit "$S" "$3"
  git -C "$S" push -q origin HEAD:main
  git -C "$W" fetch -q origin
}

@test "issue closed by another merged PR: SUPERSEDED-CANDIDATE from the PR alone, exit 10" {
  json issue7 '{"number":7,"state":"closed"}'
  json tl7 '[{"event":"cross-referenced","source":{"issue":{"number":8,"pull_request":{"merged_at":null}}}},{"event":"closed","commit_id":"abcdef0123456789"}]'
  json pulls-of-commit '[{"number":9,"merged_at":"2026-11-01T00:00:00Z"},{"number":5,"merged_at":null}]'
  gh_route 'api repos/o/r/issues/7' issue7.json
  gh_route 'api repos/o/r/issues/7/timeline*' tl7.json
  gh_route 'api repos/o/r/commits/abcdef0123456789/pulls' pulls-of-commit.json
  run sc --pr 5
  [ "$status" -eq 10 ]
  [ "${lines[0]}" = "SUPERSEDED-CANDIDATE pr=#5 issue=#7" ]
  [ "${lines[1]}" = "reason: issue #7 closed by merged PR #9 (commit abcdef012)" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "closed issue with no closing commit: a merged PR that cross-references it is the reason" {
  json issue7 '{"number":7,"state":"closed"}'
  json tl7 '[{"event":"closed","commit_id":null},{"event":"cross-referenced","source":{"issue":{"number":5,"pull_request":{"merged_at":null}}}},{"event":"cross-referenced","source":{"issue":{"number":12,"pull_request":{"merged_at":"2026-11-02T00:00:00Z"}}}}]'
  gh_route 'api repos/o/r/issues/7' issue7.json
  gh_route 'api repos/o/r/issues/7/timeline*' tl7.json
  run sc --pr '#5'
  [ "$status" -eq 10 ]
  [ "${lines[1]}" = "reason: issue #7 is closed and merged PR #12 references it" ]
}

@test "conflict hunks over lines a later PR for the same issue added: candidate, with the overlap table" {
  conflicting_main "Guard b another way (#9)" "Fixes #7" "Tidy g (#11)"
  json pr11 '{"number":11,"title":"Tidy g","body":"Unrelated cleanup, see #70"}'
  json open5 '[{"number":5}]'; gh_route 'api repos/o/r/pulls?head=o:pr*' open5.json
  gh_route 'api repos/o/r/issues/7' issue7-open.json
  gh_route 'api repos/o/r/pulls/11' pr11.json
  run sc --worktree "$W"
  [ "$status" -eq 10 ]
  [ "${lines[0]}" = "SUPERSEDED-CANDIDATE pr=#5 issue=#7" ]
  [ "${lines[1]}" = "reason: conflict hunks overlap lines merged PR #9 added for issue #7" ]
  [ "${lines[2]}" = "$(printf 'file\tpr_lines\tmain_lines\tmerged_pr\tsame_issue')" ]
  [[ "$output" == *"$(printf 'f.txt\t2-2\t2-3\t#9\tyes')"* ]]
  [[ "$output" == *"$(printf 'g.txt\t2-2\t2-2\t#11\tno')"* ]]
  # #9's own commit message names the issue, so only #11's PR body is read.
  [ "$(grep -c 'pulls/9' "$FX/calls" || true)" -eq 0 ]
  # Read-only: the worktree is untouched.
  [ -z "$(git -C "$W" status --porcelain)" ]
  [ "$(git -C "$W" rev-parse HEAD)" = "$(git -C "$W" rev-parse pr)" ]
}

@test "a merged PR's body naming the issue counts; a merge commit ties lines to its PR" {
  edit "$W" f.txt 2 b-pr; commit "$W" "pr change"
  git -C "$S" switch -q -c feature
  edit "$S" f.txt 2 b-feature; commit "$S" "feature work"
  git -C "$S" switch -q main
  git -C "$S" merge -q --no-ff -m "Merge pull request #12 from o/feature" feature
  git -C "$S" push -q origin HEAD:main
  git -C "$W" fetch -q origin
  json issue7-open '{"number":7,"state":"open"}'
  json pr12 '{"number":12,"title":"Guard b","body":"Part of #7."}'
  gh_route 'api repos/o/r/issues/7' issue7-open.json
  gh_route 'api repos/o/r/pulls/12' pr12.json
  run sc --pr 5 --worktree "$W"
  [ "$status" -eq 10 ]
  [[ "$output" == *"$(printf 'f.txt\t2-2\t2-2\t#12\tyes')"* ]]
}

@test "a conflict with unrelated merges only is NOT-SUPERSEDED, exit 0, table kept for context" {
  conflicting_main "Rename b (#21)" "" "Tidy g"
  json pr21 '{"number":21,"title":"Rename b","body":"No issue."}'
  gh_route 'api repos/o/r/issues/7' issue7-open.json
  gh_route 'api repos/o/r/pulls/21' pr21.json
  run sc --pr 5 --worktree "$W"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NOT-SUPERSEDED pr=#5 issue=#7" ]
  [[ "$output" == *"$(printf 'f.txt\t2-2\t2-3\t#21\tno')"* ]]
  [[ "$output" == *"$(printf 'g.txt\t2-2\t2-2\t-\tno')"* ]]
  run ! grep -q '^reason:' <<<"$output"
}

@test "no conflict, PR already merged, unreadable issue, unusable worktree, bad input" {
  edit "$W" g.txt 3 3-pr; commit "$W" "pr change"
  edit "$S" f.txt 1 a-main; commit "$S" "Elsewhere (#9)" "Fixes #7"
  git -C "$S" push -q origin HEAD:main
  git -C "$W" fetch -q origin
  gh_route 'api repos/o/r/issues/7' issue7-open.json
  run sc --pr 5 --worktree "$W"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT-SUPERSEDED pr=#5 issue=#7" ]

  json pr6 '{"number":6,"state":"closed","merged_at":"2026-11-01T00:00:00Z","base":{"ref":"main"},"body":"Fixes #7"}'
  gh_route 'api repos/o/r/pulls/6' pr6.json
  run sc --pr 6
  [ "$status" -eq 0 ]
  [ "$output" = "NOT-SUPERSEDED pr=#6 issue=#7: PR is MERGED" ]

  run sc --pr 5 --issue 99
  [ "$status" -eq 3 ]
  [[ "$output" == *"issue #99 unreadable"* ]]

  run sc --pr 5 --issue 7 --worktree "$W" --base nope
  [ "$status" -eq 4 ]
  [[ "$output" == *"no origin/nope"* ]]

  run sc --issue 7
  [ "$status" -eq 2 ]
  run sc --pr five
  [ "$status" -eq 2 ]
  run sc --pr 5 --worktree "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 4 ]
}

@test "merge-queue: a superseded conflict leaves the queue front as superseded; the rest still runs" {
  git -C "$W" switch -q -c a
  edit "$W" f.txt 2 b-pr; commit "$W" "pr change"
  edit "$S" f.txt 2 $'b-main\nb2'; commit "$S" "Guard b another way (#9)" "Fixes #7"
  git -C "$S" push -q origin HEAD:main
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/b" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/b" switch -q -c b
  echo body >"$BATS_TEST_TMPDIR/body.md"
  json repo '{"default_branch":"main"}'
  gh_route 'api repos/o/r' repo.json
  json open5 '[{"number":5}]'; gh_route 'api repos/o/r/pulls?head=o:a&*' open5.json
  gh_route 'api repos/o/r/issues/7' issue7-open.json
  # b has nothing to merge or push past the base; its PR lookup is answered empty, then refused.
  gh_routes <<'R'
case "$a" in
  "pr list"*"--head b"*) echo '[]'; exit 0 ;;
  "pr create"*) exit 1 ;;
esac
R
  mq() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }
  mq add --id a --worktree "$W" --branch a --title "t a" --body-file "$BATS_TEST_TMPDIR/body.md"
  mq add --id c --worktree "$W" --branch a --title "t c" --body-file "$BATS_TEST_TMPDIR/body.md" --requires a
  mq add --id b --worktree "$BATS_TEST_TMPDIR/b" --branch b --title "t b" --body-file "$BATS_TEST_TMPDIR/body.md"
  ORCHESTRATE_DIRECT_MERGE=1 run mq run-once
  [ "$status" -eq 0 ]
  q="$ORCHESTRATE_STATE_DIR/o__r/merge-queue"
  [ "$(sed -n 1p "$q/a.outcome")" = superseded ]
  [[ "$(sed -n 2p "$q/a.outcome")" == "route to an evidence session, see "* ]]
  [[ "$output" == *"c: blocked on a"* ]]
  # The next item was still processed in the same pass (it reached the PR step).
  [ -f "$q/b.outcome" ]
  [[ "$(cat "$q/logs/a.log")" == *"SUPERSEDED-CANDIDATE pr=#5 issue=#7"* ]]
  [ "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/a || true)" = "" ]
  [ -z "$(git -C "$W" status --porcelain)" ]
  run mq status
  [[ "$output" == *$'a\tsuperseded\ta'* ]]
  run mq retry a
  [ "$output" = "a re-armed (was superseded)" ]
}

@test "doctrine: the conflict lane and cloud repair brief check supersession first; the evidence role closes nothing" {
  R="$SCRIPTS/../roles" B="$SCRIPTS/../briefs"
  [[ "$(cat "$R/conflict-lane.md")" == *'supersede-check.sh" --pr P --worktree'* ]]
  [[ "$(cat "$R/conflict-lane.md")" == *"supersede-evidence.md"* ]]
  [[ "$(cat "$B/repair.md")" == *"SUPERSEDED-CANDIDATE"* ]]
  [[ "$(sed -n 1p "$B/repair.md")" == "<!-- waaagh-brief repair v2."* ]]
  E=$(cat "$R/supersede-evidence.md")
  [[ "$E" == *"Start fresh from \`origin/{{BASE}}\`"* ]]
  [[ "$E" == *"failing-first test per"* ]]
  [[ "$E" == *"You close nothing"* ]]
  [[ "$E" == *"Supersedes #P"* ]]
  [[ "$(cat "$R/README.md")" == *'`supersede-evidence.md`'* ]]
  [[ "$(cat "$SCRIPTS/../SKILL.md")" == *'`superseded`'* ]]
}
