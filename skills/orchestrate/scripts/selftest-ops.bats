#!/usr/bin/env bats
# Self-test for the orchestrate helper scripts (ops). Shared helpers: selftest_helper.bash.

setup() {
  load test_helper
  load selftest_helper
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

@test "main-health keeps the hold when a selected workflow has no completed evidence" {
  stub_gh_router
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red old" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  { run_json Build completed success aaaaaaaaaaaa 1 2026-09-27T01:00:00Z
    run_json Tests in_progress "" bbbbbbbbbbbb 2 2026-09-27T02:00:00Z; } | jq -s . >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Tests
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Tests(pending)" ]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Deploy
  [ "$output" = "unknown missing=Deploy(no-run)" ]
  # The pending-only control stays unknown.
  run_json Tests in_progress "" bbbbbbbbbbbb 2 2026-09-27T02:00:00Z | jq -s . >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main
  [ "$status" -eq 2 ]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
}

@test "main-health clears the hold only with every selected workflow green, naming each SHA" {
  stub_gh_router
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red old" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  { run_json Build completed success aaaaaaaaaaaa 1 2026-09-27T01:00:00Z
    run_json Tests completed success bbbbbbbbbbbb 2 2026-09-27T02:00:00Z
    run_json Badges completed failure bbbbbbbbbbbb 3 2026-09-27T02:00:00Z; } | jq -s . >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Tests --ignore-workflow Badges
  [ "$status" -eq 0 ]
  [ "$output" = "green bbbbbbbbb Build@aaaaaaaaa,Tests@bbbbbbbbb mixed-heads" ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
  # Ignored workflows stay advisory; the same failure in a selected workflow is red.
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --ignore-workflow Badges
  [ "$status" -eq 0 ]
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Badges
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Badges=failure(3)" ]
}

@test "main-health tells an exhausted run window from a missing workflow, and an unreadable list from red" {
  stub_gh_router
  for i in 1 2 3; do run_json Build completed success "aaaaaaaaaa0$i" "$i" "2026-09-27T0$i:00:00Z"; done | jq -s . >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Nightly --limit 3
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Nightly(not-in-window)" ]
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Nightly --limit 10
  [ "$output" = "unknown missing=Nightly(no-run)" ]
  echo 'not json' >"$FX/runs.json"
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red old" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown run list unreadable"* ]]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
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

@test "campaign wrap-up stops new lanes, keeps the rest of status, and reports when drained" {
  stub_gh_router
  jq -n '[range(0;3)|{number:.}]' >"$FX/prs.json"
  run "$SCRIPTS/campaign.sh" wrap-up on --repo o/r
  [ "$output" = "wrap-up on" ]
  [ "$("$SCRIPTS/campaign.sh" lanes --repo o/r --bots idle --verify idle)" = 0 ]
  [ "$("$SCRIPTS/campaign.sh" lanes --bots idle --verify idle)" = 16 ]   # no repo: the pure cap
  S="$ORCHESTRATE_STATE_DIR/o__r"
  printf 'wt-a\tlane/a\t12\tsrc/a.ts\tsol\tawaiting-ci\nwt-b\tlane/b\t13\tsrc/b.ts\tsol\tmerged\n' >"$S/lanes.tsv"
  printf '# Decisions\n- [ ] keep the v1 API?\n- [x] drop Node 18\n- [ ] rename the flag?\n' >"$S/decisions.md"
  run "$SCRIPTS/campaign.sh" status --repo o/r --bots idle
  [[ "$output" == *"wrap_up=on"* ]]
  [[ "$output" == *"lanes=0"* ]]
  [[ "$output" == *"active_lanes=1"* ]]
  [[ "$output" == *"decisions_open=2"* ]]
  [[ "$output" == *"drained=no"* ]]
  [[ "$output" == *"main=ok"* && "$output" == *"merge_mode="* ]]
  echo '[]' >"$FX/prs.json"
  printf 'wt-a\tlane/a\t12\tsrc/a.ts\tsol\tmerged\n' >"$S/lanes.tsv"
  run "$SCRIPTS/campaign.sh" status --repo o/r
  [[ "$output" == *"drained=yes"* ]]
  run "$SCRIPTS/campaign.sh" wrap-up off --repo o/r
  run "$SCRIPTS/campaign.sh" status --repo o/r --bots idle
  [[ "$output" == *"wrap_up=off"* && "$output" == *"lanes=16"* ]]
  [[ "$output" != *"drained="* ]]
  run "$SCRIPTS/campaign.sh" wrap-up maybe --repo o/r
  [ "$status" -eq 2 ]
}

@test "lane-claim refuses a lane whose issue or files another lane or an open PR already has" {
  stub_gh_router
  echo '[{"number":45,"title":"Fix login crash (#12)","body":"","closingIssuesReferences":[],"files":[{"path":"src/auth/login.ts"}]},
         {"number":46,"title":"Docs","body":"Fixes #30","closingIssuesReferences":[{"number":31}],"files":[{"path":"docs/a.md"}]}]' >"$FX/prs.json"
  lc() { run "$SCRIPTS/lane-claim.sh" "$@" --repo o/r; }
  lc add --worktree wt-a --branch lane/a --issues 20 --files src/cart/,lib/x.ts --agent sol
  [ "$status" -eq 0 ]
  # Same issue as an active lane; a file under a lane's directory; an issue an open PR covers
  # (closing reference, or "#N" in title or body); a file an open PR touches.
  lc check --issues 20 --files other.ts
  [ "$status" -eq 3 ]; [[ "$output" == "conflict: lane wt-a has issue 20" ]]
  lc check --issues 99 --files src/cart/total.ts
  [ "$status" -eq 3 ]; [[ "$output" == "conflict: lane wt-a owns src/cart/total.ts" ]]
  lc check --issues 31 --files z.ts
  [[ "$output" == "conflict: PR 46 covers issue 31" ]]
  lc check --issues 12 --files z.ts
  [[ "$output" == "conflict: PR 45 covers issue 12" ]]
  lc check --issues 30 --files z.ts
  [[ "$output" == "conflict: PR 46 covers issue 30" ]]
  lc check --issues 1 --files src/auth/
  [[ "$output" == "conflict: PR 45 touches src/auth/" ]]
  # #12 does not match issue 1 or 123; disjoint work passes and add refuses a conflict.
  lc check --issues 123 --files src/other.ts
  [ "$status" -eq 0 ]; [ "$output" = ok ]
  lc add --worktree wt-b --branch lane/b --issues 20 --files q.ts
  [ "$status" -eq 3 ]
  [ "$(grep -c . "$ORCHESTRATE_STATE_DIR/o__r/lanes.tsv")" -eq 1 ]
  # A finished lane no longer blocks.
  lc set --worktree wt-a --status merged
  [ "$status" -eq 0 ]
  lc check --issues 20 --files src/cart/total.ts
  [ "$status" -eq 0 ]
  lc set --worktree nope --status merged
  [ "$status" -eq 3 ]
}

@test "lane-claim gives no verdict when open PRs cannot be read" {
  stub_gh_router
  echo 'not json' >"$FX/prs.json"
  run "$SCRIPTS/lane-claim.sh" add --worktree wt-a --branch lane/a --issues 20 --files a.ts --repo o/r
  [ "$status" -eq 4 ]
  [ ! -s "$ORCHESTRATE_STATE_DIR/o__r/lanes.tsv" ]
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
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -vc '^# ')" = 1 ]
  [[ "$output" == *$'0.8\t10\t11\t'* ]]
  [[ "$output" == *"# shown 1 of 1 leads (0 clusters, 1 pairs; 0 over the per-issue cap); all: $ORCHESTRATE_STATE_DIR/o__r/candidates/dupes-"*.tsv ]]
}

@test "dupes collapses a repetitive cluster into one bounded row and keeps unrelated leads" {
  stub_gh_router
  dupes_fixture 100 "$DIVERSE"
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 2000 ]
  [ "$(printf '%s\n' "$output" | grep -vc '^# ')" = 3 ]
  first=${output%%$'\n'*}
  [[ "$first" == $'1\t1\t2,3,4,5,6,7,8,9,10,11,+89\tFix shared device session recovery failure\t(same title words)' ]]
  [[ "$output" == *$'\t901\t902\t'* ]]
  [[ "$output" == *$'\t903\t904\t'* ]]
  [[ "$output" == *"# shown 3 of 3 leads (1 clusters, 2 pairs"* ]]
  full=$(printf '%s\n' "$output" | sed -n 's/^# .*; all: //p')
  [ -f "$full" ]
  [[ "$(head -1 "$full")" == $'1\t1\t2,3,'* ]]
}

@test "dupes stays bounded and stable at the 400-issue fetch limit" {
  stub_gh_router
  dupes_fixture 400 "$DIVERSE"
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 2000 ]
  first=$output
  ORCHESTRATE_NOW=1790510401 run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$(printf '%s\n' "$output" | grep -v '^# ')" = "$(printf '%s\n' "$first" | grep -v '^# ')" ]
}

@test "dupes caps rows per issue and in total, and reports what it omitted" {
  stub_gh_router
  # One hub title that shares most words with each of six distinct variants.
  jq -n '[{number: 1, title: "alpha beta gamma delta epsilon"}]
    + [range(2; 8) | {number: ., title: "alpha beta gamma delta variant\(.)"}]' >"$FX/issues.json"
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r --per-issue 2
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -v '^# ' | cut -f2,3 | grep -c '^1	')" = 2 ]
  [[ "$output" == *"over the per-issue cap"* ]]
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r --limit 3
  [ "$(printf '%s\n' "$output" | grep -vc '^# ')" = 3 ]
  [[ "$output" == *"# shown 3 of "* ]]
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
  run ! grep -q 'issue close' "$FX/calls"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "$E"
  [ "$status" -eq 0 ]
  grep -q 'issue close 5 --repo o/r --reason completed' "$FX/calls"
  grep -q 'issue=5' "$ORCHESTRATE_STATE_DIR/o__r/hygiene-actions.log"
  rm -f "$FX/closed-5" "$FX/comments-5"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 5 --evidence "$E"
  [ "$status" -eq 3 ]
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 6 --evidence "$E"
  [ "$status" -eq 0 ]
  grep -q 'issue close 5 --repo o/r --duplicate-of 6' "$FX/calls"
  rm -f "$FX/closed-5" "$FX/comments-5"
  echo '{"state":"OPEN","labels":[{"name":"epic"}]}' >"$FX/issue.json"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 6 --evidence "$E"
  [ "$status" -eq 3 ]
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "short"
  [ "$status" -eq 2 ]
}

@test "issue-close finishes a partial close without a second comment, and reconciles a lost answer" {
  stub_gh_router
  export ORCHESTRATE_READ_SLEEP=0
  echo '{"state":"OPEN","labels":[]}' >"$FX/issue.json"
  echo '{"state":"MERGED"}' >"$FX/pr.json"
  E="src/x.ts:10 now awaits the write; the race is gone"
  close() { run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "$E"; }
  # Comment posted, close failed: rerun closes without commenting again.
  echo comment-only >"$FX/close-mode"
  close
  [ "$status" -eq 5 ]
  [[ "$output" == *"without a second comment"* ]]
  echo ok >"$FX/close-mode"
  close
  [ "$status" -eq 0 ]
  [ "$(jq length "$FX/comments-5")" -eq 1 ]
  [ "$(grep -c 'issue=5' "$ORCHESTRATE_STATE_DIR/o__r/hygiene-actions.log")" -eq 1 ]
  # Success with a lost response: read back as closed, logged once.
  rm -f "$FX/closed-5" "$FX/comments-5"; : >"$ORCHESTRATE_STATE_DIR/o__r/hygiene-actions.log"
  echo lost >"$FX/close-mode"
  close
  [ "$status" -eq 0 ]
  # Success, then the readback fails: unknown, and the rerun reconciles without closing again.
  rm -f "$FX/closed-5" "$FX/comments-5"; : >"$ORCHESTRATE_STATE_DIR/o__r/hygiene-actions.log"
  echo no-readback >"$FX/close-mode"
  close
  [ "$status" -eq 9 ]
  [ ! -s "$ORCHESTRATE_STATE_DIR/o__r/hygiene-actions.log" ]
  : >"$FX/calls"
  close
  [ "$status" -eq 0 ]
  [[ "$output" == *"(earlier attempt)"* ]]
  run ! grep -q 'issue close' "$FX/calls"
  [ "$(jq length "$FX/comments-5")" -eq 1 ]
  [ "$(grep -c 'issue=5' "$ORCHESTRATE_STATE_DIR/o__r/hygiene-actions.log")" -eq 1 ]
  # And once done, a further run refuses: the issue is closed and nothing is pending.
  close
  [ "$status" -eq 3 ]
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

@test "device lock claim prints a token; release by token works for a dead-PID holder" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  # claim from a subshell: its PID is gone by the time release runs
  out=$( (lock claim --name lane1 --pid "$BASHPID") )
  [ "${out%%$'\n'*}" = claimed ]
  tok=$(echo "$out" | sed -n 's/^token //p')
  [ -n "$tok" ]
  run lock release --name other --token wrong
  [[ "$output" == "token does not match the holder" ]]
  [ -f "$L" ]
  run lock release --token "$tok"
  [[ "$output" == released ]]
  [ "$(lock status)" = free ]
}

@test "device lock release by name works when the recorded holder PID is dead" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  (lock claim --name lane2 --pid "$BASHPID" >/dev/null)
  run lock status
  [[ "$output" == *"name=lane2"*"live=no"* ]]
  run lock release --name lane2
  [[ "$output" == released ]]
  [ "$(lock status)" = free ]
}

@test "device lock stale dead-PID holder is reclaimable by another name" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  printf '999999 1000 finished-lane\n' >"$L"
  ORCHESTRATE_NOW=1100 run lock claim --name next --pid $$
  [ "$status" -eq 0 ]
  [[ "$output" == claimed* ]]
}

@test "device lock treats a reused PID (start time mismatch) as stale but a matching one as live" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  run lock claim --name holder --pid $$
  [ "$status" -eq 0 ]
  run lock claim --name rival --pid $$
  [ "$status" -eq 3 ]
  # simulate PID reuse: same live PID, different recorded start time
  sed -i.bak 's/ start=.*/ start=Mon Jan 1 00:00:00 1990/' "$L"
  run lock status
  [[ "$output" == *"live=no"* ]]
  run lock claim --name rival --pid $$
  [ "$status" -eq 0 ]
}

@test "device lock legacy single-line format is still read as live while its PID runs" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  printf '%s %s legacy\n' "$$" "$(date +%s)" >"$L"
  run lock claim --name rival --pid $$
  [ "$status" -eq 3 ]
  run lock release --name legacy
  [[ "$output" == released ]]
}

@test "device lock --no-pid holds by age only and stays exclusive" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  ORCHESTRATE_NOW=1000 run lock claim --name sub --no-pid
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=1100 run lock claim --name rival --pid $$
  [ "$status" -eq 3 ]
  ORCHESTRATE_NOW=$((1000 + 10 * 3600)) run lock claim --name rival --pid $$
  [ "$status" -eq 0 ]
}

@test "device lock resolves its path from --state-dir or the env var outside any repo" {
  D="$BATS_TEST_TMPDIR/sd"
  cd "$BATS_TEST_TMPDIR"
  run "$SCRIPTS/device-lock.sh" claim --name a --pid $$ --state-dir "$D"
  [ "$status" -eq 0 ]
  [ -f "$D/device.lock" ]
  ORCHESTRATE_DEVICE_LOCK_DIR="$D" run "$SCRIPTS/device-lock.sh" status
  [[ "$output" == "held name=a"* ]]
  ORCHESTRATE_DEVICE_LOCK_DIR="$D" run "$SCRIPTS/device-lock.sh" claim --name b --pid $$
  [ "$status" -eq 3 ]
  # no repo, no dir: falls back to the global state dir without needing gh
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/st" run "$SCRIPTS/device-lock.sh" claim --name c --pid $$
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/st/device.lock" ]
}

@test "writing validation logs into the checkout changes the fingerprint; validate.sh writes outside it" {
  before=$(fp)
  mkdir -p "$REPO/scratch"; echo "all tests pass" >"$REPO/scratch/validate.log"
  [ "$(fp)" != "$before" ]
  rm -r "$REPO/scratch"
  run val run --cmd "true" --runner validator --independent
  [ "$status" -eq 0 ]
  [[ "$output" == "PASS exit=0 key=v2|"* ]]
  [ "$(fp)" = "$before" ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

@test "an independent passing receipt is reused without re-running; a source change needs a fresh run" {
  val run --cmd "grep -q one a.txt" --runner validator --independent >/dev/null
  run val check --cmd "grep -q one a.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "reuse "*"runner=validator"* ]]
  receipt=$(printf '%s' "$output" | awk '{print $2}')
  jq -e '.schema == 1 and .result == "pass" and .exit == 0 and .verification == "independent"
         and .fingerprint_before == .fingerprint_after and (.log | length > 0)' "$receipt"
  echo two >"$REPO/a.txt"
  run val check --cmd "grep -q one a.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == "fresh-needed: no receipt"* ]]
}

@test "the declared environment is part of the receipt key" {
  NODE_ENV=development val run --cmd 'test "$NODE_ENV" = development' --env NODE_ENV --runner v --independent >/dev/null
  NODE_ENV=development run val check --cmd 'test "$NODE_ENV" = development' --env NODE_ENV
  [ "$status" -eq 0 ]
  NODE_ENV=production run val check --cmd 'test "$NODE_ENV" = development' --env NODE_ENV
  [ "$status" -eq 1 ]
  NODE_ENV=production run val run --cmd 'test "$NODE_ENV" = development' --env NODE_ENV --runner v --independent
  [ "$status" -eq 1 ]
  [[ "$output" == FAIL* ]]
}

@test "failures carry a bounded excerpt and are never reused" {
  run val run --cmd 'for i in $(seq 1 5000); do echo "case $i failed: boom"; done; exit 3' --runner v --independent
  [ "$status" -eq 1 ]
  [[ "$output" == "FAIL exit=3 "* ]]
  [[ "$output" == *"full log: "* ]]
  [ "${#output}" -lt 6000 ]
  run val check --cmd 'for i in $(seq 1 5000); do echo "case $i failed: boom"; done; exit 3'
  [ "$status" -eq 1 ]
  [[ "$output" == *"last result was fail (exit 3)"* ]]
}

@test "self-reported, partial, stale and tree-changing receipts need a fresh run" {
  val run --cmd "true" --runner codex >/dev/null
  run val check --cmd "true"
  [ "$status" -eq 1 ]
  [[ "$output" == *"self-reported"* ]]
  ORCHESTRATE_NOW=1000 val run --cmd "true" --runner v --independent >/dev/null
  ORCHESTRATE_NOW=1100 run val check --cmd "true" --max-age 60
  [[ "$output" == *"100s old"* ]]
  ORCHESTRATE_NOW=1050 run val check --cmd "true" --max-age 60
  [ "$status" -eq 0 ]
  receipt=$(printf '%s' "$output" | awk '{print $2}')
  jq 'del(.finished_epoch)' "$receipt" >"$receipt.tmp" && mv "$receipt.tmp" "$receipt"
  run val check --cmd "true"
  [[ "$output" == *"partial receipt"* ]]
  echo '{"schema":' >"$receipt"
  run val check --cmd "true"
  [[ "$output" == *"unreadable receipt"* ]]
  run val run --cmd "echo new >new.txt" --runner v --independent
  [ "$status" -eq 3 ]
  [[ "$output" == VOID* ]]
}

@test "validate.sh refuses a receipt store inside the checkout" {
  run "$SCRIPTS/validate.sh" run --dir "$REPO" --cmd true --runner v --store "$REPO/scratch"
  [ "$status" -eq 2 ]
  [[ "$output" == *"inside the checkout"* ]]
  [ ! -e "$REPO/scratch" ]
}
