#!/usr/bin/env bats
# Self-test for the orchestrate skill's helper scripts. Run: bats scripts/selftest.bats

setup() {
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  echo one >"$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" commit -qm init
}

fp() { "$SCRIPTS/fingerprint.sh" --dir "$REPO" "$@"; }

@test "clean git tree reports tree=clean" {
  run fp
  [ "$status" -eq 0 ]
  [[ "$output" == vcs=git* ]]
  [[ "$output" == *"tree=clean"* ]]
}

@test "tracked edit changes the fingerprint; reverting restores it" {
  clean=$(fp)
  echo two >"$REPO/a.txt"
  dirty=$(fp)
  [ "$clean" != "$dirty" ]
  [[ "$dirty" != *"tree=clean"* ]]
  echo one >"$REPO/a.txt"
  [ "$(fp)" = "$clean" ]
}

@test "untracked file content participates in the fingerprint" {
  echo x >"$REPO/new.txt"
  first=$(fp)
  echo y >"$REPO/new.txt"
  second=$(fp)
  [ "$first" != "$second" ]
}

@test "--key differs by command and is stable for the same state" {
  k1=$(fp --key "bun test")
  k2=$(fp --key "bun run lint")
  [ "$k1" != "$k2" ]
  [ "$(fp --key "bun test")" = "$k1" ]
}

@test "excerpt keeps failure lines, strips ANSI, and prints the log path" {
  log="$BATS_TEST_TMPDIR/ci.log"
  {
    for i in $(seq 1 50); do echo "ok line $i"; done
    printf '2026-09-27T10:00:00.123Z \033[31mError: boom\033[0m\n'
    for i in $(seq 51 100); do echo "ok line $i"; done
  } >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Error: boom"* ]]
  [[ "$output" != *$'\033'* ]]
  [[ "$output" != *"ok line 10"* ]]
  [[ "$output" == *"full log: $log (101 lines)"* ]]
}

@test "excerpt caps output and reports truncation" {
  log="$BATS_TEST_TMPDIR/many.log"
  for i in $(seq 1 200); do echo "test $i failed"; done >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 0 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"truncated: showing 10 of 200"* ]]
}

@test "excerpt ignores words that merely contain 'error'" {
  log="$BATS_TEST_TMPDIR/quiet.log"
  printf 'terrorist novel\nfailover configured\n' >"$log"
  run "$SCRIPTS/excerpt.sh" "$log"
  [[ "$output" == *"(no failure lines matched)"* ]]
}

# --- PR takeover: claims and intake -------------------------------------------------------

claim() { ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" "$SCRIPTS/pr-claim.sh" "$@" --repo o/r --pr 7; }

@test "claim is exclusive while fresh and reclaimable by its owner" {
  ORCHESTRATE_NOW=1000 run claim claim --owner A
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=1100 run claim claim --owner B
  [ "$status" -eq 3 ]
  [[ "$output" == *"held by A"* ]]
  ORCHESTRATE_NOW=1100 run claim claim --owner A
  [ "$status" -eq 0 ]
}

@test "stale claim is taken over; old owner can no longer heartbeat" {
  ORCHESTRATE_NOW=1000 claim claim --owner A --ttl 60
  ORCHESTRATE_NOW=2000 run claim claim --owner B --ttl 60
  [ "$status" -eq 0 ]
  [[ "$output" == *"took over stale claim from A"* ]]
  ORCHESTRATE_NOW=2001 run claim heartbeat --owner A
  [ "$status" -eq 3 ]
}

@test "release frees the claim only for its owner; state dir survives" {
  claim claim --owner A
  echo '{"fix_pass_consumed":true}' >"$(claim path --owner A)/state.json"
  claim release --owner B
  [[ "$(claim status --owner B)" == held* ]]
  claim release --owner A
  [ "$(claim status --owner B)" = unclaimed ]
  [ -f "$(claim path --owner B)/state.json" ]
}

# gh stub: serves $GH_FIXTURE for `gh pr list`, and records the args it was called with.
stub_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/gh.args"
cat "$GH_FIXTURE"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" GH_FIXTURE="$BATS_TEST_TMPDIR/prs.json"
  cat >"$GH_FIXTURE" <<'JSON'
[
 {"number":1,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/a","updatedAt":"2026-09-27T00:00:00Z","url":"u1"},
 {"number":2,"author":{"login":"someone"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/b","updatedAt":"2026-09-27T00:00:00Z","url":"u2"},
 {"number":3,"author":{"login":"octocat"},"isDraft":true,"isCrossRepository":false,"headRefName":"work/c","updatedAt":"2026-09-27T00:00:00Z","url":"u3"},
 {"number":4,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":true,"headRefName":"work/d","updatedAt":"2026-09-27T00:00:00Z","url":"u4"},
 {"number":5,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/e","updatedAt":"2026-09-27T11:55:00Z","url":"u5"},
 {"number":6,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/f","updatedAt":"2026-09-27T00:00:00Z","url":"u6"},
 {"number":7,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/g","updatedAt":"2026-09-27T00:00:00Z","url":"u7"}
]
JSON
}

intake() {
  cd "$REPO"
  ORCHESTRATE_AUTHOR=octocat ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 \
    "$SCRIPTS/pr-intake.sh" --repo o/r --owner ME "$@"
}

@test "intake only lists the configured author's PRs and classifies each" {
  stub_gh
  # 2026-09-27T12:00:00Z = 1790510400; PR 5 was updated 5 minutes earlier.
  ORCHESTRATE_NOW=1790510000 ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" "$SCRIPTS/pr-claim.sh" claim --repo o/r --pr 6 --owner OTHER
  ORCHESTRATE_NOW=1790510000 ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" "$SCRIPTS/pr-claim.sh" claim --repo o/r --pr 7 --owner ME
  git -C "$REPO" worktree add -q -b work/a "$BATS_TEST_TMPDIR/wt-a"
  echo dirty >>"$BATS_TEST_TMPDIR/wt-a/a.txt"
  run intake
  [ "$status" -eq 0 ]
  grep -q -- '--author octocat' "$BATS_TEST_TMPDIR/gh.args"
  [[ "$output" != *"work/b"* ]]
  [[ "$output" == *$'1\tbusy-local:'* ]]
  [[ "$output" == *$'3\tdraft'* ]]
  [[ "$output" == *$'4\tfork'* ]]
  [[ "$output" == *$'5\trecent-activity'* ]]
  [[ "$output" == *$'6\tclaimed:OTHER'* ]]
  [[ "$output" == *$'7\tmine'* ]]
}

@test "intake marks a quiet, unclaimed, clean PR eligible" {
  stub_gh
  run intake --include-drafts
  [[ "$output" == *$'1\teligible'* ]]
  [[ "$output" == *$'3\teligible'* ]]
}

# --- codex-lane-run.sh cross-lane guard ---
runner_env() {
  RUNNER="$SCRIPTS/../../../bin/codex-lane-run.sh"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
out=""; while (($#)); do [[ $1 == --output-last-message ]] && out=$2; shift; done
spec=$(cat); printf 'saw:%s\n' "$(printf '%s\n' "$spec" | sed -n 2p)" >"$out"
SH
  chmod +x "$FAKEBIN/codex"
  OTHER="$BATS_TEST_TMPDIR/other"; mkdir -p "$OTHER"
  RUNDIR="$BATS_TEST_TMPDIR/run"; mkdir -p "$RUNDIR"
}
run_lane() { PATH="$FAKEBIN:$PATH" HOME="$BATS_TEST_TMPDIR/home" "$RUNNER" --model gpt-6-luna --spec "$1" --final "$RUNDIR/final.md" --log "$RUNDIR/codex.jsonl" --cd "$REPO" --poll 1; }

@test "runner runs a spec whose first line names its own worktree, from a snapshot" {
  runner_env
  printf 'LANE-WORKTREE: %s\nmy task\n' "$(cd "$REPO" && pwd -P)" >"$RUNDIR/spec.md"
  run run_lane "$RUNDIR/spec.md"
  [ "$status" -eq 0 ]
  [ "$(cat "$RUNDIR/final.md")" = "saw:my task" ]
  [ "$(sed -n 2p "$RUNDIR/codex.jsonl.spec")" = "my task" ]
  [ "$(cat "$RUNDIR/codex.jsonl.exit")" = "0" ]
}

@test "runner refuses a spec naming another worktree (exit 64)" {
  runner_env
  printf 'LANE-WORKTREE: %s\nforeign task\n' "$OTHER" >"$RUNDIR/spec.md"
  run run_lane "$RUNDIR/spec.md"
  [ "$status" -eq 64 ]
  [[ "$output" == *"may belong to another lane"* ]]
  [ ! -e "$RUNDIR/final.md" ]
}

@test "runner refuses a spec without the LANE-WORKTREE header (exit 64)" {
  runner_env
  printf 'no header\n' >"$RUNDIR/spec.md"
  run run_lane "$RUNDIR/spec.md"
  [ "$status" -eq 64 ]
}

# --- campaign scripts: readiness, merge, main health, issues, lanes, device lock ---------------

# gh stub that answers by subcommand from fixture files and records every call.
stub_gh_router() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api user") echo '{"login":"me"}' ;;
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) cat "$FX/rules.json" ;;
  *graphql*) cat "$FX/threads.json" ;;
  "pr merge"*) [ -f "$FX/merge-fails" ] && { echo "blocked"; exit 1; }; echo MERGED >"$FX/merged" ;;
  "pr view"*) if [ -f "$FX/merged" ]; then cat "$FX/pr-merged.json"; else cat "$FX/pr.json"; fi ;;
  "pr list"*merged*) cat "$FX/prs-merged.json" ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "run list"*) cat "$FX/runs.json" ;;
  "issue list"*--label*) cat "$FX/pause.json" ;;
  "issue list"*) cat "$FX/issues.json" ;;
  "issue view"*) cat "$FX/issue.json" ;;
  "issue close"*) : ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
  echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' >"$FX/rules.json"
  echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' >"$FX/threads.json"
  echo '[]' >"$FX/pause.json"
  echo '[]' >"$FX/prs-merged.json"
}

pr_row() { # number author draft fork mergeable checks-json [labels-json]
  jq -cn --argjson n "$1" --arg a "$2" --argjson d "$3" --argjson f "$4" --arg m "$5" --argjson c "$6" --argjson l "${7:-[]}" \
    '{number:$n,author:{login:$a},isDraft:$d,isCrossRepository:$f,baseRefName:"main",headRefOid:("abcdef0123456789"+($n|tostring)),mergeable:$m,labels:$l,statusCheckRollup:$c}'
}
OKC='[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]'

@test "pr-ready classifies ready, waiting, blocked and skipped PRs" {
  stub_gh_router
  {
    pr_row 1 me false false MERGEABLE "$OKC"
    pr_row 2 me false false MERGEABLE '[{"name":"build","status":"IN_PROGRESS","conclusion":""}]'
    pr_row 3 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"lint","conclusion":"FAILURE"}]'
    pr_row 4 me false false CONFLICTING "$OKC"
    pr_row 5 me true false MERGEABLE "$OKC"
    pr_row 6 me false true MERGEABLE "$OKC"
    pr_row 7 other false false MERGEABLE "$OKC"
    pr_row 8 me false false MERGEABLE '[{"name":"lint","conclusion":"SUCCESS"}]'
    pr_row 9 me false false MERGEABLE "$OKC" '[{"name":"hold"}]'
    pr_row 10 me false false MERGEABLE '[{"name":"build","conclusion":"FAILURE","startedAt":"2026-09-27T01:00:00Z"},{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T02:00:00Z"}]'
    pr_row 11 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]'
    pr_row 12 me false false MERGEABLE '[{"name":"job (${{ matrix.os }})","conclusion":"CANCELLED","workflowName":"PR","startedAt":"2026-09-27T01:00:00Z"},{"name":"build","conclusion":"SUCCESS","workflowName":"PR","startedAt":"2026-09-27T02:00:00Z"}]'
    pr_row 13 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS","workflowName":"PR","startedAt":"2026-09-27T01:00:00Z"},{"name":"slow","conclusion":"CANCELLED","workflowName":"PR","startedAt":"2026-09-27T02:00:00Z"}]'
  } | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r --ignore-check sim
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tREADY'* ]]
  [[ "$output" == *$'2\tWAIT'*"pending:build"* ]]
  [[ "$output" == *$'3\tBLOCK'*"fail:lint"* ]]
  [[ "$output" == *$'4\tBLOCK'*"conflict"* ]]
  [[ "$output" == *$'5\tSKIP'*"draft"* ]]
  [[ "$output" == *$'6\tSKIP'*"fork"* ]]
  [[ "$output" != *$'\n7\t'* ]]
  [[ "$output" == *$'8\tBLOCK'*"missing-required:build"* ]]
  [[ "$output" == *$'9\tSKIP'*"hold"* ]]
  [[ "$output" == *$'10\tREADY'* ]]
  [[ "$output" == *$'11\tREADY'* ]]
  [[ "$output" == *$'12\tREADY'* ]]
  [[ "$output" == *$'13\tBLOCK'*"fail:slow"* ]]
  [[ "$output" == *"open=12 ready=4"* ]]
}

@test "pr-ready blocks an otherwise ready PR with an unresolved review thread" {
  stub_gh_router
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false},{"isResolved":false,"isOutdated":true}]}}}}}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'1\tBLOCK'*"threads=1"* ]]
}

merge_fixture() {
  stub_gh_router
  echo '{"state":"OPEN","isDraft":false,"isCrossRepository":false,"headRefOid":"abcdef0123","author":{"login":"me"},"mergeable":"MERGEABLE"}' >"$FX/pr.json"
  echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}' >"$FX/pr-merged.json"
  echo '[{"number":1}]' >"$FX/prs.json"
}

@test "pr-merge merges a verified head and logs it" {
  merge_fixture
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 0 ]
  [[ "$output" == "merged 1 feedface" ]]
  grep -q 'pr merge 1 --repo o/r --squash$' "$FX/calls"
  grep -q 'merged feedface' "$ORCHESTRATE_STATE_DIR/o__r/merges.log"
}

@test "pr-merge refuses a moved head, a foreign author, and a red default branch" {
  merge_fixture
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head 1234567
  [ "$status" -eq 3 ]
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --author someone
  [ "$status" -eq 3 ]
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red abc" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 4 ]
  ! grep -q 'pr merge' "$FX/calls"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --main-fix
  [ "$status" -eq 0 ]
}

@test "pr-merge allows --admin only in the fast path and only with evidence" {
  merge_fixture
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin
  [ "$status" -eq 6 ]
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --evidence "known flake: sim timeout"
  [ "$status" -eq 6 ]
  [[ "$output" == *"fast-path only"* ]]
  ! grep -q 'pr merge' "$FX/calls"
  ORCHESTRATE_FAST_PATH_OVER=0 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --evidence "known flake: sim timeout"
  [ "$status" -eq 0 ]
  grep -q 'pr merge 1 --repo o/r --squash --admin' "$FX/calls"
}

@test "pr-merge reports a merge GitHub rejected" {
  merge_fixture
  touch "$FX/merge-fails"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 5 ]
}

@test "main-health sets and clears MAIN_RED from the newest completed run per workflow" {
  stub_gh_router
  cat >"$FX/runs.json" <<'JSON'
[{"workflowName":"On Merge","status":"completed","conclusion":"success","headSha":"aaaaaaaaaaaa","databaseId":1,"createdAt":"2026-09-27T01:00:00Z"},
 {"workflowName":"On Merge","status":"completed","conclusion":"failure","headSha":"bbbbbbbbbbbb","databaseId":2,"createdAt":"2026-09-27T02:00:00Z"},
 {"workflowName":"On Merge","status":"in_progress","conclusion":"","headSha":"cccccccccccc","databaseId":3,"createdAt":"2026-09-27T03:00:00Z"},
 {"workflowName":"Badges","status":"completed","conclusion":"failure","headSha":"bbbbbbbbbbbb","databaseId":4,"createdAt":"2026-09-27T02:00:00Z"}]
JSON
  run "$SCRIPTS/main-health.sh" --repo o/r --ignore-workflow Badges
  [ "$status" -eq 1 ]
  [[ "$output" == "red bbbbbbbbb On Merge=failure(2)" ]]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
  jq '.[1].conclusion="success"' "$FX/runs.json" >"$FX/r2" && mv "$FX/r2" "$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --workflow "On Merge"
  [ "$status" -eq 0 ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
  echo '[]' >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r
  [ "$status" -eq 2 ]
}

@test "campaign lanes follow the three tiers and accept overrides" {
  [ "$("$SCRIPTS/campaign.sh" lanes --bots idle --verify idle)" = 16 ]
  [ "$("$SCRIPTS/campaign.sh" lanes --bots working --verify idle)" = 12 ]
  [ "$("$SCRIPTS/campaign.sh" lanes --bots idle --verify running)" = 4 ]
  [ "$(ORCHESTRATE_LANES=8,6,2 "$SCRIPTS/campaign.sh" lanes --bots working --verify idle)" = 6 ]
  [ "$("$SCRIPTS/campaign.sh" lanes --lanes 10,5,1 --bots idle --verify running)" = 1 ]
}

@test "campaign status reports merge mode, verification due, pause and main state" {
  stub_gh_router
  jq -n '[range(0;21)|{number:.}]' >"$FX/prs.json"
  jq -n '[range(0;16)|{number:.}]' >"$FX/prs-merged.json"
  run "$SCRIPTS/campaign.sh" status --repo o/r --bots idle
  [ "$status" -eq 0 ]
  [[ "$output" == *"paused=no"* ]]
  [[ "$output" == *"open_prs=21"* ]]
  [[ "$output" == *"merge_mode=fast"* ]]
  [[ "$output" == *"main=ok"* ]]
  [[ "$output" == *"verification_due=yes"* ]]
  [[ "$output" == *"lanes=16"* ]]
  jq -n '[range(0;20)|{number:.}]' >"$FX/prs.json"
  echo '[{"number":9}]' >"$FX/pause.json"
  run "$SCRIPTS/campaign.sh" status --repo o/r --verify-every 20
  [[ "$output" == *"merge_mode=conservative"* ]]
  [[ "$output" == *"verification_due=no"* ]]
  [[ "$output" == *"paused=yes"* ]]
  "$SCRIPTS/campaign.sh" verified --repo o/r --sha abc123
  [ "$(jq -r .last_verification_sha "$ORCHESTRATE_STATE_DIR/o__r/campaign.json")" = abc123 ]
}

@test "issues-ranked puts priority bugs first, then bugs, newest first, and marks issues in a PR" {
  stub_gh_router
  echo '[{"number":50,"closingIssuesReferences":[{"number":3}]}]' >"$FX/prs.json"
  cat >"$FX/issues.json" <<'JSON'
[{"number":1,"title":"docs typo","labels":[],"updatedAt":"2026-09-27T09:00:00Z"},
 {"number":2,"title":"old bug","labels":[{"name":"bug"}],"updatedAt":"2026-09-25T09:00:00Z"},
 {"number":3,"title":"new bug","labels":[{"name":"bug"}],"updatedAt":"2026-09-27T08:00:00Z"},
 {"number":4,"title":"fold bug","labels":[{"name":"bug"},{"name":"foldable"}],"updatedAt":"2026-09-24T09:00:00Z"},
 {"number":5,"title":"stuck","labels":[{"name":"bug"},{"name":"blocked"}],"updatedAt":"2026-09-27T09:30:00Z"}]
JSON
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --priority-label foldable
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')" = "4 3 2 1 " ]
  [[ "$output" == *$'3\tbug\t50'* ]]
  grep -q 'updated:>=2026-09-20' "$FX/calls"
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --skip-in-pr
  [ "$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')" = "2 4 1 " ]
}

@test "issue-candidates finds fixed-by-merged-PR and duplicate-title leads" {
  stub_gh_router
  cat >"$FX/issues.json" <<'JSON'
[{"number":10,"title":"tapOn hangs when the keyboard is open"},
 {"number":11,"title":"tapOn hangs when keyboard open on foldable"},
 {"number":12,"title":"observe returns stale hierarchy"}]
JSON
  echo '[{"number":90,"mergedAt":"2026-09-26T00:00:00Z","body":"Fixes #12 and refs #10","closingIssuesReferences":[{"number":11}]}]' >"$FX/prs-merged.json"
  run "$SCRIPTS/issue-candidates.sh" fixed --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'11\t90\t'*$'\tlinked\t'* ]]
  [[ "$output" == *$'12\t90\t'*$'\tbody\t'* ]]
  [[ "$output" != $'10\t'* ]]
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]
  [[ "$output" == *$'\t10\t11\t'* ]]
}

@test "issue-close requires verified evidence and refuses protected or unverifiable closes" {
  stub_gh_router
  echo '{"state":"OPEN","labels":[]}' >"$FX/issue.json"
  echo '{"state":"OPEN"}' >"$FX/pr.json"
  E="src/x.ts:10 now awaits the write; the race is gone"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "$E"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not merged"* ]]
  echo '{"state":"MERGED"}' >"$FX/pr.json"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "$E" --dry-run
  [ "$status" -eq 0 ]
  ! grep -q 'issue close' "$FX/calls"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "$E"
  [ "$status" -eq 0 ]
  grep -q 'issue close 5 --repo o/r --reason completed' "$FX/calls"
  grep -q 'issue=5' "$ORCHESTRATE_STATE_DIR/o__r/hygiene-actions.log"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 5 --evidence "$E"
  [ "$status" -eq 3 ]
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 6 --evidence "$E"
  [ "$status" -eq 0 ]
  grep -q 'issue close 5 --repo o/r --duplicate-of 6' "$FX/calls"
  echo '{"state":"OPEN","labels":[{"name":"epic"}]}' >"$FX/issue.json"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 6 --evidence "$E"
  [ "$status" -eq 3 ]
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "short"
  [ "$status" -eq 2 ]
}

@test "device lock is exclusive while its holder is alive and reclaimable when stale" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  [ "$(lock status)" = free ]
  ORCHESTRATE_NOW=1000 run lock claim --name verify --pid $$
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=1100 run lock claim --name explorer --pid $$
  [ "$status" -eq 3 ]
  ORCHESTRATE_NOW=1100 run lock release --name explorer
  [[ "$output" == "not held by explorer" ]]
  ORCHESTRATE_NOW=$((1000 + 10 * 3600)) run lock claim --name explorer --pid $$
  [ "$status" -eq 0 ]
  echo "999999 1000 ghost" >"$L"
  ORCHESTRATE_NOW=1100 run lock claim --name verify --pid $$
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=1100 lock release --name verify
  [ "$(lock status)" = free ]
}
