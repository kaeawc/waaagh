#!/usr/bin/env bats
# JSON that grows with the repository must never reach jq as one argument (#121): Linux caps a
# single argument at 128 KiB (MAX_ARG_STRLEN) whatever ARG_MAX is, and `jq --argjson NAME "$json"`
# then dies with "Argument list too long". Each test feeds one script a payload over 128 KiB (many
# PRs, comments, threads or checks with long text) and requires the normal answer. The doc-contract
# test at the end keeps repository-sized variables off --argjson/--arg.
# gh is stubbed by test_helper.bash's stub_gh_routes: each test maps routes to fixture files with
# gh_route, or writes a `case "$a"` body with gh_routes where an answer is computed.
# Run: bats large-payloads.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  stub_gh_routes
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1793880000 ORCHESTRATE_AUTHOR=me GH_READ_JITTER=0   # 2026-11-05T10:40:00Z
  unset ORCHESTRATE_GH_API ORCHESTRATE_REVIEW_BOTS PR_READY_EXTRA
}

pad() { printf "%${1}s" '' | tr ' ' "${2:-x}"; }   # pad N [CHAR] -> N copies of CHAR
big() { # big FILE: the fixture really is over the 128 KiB single-argument cap
  local n
  n=$(wc -c <"$1")
  ((n > 131072)) || { echo "fixture $1 is only $n bytes"; return 1; }
}

@test "cloud-dispatch.sh fixtures: an issue with 150 long comments" {
  jq -n '{number: 7, html_url: "https://github.com/o/r/issues/7", body: "Parse the captured dump.", labels: []}' >"$FX/issue.json"
  jq -n --arg p "$(pad 1000)" '[range(150) | {id: ., body: $p, html_url: "https://github.com/o/r/issues/7#issuecomment-\(.)"}]
    + [{id: 999, body: "<details><summary>fixture</summary>dump</details>", html_url: "https://github.com/o/r/issues/7#issuecomment-999"}]' \
    >"$FX/comments.json"
  big "$FX/comments.json"
  gh_route "api repos/o/r/issues/7/comments*" comments.json
  gh_route "api repos/o/r/issues/7" issue.json
  run "$SCRIPTS/cloud-dispatch.sh" fixtures --issue 7 --repo o/r --no-blocker-check
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "$output" = "fixtures https://github.com/o/r/issues/7#issuecomment-999" ]
}

@test "gh-issues.sh issues --fields comments over REST: one issue with 150 long comments" {
  jq -n '[{number: 1, title: "t", state: "open", body: "", user: {login: "me"}, labels: [],
    updated_at: "2026-11-01T00:00:00Z", created_at: "2026-11-01T00:00:00Z"}]' >"$FX/issues.json"
  jq -n --arg p "$(pad 1000)" '[range(150) | {user: {login: "u\(.)"}, body: $p, created_at: "2026-11-01T00:00:00Z"}]' >"$FX/comments.json"
  big "$FX/comments.json"
  gh_route "api repos/o/r/issues?state=open*" issues.json
  gh_route "api repos/o/r/issues/1/comments*" comments.json
  ORCHESTRATE_GH_API=rest run "$SCRIPTS/gh-issues.sh" issues --repo o/r --fields number,comments
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "$(jq -c '[length, (.[0].comments | length), .[0].comments[149].author.login]' <<<"$output")" = '[1,150,"u149"]' ]
}

@test "gh-rest-pr.sh view --checks with 700 check runs, and thread-nodes with 600 threads" {
  jq -n '{number: 5, title: "t", state: "open", user: {login: "me", type: "User"}, draft: false,
    head: {ref: "b", sha: "abc123", repo: {full_name: "o/r"}}, base: {ref: "main", repo: {full_name: "o/r"}},
    labels: [], mergeable: true, body: ""}' >"$FX/pull.json"
  jq -n --arg p "$(pad 150)" '{total_count: 700, check_runs: [range(700) | {name: "check-\(.)-\($p)",
    status: "completed", conclusion: "success", started_at: "2026-11-01T00:00:00Z", details_url: "https://ci.example/\(.)"}]}' \
    >"$FX/check-runs.json"
  big "$FX/check-runs.json"
  jq -n --arg p "$(pad 200)" '[range(600) | {id: "T\(.)", isResolved: false, isOutdated: false,
    comments: [{databaseId: (1000 + .), body: $p}]}]' >"$FX/threads.json"
  big "$FX/threads.json"
  gh_routes <<'R'
case "$a" in
  "api repos/o/r/pulls/5") cat "$FX/pull.json"; exit 0 ;;
  "api --paginate repos/o/r/commits/abc123/check-runs"*) cat "$FX/check-runs.json"; exit 0 ;;
  "api repos/o/r/commits/abc123/status"*) echo '{"statuses": []}'; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/ccr/review_threads") cat "$FX/threads.json"; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/comments"*)
    jq -n '[range(600) | {id: (1000 + .), user: {login: "bot"}, body: "c", html_url: "u", created_at: "2026-11-01T00:00:00Z"}]'; exit 0 ;;
  "api --paginate repos/o/r/pulls/5/commits"*) echo '[{"sha": "abc123"}]'; exit 0 ;;
esac
R
  run "$SCRIPTS/gh-rest-pr.sh" view --repo o/r --pr 5 --checks
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "$(jq -c '[.number, (.statusCheckRollup | length), .statusCheckRollup[699].conclusion]' <<<"$output")" = '[5,700,"SUCCESS"]' ]
  run "$SCRIPTS/gh-rest-pr.sh" thread-nodes --repo o/r --pr 5
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "$(jq -c '[.number, (.reviewThreads.nodes | length)]' <<<"$output")" = '[5,600]' ]
}

@test "gh-snapshot.sh: two GraphQL pages whose rows add up to more than 128 KiB" {
  # Real rows are ~200 bytes, so 128 KiB takes ~700 open PRs; a long review-commit field gets
  # there with 140 rows, which keeps the per-row cache loop fast.
  for pg in 1 2; do
    jq -n --argjson pg "$pg" --arg p "$(pad 2000 f)" '{data: {repository: {pullRequests: {
      pageInfo: {hasNextPage: ($pg == 1), endCursor: "c\($pg)"},
      nodes: [range(($pg - 1) * 70 + 1; $pg * 70 + 1) | {number: ., headRefOid: ("\(.)" as $s | ("a" * (40 - ($s | length))) + $s), isDraft: false,
        commits: {nodes: [{commit: {statusCheckRollup: {state: "SUCCESS"}}}]},
        reviews: {nodes: [{state: "COMMENTED", commit: {oid: $p}}]}}]}}}}' >"$FX/page$pg.json"
  done
  big "$FX/page1.json"
  gh_route "api graphql*after=c1*" page2.json
  gh_route "api graphql*" page1.json
  run "$SCRIPTS/gh-snapshot.sh" --repo o/r --limit 300 --json
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "$(jq -c '[length, .[139].number, .[139].cache, .[139].reviewed]' <<<"$output")" = '[140,140,"new","stale"]' ]
}

@test "issues-ranked.sh: 300 open PRs whose closing references add up to more than 128 KiB" {
  jq -n '[range(300) | . as $i | {number: (1000 + $i),
    closingIssuesReferences: ([range(50) | {number: (5000 + $i * 50 + .)}] + (if $i == 299 then [{number: 2}] else [] end))}]' \
    >"$FX/prs.json"
  big "$FX/prs.json"
  jq -n '[{number: 1, title: "one", labels: [], updatedAt: "2026-11-01T00:00:00Z"},
          {number: 2, title: "two", labels: [], updatedAt: "2026-11-02T00:00:00Z"}]' >"$FX/issues.json"
  gh_route "pr list*" prs.json
  gh_route "issue list*" issues.json
  run "$SCRIPTS/issues-ranked.sh" --repo o/r
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "$(cut -f2,4 <<<"$output" | tr '\t\n' ' |')" = "2 1299|1 -|" ]
}

@test "lane-claim.sh check: 200 open PRs with long bodies, and over REST a PR with 3000 files" {
  jq -n --arg p "$(pad 1000)" '[range(200) | {number: (100 + .), title: "PR \(.)", body: $p,
    closingIssuesReferences: [], files: [{path: "x/\(.).ts"}]}]
    + [{number: 999, title: "last", body: "Fixes #42", closingIssuesReferences: [{number: 42}], files: []}]' >"$FX/prs.json"
  big "$FX/prs.json"
  gh_route "pr list*" prs.json
  run "$SCRIPTS/lane-claim.sh" check --issues 42 --files src/a.ts --repo o/r
  [ "$status" -eq 3 ] || { echo "status=$status: $output"; false; }
  [[ "$output" == *"conflict: PR 999 covers issue 42"* ]] || { echo "$output"; false; }

  # REST: the list, then each PR's files (one PR changes 3000 paths, the last one src/a.ts).
  jq -n '[{number: 7, title: "t", state: "open", user: {login: "me", type: "User"}, draft: false, body: "",
    head: {ref: "b", sha: "abc", repo: {full_name: "o/r"}}, base: {ref: "main", repo: {full_name: "o/r"}}, labels: []}]' >"$FX/pulls.json"
  jq -n --arg p "$(pad 40)" '[range(3000) | {filename: "deep/\($p)/\(.).ts"}] + [{filename: "src/a.ts"}]' >"$FX/files.json"
  big "$FX/files.json"
  gh_route "api repos/o/r/pulls?state=open*" pulls.json
  gh_route "api --paginate repos/o/r/pulls/7/files*" files.json
  ORCHESTRATE_GH_API=rest run "$SCRIPTS/lane-claim.sh" check --issues 43 --files src/a.ts --repo o/r
  [ "$status" -eq 3 ] || { echo "status=$status: $output"; false; }
  [[ "$output" == *"conflict: PR 7"*"src/a.ts"* ]] || { echo "$output"; false; }
}

@test "pr-ready.sh over REST: 300 open PRs with long titles, one candidate" {
  for pg in 1 2 3; do
    jq -n --argjson pg "$pg" --arg p "$(pad 800)" '[range(($pg - 1) * 100 + 1; $pg * 100 + 1) | {number: ., title: $p,
      state: "open", user: {login: (if . == 250 then "me" else "other" end), type: "User"}, draft: false, body: "",
      head: {ref: "b\(.)", sha: "sha\(.)", repo: {full_name: "o/r"}}, base: {ref: "main", repo: {full_name: "o/r"}},
      labels: [], created_at: "2026-11-01T00:00:00Z", updated_at: "2026-11-01T00:00:00Z", html_url: "u"}]' >"$FX/pulls$pg.json"
  done
  jq -s 'add' "$FX"/pulls?.json >"$FX/all.json"
  big "$FX/all.json"
  jq '.[249] + {mergeable: true}' "$FX/all.json" >"$FX/pull250.json"
  gh_routes <<'R'
case "$a" in
  "api user") echo '{"login":"me"}'; exit 0 ;;
  *rules/branches*) echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]'; exit 0 ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}'; exit 0 ;;
  "api repos/o/r/pulls?state=open"*"&page=1"*) cat "$FX/pulls1.json"; exit 0 ;;
  "api repos/o/r/pulls?state=open"*"&page=2"*) cat "$FX/pulls2.json"; exit 0 ;;
  "api repos/o/r/pulls?state=open"*"&page=3"*) cat "$FX/pulls3.json"; exit 0 ;;
  "api repos/o/r/pulls?state=open"*) echo '[]'; exit 0 ;;
  "api repos/o/r/pulls/250") cat "$FX/pull250.json"; exit 0 ;;
  "api --paginate repos/o/r/commits/sha250/check-runs"*)
    echo '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","started_at":"2026-11-01T00:00:00Z"}]}'; exit 0 ;;
  "api repos/o/r/commits/sha250/status"*) echo '{"statuses":[]}'; exit 0 ;;
esac
R
  ORCHESTRATE_GH_API=rest run "$SCRIPTS/pr-ready.sh" --repo o/r --base main --author me --no-threads
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [[ "$output" == *$'250\tREADY'* ]]
  [[ "$output" == *"open=1 ready=1 truncated=yes api=rest"* ]] || { echo "$output"; false; }
}

@test "review-followup.sh list: a page of 100 threads with long first comments" {
  jq -n --arg p "$(pad 1500)" '{data: {repository: {pullRequest: {author: {login: "me"},
    reviews: {nodes: [{author: {login: "bot"}, state: "COMMENTED", submittedAt: "2026-11-01T00:00:00Z"}]},
    reviewThreads: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [range(100) | {id: "T\(.)",
      isResolved: false, isOutdated: false, path: "a.sh", line: ., originalLine: .,
      comments: {nodes: [{author: {login: "bot"}, createdAt: "2026-11-01T00:00:00Z", url: "u\(.)", body: ("finding \(.) " + $p)}]}}]}}}}}' \
    >"$FX/page.json"
  big "$FX/page.json"
  gh_route "api graphql*" page.json
  run --separate-stderr "$SCRIPTS/review-followup.sh" list --pr 5 --repo o/r
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "${#lines[@]}" -eq 100 ]
  [[ "$stderr" == *"pr=5 unresolved=100 first=100 later=0 own=0"* ]]
}

@test "review-gate.sh scan and check: 200 long bot reviews and 200 long comments" {
  jq -n --arg p "$(pad 800)" '[range(200) | {user: {login: "coderabbitai[bot]"}, commit_id: "old",
    body: $p, state: "COMMENTED", submitted_at: "2026-11-01T00:00:00Z"}]
    + [{user: {login: "chatgpt-codex-connector[bot]"}, commit_id: "abcdef1234567890", body: "ok", state: "COMMENTED",
        submitted_at: "2026-11-02T00:00:00Z"}]' >"$FX/reviews.json"
  jq -n --arg p "$(pad 800)" '[range(200) | {user: {login: "someone"}, body: $p, created_at: "2026-11-01T00:00:00Z"}]' >"$FX/comments.json"
  big "$FX/reviews.json"
  big "$FX/comments.json"
  gh_route "api repos/o/r/pulls/5/reviews*" reviews.json
  gh_route "api repos/o/r/issues/5/comments*" comments.json
  run "$SCRIPTS/review-gate.sh" scan --pr 5 --repo o/r
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  "$SCRIPTS/review-gate.sh" policy review-at-head --repo o/r >/dev/null
  run "$SCRIPTS/review-gate.sh" check --pr 5 --head abcdef1234567890 --repo o/r
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "$output" = "ok reviewed at-head" ]
}

@test "thread-sweep.sh scan: a GraphQL page of 25 PRs whose threads add up to more than 128 KiB" {
  jq -n --arg p "$(pad 600)" '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: false, endCursor: null},
    nodes: [range(25) | . as $pr | {number: (100 + $pr), commits: {nodes: [{commit: {oid: "abc"}}]},
      reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [range(10) | {id: "T\($pr)-\(.)", isResolved: false, isOutdated: false,
        starter: {nodes: [{author: {login: "bot"}, url: "u"}]},
        latest: {totalCount: 1, nodes: [{author: {login: "bot"}, body: $p}]}}]}}]}}}}' >"$FX/page.json"
  big "$FX/page.json"
  gh_route "api graphql*" page.json
  run "$SCRIPTS/thread-sweep.sh" scan --summary --repo o/r
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [ "$output" = "threads unresolved=250 answered=0 resolve-now=- repair=$(seq 100 124 | sed 's/^/#/' | paste -sd, -)" ]
}

@test "triage-tick.sh snapshot: 300 open PRs whose closing references add up to more than 128 KiB" {
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD
  jq -n '[range(300) | . as $i | {number: (1000 + $i), closingIssuesReferences: [range(50) | {number: (5000 + $i * 50 + .)}]}]' >"$FX/prs.json"
  big "$FX/prs.json"
  echo '[{"number":5,"labels":[{"name":"cloud-ready"}]},{"number":5001,"labels":[{"name":"cloud-ready"}]}]' >"$FX/issues.json"
  gh_routes <<'R'
case "$a" in
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-11-05T01:00:00Z"}]}'; exit 0 ;;
  "pr list"*) cat "$FX/prs.json"; exit 0 ;;
  "issue list"*) cat "$FX/issues.json"; exit 0 ;;
  "api graphql"*) echo '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}'; exit 0 ;;
esac
R
  run "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main
  [ "$status" -eq 0 ] || { echo "status=$status: $output"; false; }
  [[ "$output" == *"prs open=300+"* ]]
  [[ "$output" == *"dispatch "*"next=#5"* ]]
}

@test "lint: no repository-sized variable reaches jq as --argjson or --arg" {
  # The variable names these scripts use for whole PR / issue / comment / review / thread / check
  # lists, pages and TSV ledgers. Bounded values keep their arguments: a number, a name, a short
  # list (labels, required checks, one lane's issue numbers), one PR's snapshot or review row.
  # `issues` and `files` are not listed: lane-claim.sh and device-recheck.sh use them for a lane's
  # own short lists.
  local hits
  hits=$(grep -nE -- '--argjson [a-z_]+ "\$\{?(prs|items|rows|pages?|all|comments|com|iss|reviews|threads|nodes|out|cr|st|runs|c|f|one)\}?"|--arg [a-z_]+ "\$\{?(rows|checked|lanes_tsv|prs|comments)\}?"' \
    "$SCRIPTS"/*.sh "$SCRIPTS"/../../../bin/*.sh || true)
  [ -z "$hits" ] || { echo "$hits"; false; }
}
