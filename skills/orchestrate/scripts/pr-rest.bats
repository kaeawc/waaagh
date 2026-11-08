#!/usr/bin/env bats
# The PR side without GraphQL (#109): pr-ready.sh, gh-snapshot.sh and lane-claim.sh against a gh
# that refuses GraphQL with the cloud-session 403 and serves REST shapes (rest_stub.bash), built
# from the same fixtures as the GraphQL suites (selftest-pr, merge-selection, pr-ready-pages), and
# gh-rest-pr.sh's own parsing. Run: bats scripts/pr-rest.bats

setup() {
  load test_helper
  load selftest_helper
  load rest_stub
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  stub_gh_router
  rest_wrap
}

verdict_both() { # checks... -> both paths agree; prints the REST verdict and detail
  printf '%s\n' "$@" | jq -s . >"$FX/checks.json"
  pr_row 1 me false false MERGEABLE "$(cat "$FX/checks.json")" | jq -s . >"$FX/prs.json"
  both --repo o/r --no-threads >/dev/null || return 1
  printf '%s\n' "$output" | awk -F'\t' '$1 == 1 { print $2 "\t" $6 }'
}

# --- the selftest-pr fixtures, through both paths -------------------------------------------

@test "rest: ready, waiting, blocked and skipped PRs classify as over GraphQL" {
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
    pr_row 10 me false false MERGEABLE '[{"name":"build","conclusion":"FAILURE","startedAt":"2026-09-27T01:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/50/job/500"},{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T02:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/50/job/501"}]'
    pr_row 11 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]'
    pr_row 12 me false false MERGEABLE '[{"name":"job (${{ matrix.os }})","conclusion":"CANCELLED","workflowName":"PR","startedAt":"2026-09-27T01:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/60/job/600"},{"name":"build","conclusion":"SUCCESS","workflowName":"PR","startedAt":"2026-09-27T02:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/61/job/610"}]'
    pr_row 13 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS","workflowName":"PR","startedAt":"2026-09-27T01:00:00Z"},{"name":"slow","conclusion":"CANCELLED","workflowName":"PR","startedAt":"2026-09-27T02:00:00Z"}]'
    pr_row 14 me false false UNKNOWN '[{"name":"build","status":"IN_PROGRESS"},{"name":"test","conclusion":"FAILURE"}]'
  } | jq -s . >"$FX/prs.json"
  both --repo o/r --ignore-check sim
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tREADY'* ]]
  [[ "$output" == *$'2\tWAIT'*"pending:build"* ]]
  [[ "$output" == *$'4\tBLOCK'*"conflict"* ]]
  [[ "$output" == *$'5\tSKIP\tabcdef012\tUNKNOWN\t0\tdraft'* ]]   # not read over REST
  [[ "$output" == *$'12\tREADY'* ]]
  [[ "$output" == *$'14\tBLOCK\t'*$'\tfail:test pending:build mergeable=UNKNOWN'* ]]
  [[ "$output" == *"open=13 ready=4 ready-but-skipped=1 skipped-by=hold:1 api=rest"* ]]
  # One refused GraphQL list, one REST page, and no per-PR read for drafts, forks or other authors.
  [ "$(grep -c '^pr list' "$FX/rest-calls")" -eq 1 ]
  [ "$(grep -c 'pulls?state=open' "$FX/rest-calls")" -eq 1 ]
  ! grep -qE 'pulls/(5|6|7)( |$)|abcdef0123456789(5|6|7)/' "$FX/rest-calls"
  # Workflow names are read only for heads whose checks name an Actions run.
  [ "$(grep -c 'actions/runs?head_sha=' "$FX/rest-calls")" -eq 2 ]
}

@test "rest: only proven replacements supersede a check, as over GraphQL" {
  echo '[]' >"$FX/rules.json"
  T1=2026-09-27T01:00:00Z T2=2026-09-27T02:00:00Z
  [ "$(verdict_both "$(check unit CANCELLED CI $T1 70 700)" "$(check lint SUCCESS CI $T2 70 701)")" = $'BLOCK\tfail:unit' ]
  [ "$(verdict_both "$(check unit CANCELLED CI $T1)" "$(check lint SUCCESS CI $T2)")" = $'BLOCK\tfail:unit' ]
  [ "$(verdict_both "$(check test FAILURE Linux $T1 71 710)" "$(check test SUCCESS Mac $T2 72 720)")" = $'BLOCK\tfail:test' ]
  [ "$(verdict_both "$(check test FAILURE "" $T1 "" "" StatusContext)" "$(check test SUCCESS CI $T2 73 730)")" = $'BLOCK\tfail:test' ]
  [ "$(verdict_both "$(check unit FAILURE CI $T2 74 740)" "$(check unit SUCCESS CI $T2 74 741)")" = $'READY\t-' ]
  [ "$(verdict_both "$(check unit CANCELLED CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)")" = $'READY\t-' ]
  [ "$(verdict_both "$(check unit FAILURE CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)")" = $'BLOCK\tfail:unit' ]
  [ "$(verdict_both "$(check unit FAILURE CI $T1 77 770)" "$(check e2e FAILURE CI $T1 77 771)" "$(check unit SUCCESS CI $T2 77 772)")" = $'BLOCK\tfail:e2e' ]
  [ "$(verdict_both "$(check build FAILURE CI $T1)" "$(check build SUCCESS CI $T1)")" = $'BLOCK\tfail:build' ]
  [ "$(verdict_both "$(check 'job (${{ matrix.os }})' CANCELLED PR $T1)" "$(check build SUCCESS PR $T2)")" = $'BLOCK\tfail:job (${{ matrix.os }})' ]
  old=$(jq -cn '{__typename: "StatusContext", context: "ci/legacy", state: "FAILURE", startedAt: "2026-09-27T01:00:00Z"}')
  new=$(jq -cn '{__typename: "StatusContext", context: "ci/legacy", state: "SUCCESS", startedAt: "2026-09-27T02:00:00Z"}')
  [ "$(verdict_both "$old" "$new")" = $'READY\t-' ]
}

@test "rest: review threads block, fail closed and follow pages as over GraphQL" {
  { pr_row 1 me false false MERGEABLE "$OKC"; pr_row 2 me false false MERGEABLE "$OKC"; pr_row 3 me false false MERGEABLE "$OKC"
    pr_row 4 me false false MERGEABLE "$OKC"; pr_row 5 me false false MERGEABLE '[{"name":"test","conclusion":"FAILURE"}]'; } |
    jq -s . >"$FX/prs.json"
  jq -n '{"1": [{isResolved: false, isOutdated: false}, {isResolved: false, isOutdated: true}], "2": "null", "3": "more",
          "4": {pages: [[range(0; 100) | {isResolved: true, isOutdated: false}], [{isResolved: false, isOutdated: false}]]},
          "5": [{isResolved: false, isOutdated: false}]}' >"$FX/threads.json"
  both --repo o/r
  [[ "$output" == *$'1\tBLOCK\t'*$'\tthreads=1'* ]]
  [[ "$output" == *$'2\tBLOCK\t'*"threads=unknown"* ]]
  [[ "$output" == *$'3\tBLOCK\t'*"threads=unknown"* ]]
  [[ "$output" == *$'4\tBLOCK\t'*$'\tthreads=1'* ]]
  [[ "$output" == *$'5\tBLOCK\t'*"fail:test missing-required:build few-checks=0 threads=1"* ]]
  grep -q 'pulls/1/ccr/review_threads' "$FX/rest-calls"
  # The same answers in the other shapes the undocumented route may use.
  for shape in snake wrapped; do
    echo "$shape" >"$FX/thread-shape"
    both --repo o/r
    [[ "$output" == *$'1\tBLOCK\t'*$'\tthreads=1'* ]]
  done
  # Every thread read failing: nothing is READY.
  echo '{}' >"$FX/threads.json"; rm -f "$FX/thread-shape"
  touch "$FX/graphql-fails"
  both --repo o/r
  [[ "$output" == *"ready=0"* ]]
}

@test "rest: the required-check policy and branch protection apply as over GraphQL" {
  pr_row 7 me false false MERGEABLE '[{"name":"lint","conclusion":"SUCCESS"}]' | jq -s . >"$FX/prs.json"
  both --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"missing-required:build"* ]]
  touch "$FX/rules-fails"
  both --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"policy=unknown"* ]]
  rm "$FX/rules-fails"
  echo '[]' >"$FX/rules.json"
  echo '{"protected":true,"protection":{"required_status_checks":{"contexts":["ci/legacy"],"checks":[{"context":"build"}]}}}' >"$FX/branch.json"
  both --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"missing-required:build,ci/legacy"* ]]
}

@test "rest: --delta, --pr and SIGPIPE-ignored runs give the same rows" {
  ready_prs 20
  both --repo o/r --delta
  [ "$(printf '%s\n' "$output" | grep -c READY)" -eq 20 ]
  both --repo o/r --delta
  [[ "$output" == "no-change"*"changed=0"* ]]
  jq '.[1:] | (.[0].headRefOid = "ffffffffff") | (.[1].statusCheckRollup += [{"name":"lint","conclusion":"FAILURE"}])' \
    "$FX/prs.json" >"$FX/p2" && mv "$FX/p2" "$FX/prs.json"
  both --repo o/r --delta
  [[ "$output" == *$'1\tGONE'* ]]
  [[ "$output" == *$'2\tREADY\tfffffffff'* ]]
  [[ "$output" == *$'3\tBLOCK'*"fail:lint"* ]]
  : >"$FX/rest-calls"
  both --repo o/r --pr 3
  [ "$(printf '%s\n' "$output" | grep -c $'\t')" -eq 1 ]
  [ "$(grep -c '/check-runs' "$FX/rest-calls")" -eq 1 ]   # only the named PR is read
  run bash -c "trap '' PIPE; ORCHESTRATE_GH_API=rest exec '$SCRIPTS/pr-ready.sh' --repo o/r --no-threads"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Broken pipe"* ]]
  [[ "$output" == *"api=rest"* ]]
}

# --- the merge-selection fixtures ------------------------------------------------------------

@test "rest: holds, label exclusions, branch filters and bot authors select as over GraphQL" {
  sel() { # number branch labels-json [checks] [author]
    pr_row "$1" "${5:-me}" false false MERGEABLE "${4:-$OKC}" "$(jq -c 'map({name: .})' <<<"$3")" | jq -c --arg b "$2" '.headRefName = $b'
  }
  { sel 1 work/1-a '["dependencies"]'; sel 2 work/2-b '["hold"]'; sel 3 work/3-c '[]'; sel 4 l-16900-fix '[]'
    sel 5 work/5-e '["dependencies"]' '[{"name":"build","conclusion":"FAILURE"}]'; sel 6 work/6-f '[]' "$OKC" app/dependabot
    sel 7 work/7-g '["hold"]'; } | jq -s . >"$FX/prs.json"
  echo '{"7": [{"isResolved": false, "isOutdated": false}]}' >"$FX/threads.json"
  both --repo o/r --base main --author me --author app/dependabot --exclude-label dependencies --hold 3 --head-match '^work/[0-9]+-'
  [[ "$output" == *$'1\tSKIP\tabcdef012\tMERGEABLE\t1\tlabel:dependencies ready-but-skipped'* ]]
  [[ "$output" == *$'4\tSKIP\tabcdef012\tMERGEABLE\t1\tbranch ready-but-skipped'* ]]
  [[ "$output" == *$'6\tREADY'* ]]
  [[ "$output" == *$'7\tSKIP\tabcdef012\tMERGEABLE\t1\thold'$'\n'* ]]
  [[ "$output" == *"ready-but-skipped=4 skipped-by=branch:1,hold:2,label:1"* ]]
}

# --- REST-only behaviour ---------------------------------------------------------------------

@test "rest: the 403 is followed once per pass; rest skips GraphQL; graphql and other 403s do not fall back" {
  ready_prs 2
  touch "$FX/rest-mode"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pr list' "$FX/rest-calls")" -eq 1 ]
  [ "$(grep -c graphql "$FX/rest-calls")" -eq 0 ]
  [[ "$output" != *diagnostics=* ]]   # a refused GraphQL is expected here, not a read problem
  : >"$FX/rest-calls"
  ORCHESTRATE_GH_API=rest run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *"open=2 ready=2 api=rest"* ]]
  ! grep -q '^pr ' "$FX/rest-calls"
  ORCHESTRATE_GH_API=graphql run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 3 ]
  ORCHESTRATE_GH_API=sometimes run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 2 ]
  # A 403 that is not the GraphQL refusal is final, as before.
  rm "$FX/rest-mode"
  echo '#!/bin/sh
case "$*" in "pr list"*) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;; *) exec "$BATS_TEST_TMPDIR/bin/gh" "$@" ;; esac' >"$BATS_TEST_TMPDIR/restbin/gh"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 3 ]
  [[ "$output" == *"no verdicts"* ]]
}

@test "rest: a candidate whose checks cannot be read is BLOCK checks=unknown, never READY" {
  ready_prs 3
  pr_row 4 me false false MERGEABLE "$OKC" '[{"name":"hold"}]' | jq -s --slurpfile p "$FX/prs.json" '$p[0] + .' >"$FX/p2"
  mv "$FX/p2" "$FX/prs.json"
  touch "$FX/rest-mode" "$FX/rest-fails-abcdef01234567892" "$FX/rest-fails-abcdef01234567894"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\tBLOCK\tabcdef012\tUNKNOWN\t0\tchecks=unknown'* ]]
  [[ "$output" == *$'4\tSKIP\tabcdef012\tUNKNOWN\t0\thold'$'\n'* ]]
  [[ "$output" == *"open=4 ready=2 api=rest diagnostics="* ]]
}

@test "rest: a full REST list is truncated, and an EXTRA PR beyond it is read on its own" {
  # 300 drafts newest first, then two old PRs: the list stops at 300; drafts cost no per-PR read.
  { for i in $(seq 305 -1 6); do pr_row "$i" me true false MERGEABLE "$OKC"; done
    pr_row 3 me false false MERGEABLE "$OKC"; pr_row 2 me false false MERGEABLE "$OKC"; } | jq -s . >"$FX/prs.json"
  pr_row 5 me false false MERGEABLE "$OKC" | jq '.state = "MERGED"' >"$FX/view-5.json"
  touch "$FX/rest-mode"
  PR_READY_EXTRA="3 5 4" run "$SCRIPTS/pr-ready.sh" --repo o/r --no-threads
  [ "$status" -eq 0 ]
  [[ "$output" == *$'3\tREADY\tabcdef012'* ]]
  [[ "$output" != *$'\n5\t'* ]]
  [[ "$output" == *"open=301 ready=1 truncated=yes extra-unreadable=4 api=rest"* ]]
  [ "$(grep -c 'pulls?state=open' "$FX/rest-calls")" -eq 3 ]
  [ "$(grep -c '/check-runs' "$FX/rest-calls")" -eq 1 ]
}

@test "rest: an unreadable REST list exits 3 with no verdicts" {
  echo 'not json' >"$FX/prs.json"
  touch "$FX/rest-mode"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 3 ]
  [[ "$output" == *"no verdicts"* ]]
}

# --- gh-rest-pr.sh parsing -------------------------------------------------------------------

rp() { "$SCRIPTS/gh-rest-pr.sh" "$@" --repo o/r; }

@test "gh-rest-pr list maps REST pull requests onto the gh pr list shape, page by page" {
  { pr_row 1 app/dependabot false false MERGEABLE "$OKC"; pr_row 2 me true true MERGEABLE "$OKC" '[{"name":"x"}]'; } |
    jq -s 'map(. + {title: "t", body: "Fixes #12, closes o/r#13 and fixed: #15. Fixes other/repo#14; see #16"})' >"$FX/prs.json"
  touch "$FX/rest-mode"
  run rp list
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0] | [.author.login, .isDraft, .isCrossRepository, .mergeable, .statusCheckRollup]' <<<"$output")" = '["app/dependabot",false,false,"UNKNOWN",[]]' ]
  [ "$(jq -c '.[1] | [.isDraft, .isCrossRepository, .labels, .baseRefName, .headRefOid]' <<<"$output")" = '[true,true,[{"name":"x"}],"main","abcdef01234567892"]' ]
  [ "$(jq -c '[.[0].closingIssuesReferences[].number]' <<<"$output")" = '[12,13,15]' ]
  # 250 open PRs: three pages of 100; --limit stops early.
  for i in $(seq 1 250); do pr_row "$i" me false false MERGEABLE '[]'; done | jq -s . >"$FX/prs.json"
  : >"$FX/rest-calls"
  [ "$(rp list | jq length)" -eq 250 ]
  [ "$(grep -c 'pulls?state=open' "$FX/rest-calls")" -eq 3 ]
  : >"$FX/rest-calls"
  [ "$(rp list --limit 120 | jq length)" -eq 120 ]
  [ "$(grep -c 'pulls?state=open' "$FX/rest-calls")" -eq 2 ]
  run rp list --limit 0
  [ "$status" -eq 2 ]
  run rp view
  [ "$status" -eq 2 ]
}

@test "gh-rest-pr threads reads every shape it knows and fails closed on the rest" {
  mkdir -p "$BATS_TEST_TMPDIR/tbin"
  cat >"$BATS_TEST_TMPDIR/tbin/gh" <<'STUB'
#!/usr/bin/env bash
cat "$FX/threads-body"
STUB
  chmod +x "$BATS_TEST_TMPDIR/tbin/gh"
  t() { printf '%s' "$1" >"$FX/threads-body"; PATH="$BATS_TEST_TMPDIR/tbin:$PATH" "$SCRIPTS/gh-rest-pr.sh" threads --repo o/r --pr 1 2>/dev/null; }
  [ "$(t '[]')" = 0 ]
  [ "$(t '[{"isResolved":false,"isOutdated":false},{"isResolved":true,"isOutdated":false},{"isResolved":false,"isOutdated":true}]')" = 1 ]
  [ "$(t '[{"resolved":false,"outdated":false},{"resolved":false}]')" = 2 ]
  [ "$(t '[{"is_resolved":false,"is_outdated":true}]')" = 0 ]
  [ "$(t '{"threads":[{"isResolved":false}]}')" = 1 ]
  [ "$(t '{"review_threads":{"nodes":[{"resolved":false},{"resolved":true}]}}')" = 1 ]
  [ "$(t '[{"isResolved":false}][{"isResolved":false},{"isResolved":true}]')" = 2 ]   # --paginate pages
  run t '[{"id":1}]'
  [ "$status" -eq 3 ]
  run t '{"message":"ok"}'
  [ "$status" -eq 3 ]
  run t '[{"isResolved":"no"}]'
  [ "$status" -eq 3 ]
}

@test "gh-rest-pr files, review and rollup read their routes" {
  pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/9/job/90","workflowName":"CI"},{"__typename":"StatusContext","context":"ci/x","state":"PENDING"}]' |
    jq -s 'map(. + {files: [{path: "a.sh"}, {path: "b/c.md"}], reviews: [{state: "COMMENTED", commit_id: "aaa"}, {state: "APPROVED", commit_id: "bbb"}]})' >"$FX/prs.json"
  touch "$FX/rest-mode"
  [ "$(rp files --pr 1)" = '[{"path":"a.sh"},{"path":"b/c.md"}]' ]
  [ "$(rp review --pr 1)" = '{"state":"APPROVED","commit":"bbb"}' ]
  [ "$(rp review --pr 2)" = '{"state":null,"commit":null}' ]
  run rp rollup --sha abcdef01234567891
  [ "$(jq -c '.[0] | [.__typename, .name, .conclusion, .workflowName]' <<<"$output")" = '["CheckRun","build","SUCCESS","CI"]' ]
  [ "$(jq -c '.[1] | [.__typename, .context, .state]' <<<"$output")" = '["StatusContext","ci/x","PENDING"]' ]
  run rp view --pr 9
  [ "$status" -eq 3 ]
}

# --- gh-snapshot.sh and lane-claim.sh ---------------------------------------------------------

@test "gh-snapshot falls back to REST: the same row format, roll-up and review per PR" {
  { pr_row 1 me false false MERGEABLE "$OKC"; pr_row 2 me true false MERGEABLE '[{"name":"b","status":"QUEUED"}]'
    pr_row 3 me false false MERGEABLE '[{"name":"b","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"c","state":"ERROR"}]'
    pr_row 4 me false false MERGEABLE '[]'; } |
    jq -s 'map(. + {reviews: (if .number == 1 then [{state: "APPROVED", commit_id: .headRefOid}]
                              elif .number == 3 then [{state: "CHANGES_REQUESTED", commit_id: "0ld"}] else [] end)})' >"$FX/prs.json"
  touch "$FX/rest-mode"
  run "$SCRIPTS/gh-snapshot.sh" --repo o/r
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pr 1 head=abcdef01234567891 draft=no rollup=SUCCESS review=APPROVED review-commit=abcdef01234567891 reviewed=head cache=new" ]
  [ "${lines[1]}" = "pr 2 head=abcdef01234567892 draft=yes rollup=PENDING review=NONE review-commit=- reviewed=none cache=new" ]
  [ "${lines[2]}" = "pr 3 head=abcdef01234567893 draft=no rollup=ERROR review=CHANGES_REQUESTED review-commit=0ld reviewed=stale cache=new" ]
  [ "${lines[3]}" = "pr 4 head=abcdef01234567894 draft=no rollup=NONE review=NONE review-commit=- reviewed=none cache=new" ]
  grep -q 'sort=created&direction=asc' "$FX/rest-calls"
  run "$SCRIPTS/gh-snapshot.sh" --repo o/r --limit 2
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *"cache=same" ]]
  ORCHESTRATE_GH_API=graphql run "$SCRIPTS/gh-snapshot.sh" --repo o/r
  [ "$status" -eq 3 ]
  [[ "$output" == *"gh-read: forbidden status=403"*"GraphQL"* ]]
}

@test "lane-claim reads open PRs over REST: body references, #N and files" {
  echo '[{"number":45,"title":"Fix login crash (#12)","body":"","files":[{"path":"src/auth/login.ts"}],"headRefOid":"a"},
         {"number":46,"title":"Docs","body":"Fixes #31","files":[{"path":"docs/a.md"}],"headRefOid":"b"}]' >"$FX/prs.json"
  touch "$FX/rest-mode"
  lc() { run "$SCRIPTS/lane-claim.sh" "$@" --repo o/r; }
  lc check --issues 31 --files z.ts
  [ "$status" -eq 3 ]; [ "$output" = "conflict: PR 46 covers issue 31" ]
  lc check --issues 12 --files z.ts
  [ "$output" = "conflict: PR 45 covers issue 12" ]
  lc check --issues 1 --files src/auth/
  [ "$output" = "conflict: PR 45 touches src/auth/" ]
  lc check --issues 123 --files src/other.ts
  [ "$status" -eq 0 ]; [ "$output" = ok ]
  # Files are read per PR only when the check names files.
  : >"$FX/rest-calls"
  lc check --issues 123
  [ "$status" -eq 0 ]
  ! grep -q '/files' "$FX/rest-calls"
  echo 'not json' >"$FX/prs.json"
  lc add --worktree wt-a --branch lane/a --issues 20 --files a.ts
  [ "$status" -eq 4 ]
}
