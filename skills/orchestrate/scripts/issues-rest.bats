#!/usr/bin/env bats
# Issue-side reads without GraphQL (#108): gh-issues.sh and its callers (campaign.sh status,
# issues-ranked.sh, issue-candidates.sh, issue-route.sh status) against one fixture set, served
# either the GraphQL way (`gh issue list` / `gh pr list`) or by a gh that refuses those with the
# Claude Code cloud 403 and answers only REST (rest_stub.bash). Both must give the same verdicts.
# Run: bats issues-rest.bats

setup() {
  load test_helper
  load rest_stub
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/nogit"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 ORCHESTRATE_AUTHOR=me   # 2026-09-27T12:00:00Z
  # Fixtures are REST-shaped: $FX/issues.json (/repos/o/r/issues items, pull requests included),
  # $FX/pulls.json (open pulls; `_closing` = what GraphQL closingIssuesReferences would list),
  # $FX/merged.json (search items), $FX/comments-N.json. The stub below serves the gh list
  # commands from them the GraphQL way; rest_wrap (rest_stub.bash) sits in front of it and, while
  # $FX/rest-mode exists (the default here), refuses those, and any graphql call, with the cloud
  # 403 and serves the REST routes from the same fixtures. Every call is logged to $FX/calls.
  # GH_FORBID=1 makes the gh list commands fail with a 403 that does not name GraphQL (=url: one
  # that ends in gh's "(https://api.github.com/graphql)"), served with $FX/rest-mode removed.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
label="" prev=""
for a in "$@"; do [ "$prev" = --label ] && label=$a; prev=$a; done
comments() { # issue number -> gh-shaped comments
  if [ -f "$FX/comments-$1.json" ]; then jq '[.[] | {author: {login: .user.login}, body, createdAt: .created_at}]' "$FX/comments-$1.json"; else echo '[]'; fi
}
case "$1 $2" in
  "issue list" | "pr list" | "api graphql")
    case "${GH_FORBID:-0}" in
      1) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;;
      url) echo "HTTP 403: Resource not accessible by integration (https://api.github.com/graphql)" >&2; exit 1 ;;
    esac ;;
esac
case "$1 $2" in
  "issue list")
    jq -c --arg l "$label" '[.[] | select(.pull_request == null)
      | select($l == "" or any(.labels[]; .name == $l))
      | {number, title, body: (.body // ""), labels: [.labels[] | {name}], updatedAt: .updated_at}]' "$FX/issues.json" >"$FX/out"
    for n in $(jq -r '.[].number' "$FX/out"); do
      jq -c --argjson n "$n" --argjson c "$(comments "$n")" 'map(if .number == $n then .comments = $c else . end)' "$FX/out" >"$FX/out2"
      mv "$FX/out2" "$FX/out"
    done
    jq -c 'map(.comments //= [])' "$FX/out" ;;
  "pr list")
    if [[ " $* " == *" merged "* ]]; then
      jq '[.[] | {number, title, body, mergedAt: .pull_request.merged_at, closingIssuesReferences: [(._closing // [])[] | {number: .}]}]' "$FX/merged.json"
    else
      jq '[.[] | {number, title, body, closingIssuesReferences: [(._closing // [])[] | {number: .}]}]' "$FX/pulls.json"
    fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export REST_CALLS="$FX/calls"
  rest_wrap
  touch "$FX/rest-mode"
  echo '[]' >"$FX/pulls.json"; echo '[]' >"$FX/merged.json"; echo '[]' >"$FX/issues.json"
}

# issue N TITLE LABELS(comma) [UPDATED] [pr]  (REST shape; "pr" makes it a pull request item)
issue() {
  jq --argjson n "$1" --arg t "$2" --arg l "$3" --arg u "${4:-2026-09-26T10:00:00Z}" --arg pr "${5:-}" \
    '. + [{number: $n, title: $t, state: "open", body: "", user: {login: "me"}, updated_at: $u, created_at: $u,
      labels: ($l | split(",") | map({name: ., color: "ededed", description: ""}))}
      + (if $pr == "pr" then {pull_request: {url: "https://api.github.com/repos/o/r/pulls/\($n)"}} else {} end)]' \
    "$FX/issues.json" >"$FX/i.tmp" && mv "$FX/i.tmp" "$FX/issues.json"
}
# pull N BODY [CLOSING-JSON]: an open PR; CLOSING is what GraphQL would link
pull() {
  jq --argjson n "$1" --arg b "$2" --argjson c "${3:-[]}" \
    '. + [{number: $n, title: "PR \($n)", state: "open", body: $b, user: {login: "me"}, labels: [], draft: false,
      head: {ref: "b\($n)"}, merged_at: null, _closing: $c}]' "$FX/pulls.json" >"$FX/p.tmp" && mv "$FX/p.tmp" "$FX/pulls.json"
}
# merged N BODY MERGED_AT
merged() {
  jq --argjson n "$1" --arg b "$2" --arg t "$3" \
    '. + [{number: $n, title: "PR \($n)", state: "closed", body: $b, user: {login: "me"}, labels: [],
      pull_request: {merged_at: $t}}]' "$FX/merged.json" >"$FX/m.tmp" && mv "$FX/m.tmp" "$FX/merged.json"
}

fixture() {
  issue 1 "Crash on start when the session resumes" bug,P1 2026-09-26T10:00:00Z
  issue 2 "Crash on start when session resumes" cloud-ready 2026-09-26T09:00:00Z
  issue 3 "Blocked thing" blocked 2026-09-26T08:00:00Z
  issue 4 "Android emulator flake in device tests" needs-local:android-emulator 2026-09-26T11:00:00Z
  issue 5 "iOS simulator boot timeout" needs-local:ios-simulator,cloud-ready 2026-09-26T07:00:00Z
  issue 10 "Fix the crash" fleet-pause 2026-09-26T12:00:00Z pr
  pull 10 "Fixes #2" '[2]'
  pull 11 "Refs #4, not a closing reference" '[]'
  pull 12 "resolves: #1" '[1]'
  merged 20 "Fixes #4" 2026-09-26T11:30:00Z
  echo '[{"user":{"login":"me"},"body":"Device verification: PASS on android pixel 8","created_at":"2026-09-26T12:00:00Z"}]' >"$FX/comments-4.json"
}

# both CMD...: run CMD the GraphQL way, then with GraphQL refused (fresh memo each), and require
# the same output and status. Leaves the REST run in $output / $status (and REST mode on).
both() {
  rm -f "$ORCHESTRATE_STATE_DIR/gh-no-graphql" "$FX/rest-mode"
  run "$@"; local g=$output gs=$status
  rm -f "$ORCHESTRATE_STATE_DIR/gh-no-graphql" "$FX/calls"
  touch "$FX/rest-mode"
  run "$@"
  [ "$status" -eq "$gs" ] || { echo "graphql exit $gs, rest exit $status: $output"; false; }
  # Candidate files carry a timestamp path in the last line; compare the rest.
  [ "$(sed '/^# /s#all: .*##' <<<"$output")" = "$(sed '/^# /s#all: .*##' <<<"$g")" ] ||
    { printf 'graphql:\n%s\nrest:\n%s\n' "$g" "$output"; false; }
}

@test "issues-ranked.sh: same ranking and in-open-PR join over REST as over GraphQL" {
  fixture
  both "$SCRIPTS/issues-ranked.sh" --repo o/r --priority-label P1
  [ "$status" -eq 0 ]
  [ "$(cut -f2-4 <<<"$output")" = "$(printf '1\tP-bug\t12\n4\tother\t-\n2\tother\t10\n5\tother\t-')" ]
  # The PR item in /issues is dropped; the REST run read /issues and /pulls, never GraphQL twice.
  run ! grep -q '^10	' <<<"$output"
  grep -q '^api repos/o/r/pulls?state=open&per_page=100&page=1' "$FX/calls"
  [ "$(grep -c '^pr list\|^issue list' "$FX/calls")" -eq 1 ]
  both "$SCRIPTS/issues-ranked.sh" --repo o/r --priority-label P1 --skip-in-pr
  [ "$(cut -f2 <<<"$output" | tr '\n' ' ')" = "4 5 " ]
}

@test "issue-candidates.sh dupes, sweep and fixed: same leads over REST as over GraphQL" {
  fixture
  both "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\t2\tCrash on start'* ]]
  both "$SCRIPTS/issue-candidates.sh" sweep --repo o/r --checkout "$BATS_TEST_TMPDIR/nogit"
  [ "$(cut -f1,2,4 <<<"$output" | sed -n 1,2p)" = "$(printf 'A\t4\t#20\nC\t5\t-')" ]
  grep -q '^api repos/o/r/issues/4/comments' "$FX/calls"
  grep -q '^api repos/o/r/issues?state=open&labels=needs-local%3Aandroid-emulator' "$FX/calls"
  both "$SCRIPTS/issue-candidates.sh" fixed --repo o/r
  [ "$output" = "$(printf '4\t20\t2026-09-26T11:30:00Z\tbody\tAndroid emulator flake in device tests')" ]
}

@test "issue-route.sh status: same counts and invariant rows over REST as over GraphQL" {
  fixture
  both "$SCRIPTS/issue-route.sh" status --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'count\tcloud-ready\t2'* ]]
  [[ "$output" == *$'multi\t5\t'* ]]
  [[ "$output" == *$'unrouted\t1\t'* ]]
  [[ "$output" != *$'\t10\t'* ]]
}

@test "campaign.sh status: pause check and PR counts over REST; a PR carrying the pause label is not an issue" {
  fixture
  both "$SCRIPTS/campaign.sh" status --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"paused=no"* ]]
  [[ "$output" == *"open_prs=3"* ]]
  issue 6 "Stop the fleet" fleet-pause
  both "$SCRIPTS/campaign.sh" status --repo o/r
  [[ "$output" == *"paused=yes(fleet-pause)"* ]]
  grep -q '^api repos/o/r/issues?state=open&labels=fleet-pause' "$FX/calls"
  # The label read's refusal (no "HTTP 403:" prefix) is still a 403: one attempt, then REST.
  [ "$(grep -c '^issue list' "$FX/calls")" -eq 1 ]
}

@test "gh-issues.sh: GraphQL refused once, then REST straight away; ORCHESTRATE_GH_API=rest never tries GraphQL" {
  fixture
  run "$SCRIPTS/gh-issues.sh" issues --repo o/r --fields number
  [ "$status" -eq 0 ]
  [ "$(jq -c 'map(.number)' <<<"$output")" = "[1,2,3,4,5]" ]
  [ -f "$ORCHESTRATE_STATE_DIR/gh-no-graphql" ]
  rm "$FX/calls"
  run "$SCRIPTS/gh-issues.sh" prs-open --repo o/r --fields number,closingIssuesReferences
  [ "$(jq -c 'map([.number, [.closingIssuesReferences[].number]])' <<<"$output")" = "[[10,[2]],[11,[]],[12,[1]]]" ]
  run ! grep -q '^pr list' "$FX/calls"
  # The memo expires after 12 hours: GraphQL is tried again.
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 43200)) run "$SCRIPTS/gh-issues.sh" prs-open --repo o/r
  grep -q '^pr list' "$FX/calls"
  rm -f "$ORCHESTRATE_STATE_DIR/gh-no-graphql" "$FX/calls"
  ORCHESTRATE_GH_API=rest run "$SCRIPTS/gh-issues.sh" issues --repo o/r
  [ "$status" -eq 0 ]
  run ! grep -q '^issue list' "$FX/calls"
  [ ! -f "$ORCHESTRATE_STATE_DIR/gh-no-graphql" ]
}

@test "gh-issues.sh: a 403 that does not name GraphQL is not a fallback; graphql mode never falls back" {
  fixture
  rm "$FX/rest-mode"
  GH_FORBID=1 run "$SCRIPTS/gh-issues.sh" issues --repo o/r
  [ "$status" -eq 5 ]
  [[ "$output" == *"gh-read: forbidden status=403"* ]]
  run ! grep -q '^api ' "$FX/calls"
  # gh ends a GraphQL error with the endpoint URL; that lower-case "graphql" is not the refusal.
  GH_FORBID=url run "$SCRIPTS/gh-issues.sh" issues --repo o/r
  [ "$status" -eq 5 ]
  run ! grep -q '^api ' "$FX/calls"
  [ ! -f "$ORCHESTRATE_STATE_DIR/gh-no-graphql" ]
  touch "$FX/rest-mode"
  ORCHESTRATE_GH_API=graphql run "$SCRIPTS/gh-issues.sh" issues --repo o/r
  [ "$status" -eq 5 ]
  [[ "$output" == *"GraphQL is not available"* ]]
  rm "$FX/rest-mode"
  GH_FORBID=1 run "$SCRIPTS/issues-ranked.sh" --repo o/r
  [ "$status" -eq 5 ]
  [[ "$output" == *"issues-ranked.sh: open pull requests could not be read"* ]]
  ORCHESTRATE_GH_API=bogus run "$SCRIPTS/gh-issues.sh" issues --repo o/r
  [ "$status" -eq 2 ]
}

@test "gh-issues.sh REST pages: 100 per page, pull requests dropped, stops at --limit and at the page cap" {
  for i in $(seq 1 130); do
    if ((i % 10 == 0)); then issue "$i" "PR $i" x 2026-09-26T10:00:00Z pr; else issue "$i" "Issue $i" x; fi
  done
  run "$SCRIPTS/gh-issues.sh" issues --repo o/r --limit 200 --fields number,labels,updatedAt
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 117 ]
  [ "$(jq -c '.[0] | [.labels[0].name, .updatedAt]' <<<"$output")" = '["x","2026-09-26T10:00:00Z"]' ]
  [ "$(grep -c '^api repos/o/r/issues' "$FX/calls")" -eq 2 ]
  rm "$FX/calls"
  run "$SCRIPTS/gh-issues.sh" issues --repo o/r --limit 50
  [ "$(jq length <<<"$output")" -eq 50 ]
  [ "$(grep -c '^api repos/o/r/issues' "$FX/calls")" -eq 1 ]
  # --limit 1 allows two pages: the cap is reached with the list still incomplete, and said so.
  for i in $(seq 131 330); do issue "$i" "PR $i" x 2026-09-26T10:00:00Z pr; done
  jq '[.[] | select(.number > 130)] + [.[] | select(.number <= 130)]' "$FX/issues.json" >"$FX/i.tmp" && mv "$FX/i.tmp" "$FX/issues.json"
  run bash -c '"$1/gh-issues.sh" issues --repo o/r --limit 1 2>"$2/err"' _ "$SCRIPTS" "$FX"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  grep -q "stopped at the page cap (2 pages, 200 items read)" "$FX/err"
}
