#!/usr/bin/env bats
# GitHub quota pacing (#71): gh-budget.sh against a scripted /rate_limit, the gh shim, gh-read's
# budget outcome, declared priorities, the hidden-request lint, main-health on actions/runs, and
# the per-pass gh-snapshot.sh. Fake clock: waits are logged, not slept. Run: bats gh-budget.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_BUDGET_FAKE_SLEEP=1   # 2026-09-27T12:00:00Z
  unset GH_BUDGET_PRIORITY GH_BUDGET_ACTIVE GH_BUDGET_MAX_WAIT GH_BUDGET_HIGH_MAX_WAIT ORCHESTRATE_GH_BUDGET
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
printf '%s\n' "$PATH" >"$FX/path"
case "$*" in
  "api rate_limit") [ -f "$FX/rate.json" ] || { echo "HTTP 502" >&2; exit 1; }; cat "$FX/rate.json" ;;
  --version) echo "gh version 2.0" ;;
  "api graphql"*) n=$(($(cat "$FX/gq" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FX/gq"; cat "$FX/page$n.json" ;;
  "run list"* | *reviews* | *workflows*)
    if [ -f "$FX/limited" ]; then
      [ ! -f "$FX/rate-after.json" ] || mv "$FX/rate-after.json" "$FX/rate.json"
      echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2; exit 1
    fi
    echo '[]' ;;
  "api repos/o/r/actions/runs?"*) cat "$FX/runs.json" ;;
  *) echo "ok $*" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

rate() { # CORE_REMAINING [GRAPHQL_REMAINING] [RESET_IN] [FILE]
  jq -n --argjson c "$1" --argjson g "${2:-5000}" --argjson r $((ORCHESTRATE_NOW + ${3:-1000})) \
    '{resources: {core: {limit: 5000, remaining: $c, reset: $r}, graphql: {limit: 5000, remaining: $g, reset: $r},
      search: {limit: 30, remaining: 30, reset: $r}}}' >"$FX/${4:-rate.json}"
}
budget() { "$SCRIPTS/gh-budget.sh" "$@"; }
count() { grep -c -- "$1" "$FX/calls" 2>/dev/null || true; }

@test "calls above the floor are spaced until the reset; one cached /rate_limit read serves them" {
  rate 1100            # normal floor 1000: 100 spare over 1000 s, one call per 10 s
  run budget run normal -- api repos/o/r
  [ "$status" -eq 0 ]; [ "$output" = "ok api repos/o/r" ]
  run budget run normal -- api repos/o/r
  [ "$status" -eq 0 ]; [[ "$output" == *"gh-budget: wait 10"* ]]
  run budget run normal -- api repos/o/r
  [[ "$output" == *"gh-budget: wait 20"* ]]
  [ "$(count '^api rate_limit')" -eq 1 ]
  # Each call is counted against the cached snapshot; high keeps its own slots.
  [ "$(jq .resources.core.remaining "$ORCHESTRATE_STATE_DIR/gh-budget/rate_limit.json")" -eq 1097 ]
  run budget run high -- api repos/o/r
  [ "$status" -eq 0 ]; [[ "$output" != *wait* ]]
  # Past the TTL the snapshot is read again.
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 21)) run budget run high -- api repos/o/r
  [ "$(count '^api rate_limit')" -eq 2 ]
}

@test "each priority spends only down to its floor: low skips (exit 75), normal and high still run" {
  rate 2400
  run budget run low -- api repos/o/r
  [ "$status" -eq 75 ]
  [ "$output" = "gh-budget: out-of-budget priority=low resource=core remaining=2400 floor=2500 retry-at=2026-09-27T12:16:41Z" ]
  [ "$(count 'repos/o/r')" -eq 0 ]
  run budget run normal -- api repos/o/r
  [ "$status" -eq 0 ]
  run budget run high -- api repos/o/r
  [ "$status" -eq 0 ]
  run budget run urgent -- api repos/o/r
  [ "$status" -eq 2 ]
}

@test "out of budget: normal waits for a reset inside its bound, high waits for the reset past it" {
  rate 900 5000 30
  run budget run normal -- api repos/o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-budget: wait 31"* ]]; [[ "$output" == *"ok api repos/o/r"* ]]
  rm -rf "$ORCHESTRATE_STATE_DIR"
  rate 100
  run budget run normal -- api repos/o/r
  [ "$status" -eq 75 ]
  run budget run high -- api repos/o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-budget: wait 1001"* ]]
  GH_BUDGET_HIGH_MAX_WAIT=60 run budget run high -- api repos/o/r
  [ "$status" -eq 75 ]
}

@test "graphql and core are budgeted apart" {
  rate 0 4000; echo "{}" >"$FX/page1.json"
  run budget run normal -- api graphql -f query=q
  [ "$status" -eq 0 ]
  run budget run normal -- pr list --repo o/r
  [ "$status" -eq 0 ]
  run budget run normal -- api repos/o/r
  [ "$status" -eq 75 ]
  [[ "$output" == *"resource=core remaining=0"* ]]
}

@test "a rate-limit 403 with headroom left backs off that endpoint only, logged distinctly" {
  rate 4550 4000; touch "$FX/limited"; echo "{}" >"$FX/runs.json"
  run budget run normal -- run list --repo o/r
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh-budget: endpoint-limit endpoint=run list resource=core remaining=4550 retry-at=2026-09-27T12:05:00Z"* ]]
  run budget run normal -- run list --repo o/r --limit 5
  [ "$status" -eq 75 ]
  [[ "$output" == "gh-budget: endpoint-backoff endpoint=run list priority=normal retry-at=2026-09-27T12:05:00Z" ]]
  [ "$(count '^run list')" -eq 1 ]
  run budget run normal -- api "repos/o/r/actions/runs?branch=main"
  [ "$status" -eq 0 ]
  # Numeric path segments share one endpoint key.
  run budget run normal -- api repos/o/r/pulls/5/reviews --jq length
  [[ "$output" == *"endpoint-limit endpoint=repos/o/r/pulls/N/reviews "* ]]
  run budget run normal -- api repos/o/r/pulls/6/reviews
  [ "$status" -eq 75 ]
  run budget status
  [[ "$output" == *"core remaining="*"/5000 reset=2026-09-27T12:16:40Z floors high=150 normal=1000 low=2500"* ]]
  [[ "$output" == *"endpoint-limit endpoint=run list retry-at=2026-09-27T12:05:00Z"* ]]
  # With no headroom it is the resource that is exhausted, not the endpoint.
  rate 4550 4000; rate 0 4000 1000 rate-after.json
  run budget run high -- api repos/o/r/actions/workflows
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh-budget: exhausted resource=core retry-at=2026-09-27T12:16:40Z"* ]]
  [ ! -f "$ORCHESTRATE_STATE_DIR/gh-budget/endpoint-repos_o_r_actions_workflows" ]
}

@test "an unreadable /rate_limit fails open; exempt commands never read it" {
  run budget run normal -- api repos/o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-budget: unpaced resource=core"* ]]; [[ "$output" == *"ok api repos/o/r"* ]]
  rm -f "$FX/calls"
  run budget run low -- --version
  [ "$output" = "gh version 2.0" ]
  run budget run low -- api rate_limit
  [ "$(count '^api rate_limit')" -eq 1 ]
  [ "$(wc -l <"$FX/calls" | tr -d ' ')" -eq 2 ]
}

@test "the gh shim paces any caller at GH_BUDGET_PRIORITY and drops itself from PATH" {
  rate 2400
  export PATH="$SCRIPTS/gh-shim:$PATH"
  run gh api repos/o/r
  [ "$status" -eq 0 ]; [ "$output" = "ok api repos/o/r" ]
  [[ "$(cat "$FX/path")" != *gh-shim* ]]
  [ "$(count '^api rate_limit')" -eq 1 ]
  GH_BUDGET_PRIORITY=low run gh api repos/o/r
  [ "$status" -eq 75 ]
  rm -f "$FX/calls"
  GH_BUDGET_ACTIVE=1 run gh api repos/o/r
  [ "$status" -eq 0 ]
  [ "$(count '^api rate_limit')" -eq 0 ]
}

@test "gh-read reports a pacer refusal as budget (exit 9), keeps pacing waits inside its timeout" {
  export PATH="$SCRIPTS/gh-shim:$PATH"
  rate 2400
  GH_BUDGET_PRIORITY=low run "$SCRIPTS/gh-read.sh" -- api repos/o/r
  [ "$status" -eq 9 ]
  [[ "$output" == "gh-read: budget status=- request-id=- retry-at=2026-09-27T12:16:41Z msg=gh-budget: out-of-budget"* ]]
  [ "$(count 'repos/o/r')" -eq 0 ]
  rm -rf "$ORCHESTRATE_STATE_DIR"
  rate 900 5000 30   # a 31 s wait: fine for gh-budget alone, too long inside a 30 s attempt
  run "$SCRIPTS/gh-read.sh" -- api repos/o/r
  [ "$status" -eq 9 ]
  run "$SCRIPTS/gh-read.sh" --timeout 90 -- api repos/o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok api repos/o/r"* ]]
}

@test "sourcing _lib.sh with ORCHESTRATE_GH_BUDGET=1 puts the shim first on PATH once" {
  run bash -c 'source "$1/_lib.sh"; source "$1/_lib.sh"; orch_gh_priority high
    echo "${PATH%%:*}"; tr : "\n" <<<"$PATH" | grep -c gh-shim; echo "$GH_BUDGET_PRIORITY"' _ "$SCRIPTS"
  [ "${lines[1]}" = 0 ]; [ "${lines[2]}" = high ]
  ORCHESTRATE_GH_BUDGET=1 run bash -c 'source "$1/_lib.sh"; source "$1/_lib.sh"
    echo "${PATH%%:*}"; tr : "\n" <<<"$PATH" | grep -c gh-shim' _ "$SCRIPTS"
  [ "${lines[0]}" = "$SCRIPTS/gh-shim" ]; [ "${lines[1]}" = 1 ]
}

@test "every script that calls GitHub declares its budget priority" {
  missing=""
  for f in "$SCRIPTS"/*.sh; do
    case "${f##*/}" in _lib.sh | gh-read.sh | gh-budget.sh | bench.sh) continue ;; esac
    grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[^-a-z_])gh (api|pr|issue|run|repo|label|search|release|workflow)|gh-read\.sh|orch_read_retry|orch_repo|orch_author|orch_default_branch' || continue
    grep -qE '^(if declare -F orch_gh_priority >/dev/null; then )?orch_gh_priority (high|normal|low)(; fi)?$' "$f" || missing="$missing ${f##*/}"
  done
  [ -z "$missing" ] || { echo "no orch_gh_priority in:$missing"; false; }
  grep -qx 'orch_gh_priority high' "$SCRIPTS/pr-merge.sh"
  grep -qx 'orch_gh_priority high' "$SCRIPTS/main-health.sh"
}

@test "scripts avoid gh commands that make hidden extra requests (run list, run watch, workflow list/view)" {
  hits=$(cat "$SCRIPTS"/*.sh "$ROOT"/bin/*.sh | grep -vE '^[[:space:]]*#|hidden-requests-ok' |
    grep -nE '(^|[[:space:](])(gh|--|ghr|gh-read\.sh)[[:space:]]+(run (list|watch)|workflow (list|view)|pr checks[^#]*--watch)' || true)
  [ -z "$hits" ] || { echo "hidden-request gh commands: $hits"; false; }
}

@test "main-health reads actions/runs directly, never gh run list" {
  echo '{"total_count":1,"workflow_runs":[{"name":"CI","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":7,"created_at":"2026-09-27T01:00:00Z"}]}' >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main
  [ "$status" -eq 0 ]
  [ "$output" = "green aaaaaaaaa CI@aaaaaaaaa" ]
  grep -q '^api repos/o/r/actions/runs?branch=main&event=push&per_page=60' "$FX/calls"
  [ "$(count '^run list')" -eq 0 ]
}

page() { # N HAS_NEXT NODE_JSON...
  local n=$1 next=$2; shift 2
  printf '%s\n' "$@" | jq -s --argjson next "$next" \
    '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: $next, endCursor: "c1"}, nodes: .}}}}' >"$FX/page$n.json"
}
pr() { # NUMBER HEAD ROLLUP|"" REVIEW|"" REVIEW_COMMIT [draft]
  jq -cn --argjson n "$1" --arg h "$2" --arg r "$3" --arg s "$4" --arg c "$5" --arg d "${6:-}" \
    '{number: $n, headRefOid: $h, isDraft: ($d == "draft"),
      commits: {nodes: [{commit: {statusCheckRollup: (if $r == "" then null else {state: $r} end)}}]},
      reviews: {nodes: (if $s == "" then [] else [{state: $s, commit: {oid: $c}}] end)}}'
}
snapshot() { rm -f "$FX/gq"; run "$SCRIPTS/gh-snapshot.sh" --repo o/r "$@"; }

@test "gh-snapshot reads every open PR in one GraphQL call per page, cached per head SHA" {
  page 1 true "$(pr 1 aaaa SUCCESS APPROVED aaaa)" "$(pr 2 bbbb "" CHANGES_REQUESTED 0ld0)" "$(pr 3 cccc PENDING "" "" draft)"
  page 2 false "$(pr 4 dddd FAILURE "" "")"
  snapshot
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pr 1 head=aaaa draft=no rollup=SUCCESS review=APPROVED review-commit=aaaa reviewed=head cache=new" ]
  [ "${lines[1]}" = "pr 2 head=bbbb draft=no rollup=NONE review=CHANGES_REQUESTED review-commit=0ld0 reviewed=stale cache=new" ]
  [ "${lines[2]}" = "pr 3 head=cccc draft=yes rollup=PENDING review=NONE review-commit=- reviewed=none cache=new" ]
  [ "${lines[3]}" = "pr 4 head=dddd draft=no rollup=FAILURE review=NONE review-commit=- reviewed=none cache=new" ]
  [ "$(count '^api graphql')" -eq 2 ]
  [ "$(count '-f after=c1')" -eq 1 ]
  [ "$(count '^pr view')" -eq 0 ]
  # Unchanged heads read as same; a new roll-up on the same head as changed.
  snapshot
  [[ "$output" == *"pr 1 "*"cache=same"* ]]; [[ "$output" != *"cache=new"* ]]
  page 1 false "$(pr 1 aaaa FAILURE APPROVED aaaa)"
  snapshot --json
  [ "$(jq -r '.[0].cache' <<<"$output")" = changed ]
  [ "$(jq length <<<"$output")" -eq 1 ]
  # The cache keeps only heads that are still open.
  [ "$(ls "$ORCHESTRATE_STATE_DIR/o__r/pr-snapshot" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "gh-snapshot reports truncation past --limit, and an unreadable page without rows" {
  page 1 true "$(pr 1 aaaa SUCCESS "" "")" "$(pr 2 bbbb SUCCESS "" "")"
  snapshot --limit 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh-snapshot: truncated at --limit 2"* ]]
  grep -q -- '-F first=2' "$FX/calls"
  rm -f "$FX/page1.json"
  snapshot
  [ "$status" -eq 3 ]
  [[ "$output" != *"pr 1 "* ]]
}
