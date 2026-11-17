#!/usr/bin/env bats
# "Skip a PR pushed recently" guards key on the newest real write, not the head (#242): GitHub's
# update-branch merge gives a PR a fresh head with no second writer, so a guard on the head's time
# skipped nearly every PR the orchestrator had just updated. branch-idle.sh and orch_last_write
# (_lib.sh) skip those merges (orch_update_merge, the #210 test); thread-sweep.sh's stalled answer
# reads the head the same way over the API; the repair brief and the follow-up brief say so.
# Real git against a local bare origin, stubbed gh. Run: bats scripts/branch-idle.bats

setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/.." && pwd)"
  seed_origin_copy
  O="$BATS_TEST_TMPDIR/origin.git"
  W="$BATS_TEST_TMPDIR/a"
  T0=1790510400
  export ORCHESTRATE_GIT_DIR="$W" ORCHESTRATE_NOW=$((T0 + 3600)) ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  unset ORCHESTRATE_SELF_LOGIN ORCHESTRATE_GH_API
  stub_gh_routes
  echo '{"default_branch":"main"}' >"$FX/repo.json"
  gh_route "api repos/o/r" repo.json
  git clone -q "$O" "$W" 2>/dev/null
  git -C "$W" switch -q -c a
  echo a >"$W/a.txt"
  git -C "$W" add -A
  at "$T0" git -C "$W" commit -qm a
  C1=$(git -C "$W" rev-parse HEAD)
  push_pr
}

# at EPOCH CMD...: run CMD with author and committer time EPOCH.
at() { env GIT_AUTHOR_DATE="@$1 +0000" GIT_COMMITTER_DATE="@$1 +0000" "${@:2}"; }
# push_pr: branch a is PR 5's head on origin.
push_pr() { git -C "$W" push -q -f origin a a:refs/pull/5/head; }
main_moves() {
  echo "$1" >"$BATS_TEST_TMPDIR/seed/$1.txt"
  git -C "$BATS_TEST_TMPDIR/seed" add -A
  at "$2" git -C "$BATS_TEST_TMPDIR/seed" commit -qm "$1"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
}
# webflow_merge EPOCH: what `gh pr update-branch` makes at EPOCH: main merged in, committed by GitHub.
webflow_merge() {
  git -C "$W" fetch -q origin
  at "$1" env GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com git -C "$W" merge -q --no-ff --no-edit origin/main
}
bi() { run "$SCRIPTS/branch-idle.sh" --repo o/r "$@"; }

@test "an update-branch merge a minute ago does not make the PR active: the last write is the own commit" {
  main_moves m1 $((T0 + 3000))
  webflow_merge $((ORCHESTRATE_NOW - 60))
  push_pr
  # m1, ten minutes old, is main's commit: not a write to the branch either.
  bi --pr 5 --minutes 20
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "idle #5 last-write=${C1:0:9} age=60m merges-skipped=1" ]
  # the default branch took one gh read
  [ "$(grep -c 'api repos/o/r' "$FX/calls" || true)" -eq 1 ]
}

@test "a recent own commit is active, before or after an update-branch merge" {
  echo b >"$W/a.txt"
  at $((ORCHESTRATE_NOW - 300)) git -C "$W" commit -qam b
  C2=$(git -C "$W" rev-parse HEAD)
  main_moves m1 $((T0 + 3000))
  webflow_merge $((ORCHESTRATE_NOW - 60))
  push_pr
  bi --pr 5 --minutes 20 --base main
  [ "$status" -eq 1 ]
  [ "$output" = "active #5 last-write=${C2:0:9} age=5m merges-skipped=1" ]
  bi --pr 5 --minutes 5 --base main
  [ "$status" -eq 0 ]
  [ "$output" = "idle #5 last-write=${C2:0:9} age=5m merges-skipped=1" ]
}

@test "a merge made by hand (a conflict resolution) is a write; so is a GitHub merge that changes more" {
  main_moves m1 $((T0 + 3000))
  git -C "$W" fetch -q origin
  at $((ORCHESTRATE_NOW - 120)) git -C "$W" merge -q --no-ff --no-edit origin/main
  M=$(git -C "$W" rev-parse HEAD)
  push_pr
  bi --pr 5 --base main
  [ "$status" -eq 1 ]
  [ "$output" = "active #5 last-write=${M:0:9} age=2m merges-skipped=0" ]
  # GitHub's web editor commits a conflict resolution as GitHub: its tree is not the clean merge.
  git -C "$W" reset -q --hard "$C1"
  webflow_merge $((ORCHESTRATE_NOW - 60))
  echo resolved >"$W/f.txt"
  git -C "$W" add f.txt
  at $((ORCHESTRATE_NOW - 60)) env GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com git -C "$W" commit -q --amend --no-edit
  M=$(git -C "$W" rev-parse HEAD)
  push_pr
  bi --pr 5 --base main
  [ "$status" -eq 1 ]
  [ "$output" = "active #5 last-write=${M:0:9} age=1m merges-skipped=0" ]
}

@test "only update-branch merges off the base: idle with last-write=none; --head reads a local ref" {
  git -C "$W" switch -q -c b origin/main
  main_moves m1 $((T0 + 3000))
  webflow_merge $((ORCHESTRATE_NOW - 30))
  bi --head b --base main
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "idle b last-write=none age=- merges-skipped=1" ]
  run bash -c 'source "$1/_lib.sh"; orch_last_write "$2" b main' _ "$SCRIPTS" "$W"
  [ "$output" = "$(printf -- '-\t-\t1')" ]
}

@test "usage and unreadable input: exit 2 and exit 4, never a guessed idle" {
  bi
  [ "$status" -eq 2 ]
  bi --pr 5 --head a
  [ "$status" -eq 2 ]
  bi --pr x
  [ "$status" -eq 2 ]
  bi --pr 5 --minutes soon
  [ "$status" -eq 2 ]
  bi --pr 6 --base main
  [ "$status" -eq 4 ]
  [[ "$output" == *"refs/pull/6/head could not be fetched"* ]]
  bi --head nosuch --base main
  [ "$status" -eq 4 ]
  bi --head a --base nosuch
  [ "$status" -eq 4 ]
  [[ "$output" == *"origin/nosuch is not in"* ]]
  : >"$FX/routes.tsv"
  bi --pr 5
  [ "$status" -eq 4 ]
  [[ "$output" == *"pass --base"* ]]
}

@test "orch_review_covers still holds a review across update-branch merges after the refactor" {
  main_moves m1 $((T0 + 3000))
  webflow_merge $((ORCHESTRATE_NOW - 60))
  H=$(git -C "$W" rev-parse HEAD)
  push_pr
  run bash -c 'source "$1/_lib.sh"; orch_review_covers "$2" 5 "$3" "$4" main' _ "$SCRIPTS" "$W" "$C1" "$H"
  [ "$status" -eq 0 ]
  echo c >"$W/a.txt"
  git -C "$W" commit -qam c
  C3=$(git -C "$W" rev-parse HEAD)
  run bash -c 'source "$1/_lib.sh"; orch_review_covers "$2" 5 "$3" "$4" main' _ "$SCRIPTS" "$W" "$C1" "$C3"
  [ "$status" -eq 1 ]
  [ "$output" = "${C3:0:9} is not a merge" ]
}

# thread-sweep.sh, over GraphQL: our reply at 10:00, the own commit at 09:00, then an update-branch
# merge at 11:00. The merge is no push of a fix, so the thread is still stalled.
@test "thread-sweep: an update-branch merge after our unpushed reply leaves the thread stalled" {
  th='{id: "T1", isResolved: false, isOutdated: false, starter: {nodes: [{author: {login: "claude"}, url: "u1"}]},
       latest: {totalCount: 2, nodes: [{author: {login: "me"}, body: "agreed, proposed fix", createdAt: "2026-11-05T10:00:00Z"}]}}'
  jq -n "[{number: 80, commits: {nodes: [
      {commit: {oid: \"abc1234def5678900000000000000000000000000\", committedDate: \"2026-11-05T09:00:00Z\",
                parents: {totalCount: 1}, committer: {email: \"me@example.com\"}}},
      {commit: {oid: \"bbb1234def5678900000000000000000000000000\", committedDate: \"2026-11-05T11:00:00Z\",
                parents: {totalCount: 2}, committer: {email: \"noreply@github.com\"}}}]},
    reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [$th]}}]" >"$FX/prs.json"
  gh_routes <<'R'
case "$a" in
  "api graphql"*"pullRequest(number"*)
    jq '{data: {repository: {pullRequest: .[0]}}}' "$FX/prs.json"; exit 0 ;;
esac
R
  ORCHESTRATE_SELF_LOGIN=me run "$SCRIPTS/thread-sweep.sh" scan --pr 80 --repo o/r
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "$(printf '80\tT1\tstalled\t-\tu1')" ]
  # An own (one-parent) commit at 11:00 is a push after the reply: the thread is open, not stalled.
  jq '.[0].commits.nodes[1].commit.parents.totalCount = 1' "$FX/prs.json" >"$FX/p2" && mv "$FX/p2" "$FX/prs.json"
  ORCHESTRATE_SELF_LOGIN=me run "$SCRIPTS/thread-sweep.sh" scan --pr 80 --repo o/r
  [ "${lines[0]}" = "$(printf '80\tT1\topen\t-\tu1')" ]
}

@test "thread-nodes over REST carries each commit's parent count and committer email" {
  export ORCHESTRATE_GH_API=rest
  gh_routes <<'R'
case "$a" in
  "api --paginate repos/o/r/pulls/5/ccr/review_threads"*) echo '[{"isResolved":false,"root_comment_id":11}]'; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/comments"*)
    echo '[{"id":11,"user":{"login":"claude[bot]"},"body":"finding","html_url":"u11","created_at":"2026-11-05T08:00:00Z"},
           {"id":12,"in_reply_to_id":11,"user":{"login":"me"},"body":"agreed","created_at":"2026-11-05T10:00:00Z"}]'; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/commits"*)
    echo '[{"sha":"abc1234","parents":[{"sha":"p"}],"commit":{"committer":{"date":"2026-11-05T09:00:00Z","email":"me@example.com"}}},
           {"sha":"bbb1234","parents":[{"sha":"p"},{"sha":"q"}],"commit":{"committer":{"date":"2026-11-05T11:00:00Z","email":"noreply@github.com"}}}]'; exit 0 ;;
esac
R
  ORCHESTRATE_SELF_LOGIN=me run "$SCRIPTS/thread-sweep.sh" scan --pr 5 --repo o/r
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "$(printf '5\t11\tstalled\t-\tu11')" ]
}

@test "the repair brief and the follow-up brief key the recent-push check on non-merge writes" {
  run grep -c 'update-branch' "$ROOT/briefs/repair.md"
  [ "$output" -ge 1 ]
  [[ "$(cat "$ROOT/briefs/repair.md")" == *"noreply@github.com"* ]]
  [[ "$(cat "$ROOT/session-topology.md")" == *"branch-idle.sh"* ]]
  [[ "$(cat "$ROOT/session-topology.md")" == *"not a GitHub update-branch merge"* ]]
}
