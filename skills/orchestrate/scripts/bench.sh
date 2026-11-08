#!/usr/bin/env bash
# Deterministic output-budget benchmarks: what the helper scripts put in front of a model, measured
# on fixed fixtures with a stubbed gh (no network, no model calls). Use it to compare prompt and
# output changes; budget.bats turns the numbers into ceilings.
#
# Usage: bench.sh
# Output (TSV, with a header): case  stdout_bytes  rows  gh_calls
#   Bytes and rows are of stdout only. No token counts: they depend on a tokenizer, and none is
#   assumed here.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
waiter="$here/../../../bin/codex-lane-wait.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/fx"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >>"$FX/calls"   # one line per call
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  # gh-snapshot.sh's open-PR query, and thread-sweep.sh's (pages of 25 by cursor), from prs.json;
  # both refused like a cloud session while $FX/rest exists (#118).
  *"api graphql"*"pullRequests(states: OPEN"* | *"api graphql"*"pullRequests(states:OPEN"*)
    if [ -f "$FX/rest" ]; then echo "HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the REST API" >&2; exit 1; fi
    case "$*" in
      *"states: OPEN"*) jq '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: false, endCursor: null},
          nodes: map({number, headRefOid, isDraft, commits: {nodes: [{commit: {statusCheckRollup: {state: "SUCCESS"}}}]},
            reviews: {nodes: (if .number % 2 == 0 then [{state: "COMMENTED", commit: {oid: .headRefOid}}] else [] end)}})}}}}' "$FX/prs.json" ;;
      *) c=$(printf '%s\n' "$*" | sed -nE 's/.* cursor=([0-9]+).*/\1/p')
        jq --argjson c "${c:-0}" '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: (length > $c + 25), endCursor: ($c + 25 | tostring)},
          nodes: [.[$c:($c + 25)][] | {number, commits: {nodes: []}, reviewThreads: {pageInfo: {hasNextPage: false}, nodes: []}}]}}}}' "$FX/prs.json" ;;
    esac ;;
  "api repos/o/r/actions/runs?branch="*) echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-09-27T01:00:00Z"}]}' ;;
  *"/pulls/"*"/reviews"*) n=$(printf '%s\n' "$*" | sed -nE 's#.*/pulls/([0-9]+)/reviews.*#\1#p')
    jq --argjson n "$n" '[.[] | select(.number == $n and .number % 2 == 0)
      | {user: {login: "someone"}, state: "COMMENTED", commit_id: .headRefOid, body: "ok", submitted_at: "2026-09-27T01:00:00Z"}]' "$FX/prs.json" ;;
  *"/issues/"*"/comments"*) echo '[]' ;;
  "pr view"*"--json headRefOid") n=${3}; jq --argjson n "$n" '.[] | select(.number == $n) | {headRefOid}' "$FX/prs.json" ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) jq -n --args '{data: {repository: (reduce $ARGS.positional[] as $n ({};
      .["p" + $n] = {reviewThreads: {pageInfo: {hasNextPage: false}, nodes: []}}))}}' \
      $(printf '%s\n' "$*" | grep -oE ' p[0-9]+:' | tr -dc '0-9\n') ;;
  "pr list"*) if [ -f "$FX/rest" ]; then echo "HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the REST API" >&2; exit 1; fi
    cat "$FX/prs.json" ;;
  # The REST path (#109), from the same rows: list pages, then per PR mergeable, checks, status and threads.
  *"pulls?state=open"*) p=$(printf '%s\n' "$*" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p')
    jq --argjson p "$p" '.[(($p - 1) * 100):($p * 100)] | map({number, draft: false, user: {login: .author.login},
      base: {ref: "main", repo: {full_name: "o/r"}}, head: {ref: "b", sha: .headRefOid, repo: {full_name: "o/r"}}, labels: []})' "$FX/prs.json" ;;
  *"/ccr/review_threads"*) echo '[]' ;;
  "api repos/o/r/pulls/"*) n=${2#repos/o/r/pulls/}
    jq --argjson n "$n" '.[] | select(.number == $n) | {number, draft: false, user: {login: .author.login}, mergeable: true,
      base: {ref: "main", repo: {full_name: "o/r"}}, head: {ref: "b", sha: .headRefOid, repo: {full_name: "o/r"}}, labels: []}' "$FX/prs.json" ;;
  *"/check-runs"*) echo '{"total_count":1,"check_runs":[{"name":"build","status":"completed","conclusion":"success","started_at":"2026-09-27T01:00:00Z"}]}' ;;
  *"/status"*) echo '{"state":"pending","statuses":[]}' ;;
  "issue list"*) cat "$FX/issues.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$work/bin/gh"
export FX="$work/fx" PATH="$work/bin:$PATH" ORCHESTRATE_STATE_DIR="$work/state" ORCHESTRATE_AUTHOR=me
export ORCHESTRATE_NOW=1790510400
# triage-tick.sh reads host-load.sh: fixed readings, not this machine's load
export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768

printf 'case\tstdout_bytes\trows\tgh_calls\n'
measure() { # NAME CMD...: run CMD, report its stdout size, row count and gh calls
  local name=$1 out
  shift
  : >"$FX/calls"
  out=$("$@" 2>/dev/null || true)
  printf '%s\t%s\t%s\t%s\n' "$name" "$(printf '%s' "$out" | wc -c | tr -d ' ')" \
    "$(if [[ -n $out ]]; then printf '%s\n' "$out" | wc -l | tr -d ' '; else echo 0; fi)" \
    "$(wc -l <"$FX/calls" | tr -d ' ')"
}

# excerpt.sh (#2): a large matching log and one megabyte line.
awk 'BEGIN { for (i = 1; i <= 20000; i++) printf "error failure %d: %0100d\n", i, 0 }' >"$work/large.log"
awk 'BEGIN { printf "error "; for (i = 0; i < 1000000; i++) printf "x"; print "" }' >"$work/wide.log"
measure excerpt-20k-failures "$here/excerpt.sh" "$work/large.log"
measure excerpt-1mb-line "$here/excerpt.sh" "$work/wide.log"

# issue-candidates.sh dupes (#3): 400 identical titles.
jq -n '[range(1; 401) | {number: ., title: "Fix shared device session recovery failure"}]' >"$FX/issues.json"
measure dupes-400-identical "$here/issue-candidates.sh" dupes --repo o/r

# pr-ready.sh (#4): 20 and 100 ready PRs, then an unchanged --delta pass.
pr_rows() {
  jq -n --argjson n "$1" '[range(1; $n + 1) | {number: ., author: {login: "me"}, isDraft: false,
    isCrossRepository: false, baseRefName: "main", headRefOid: ("abcdef0123456789" + tostring),
    mergeable: "MERGEABLE", labels: [],
    statusCheckRollup: [{name: "build", conclusion: "SUCCESS", startedAt: "2026-09-27T01:00:00Z"}]}]'
}
pr_rows 20 >"$FX/prs.json"
measure pr-ready-20-ready "$here/pr-ready.sh" --repo o/r --base main
pr_rows 100 >"$FX/prs.json"
measure pr-ready-100-ready "$here/pr-ready.sh" --repo o/r --base main
"$here/pr-ready.sh" --repo o/r --base main --delta >/dev/null 2>&1
measure pr-ready-delta-unchanged "$here/pr-ready.sh" --repo o/r --base main --delta
# The same PRs where GraphQL is refused (#109): REST costs a constant plus a few calls per ready PR.
touch "$FX/rest"
pr_rows 20 >"$FX/prs.json"
measure pr-ready-rest-20-ready "$here/pr-ready.sh" --repo o/r --base main
pr_rows 100 >"$FX/prs.json"
measure pr-ready-rest-100-ready "$here/pr-ready.sh" --repo o/r --base main
rm -f "$FX/rest" "$ORCHESTRATE_STATE_DIR/gh-no-graphql"   # and forget the refusal (orch_gh_api)

# triage-tick.sh snapshot with 50 open PRs (#118): the open count and last reviews come from one
# gh-snapshot.sh call. Then the same where GraphQL is refused, where the snapshot goes REST per PR.
pr_rows 50 >"$FX/prs.json"
echo '[{"number":900,"labels":[]}]' >"$FX/issues.json"
measure triage-tick-50-open "$here/triage-tick.sh" snapshot --repo o/r --branch main
touch "$FX/rest"
measure triage-tick-rest-50-open "$here/triage-tick.sh" snapshot --repo o/r --branch main
rm -f "$FX/rest" "$ORCHESTRATE_STATE_DIR/gh-no-graphql"   # and forget the refusal (orch_gh_api)
# review-gate.sh check for one PR: its own reads, then with a fresh snapshot row for its head.
"$here/review-gate.sh" policy review-at-head --repo o/r >/dev/null
rm -rf "$ORCHESTRATE_STATE_DIR/o__r/pr-snapshot"
measure review-gate-check-cold env -u ORCHESTRATE_NOW "$here/review-gate.sh" check --repo o/r --pr 7
"$here/gh-snapshot.sh" --repo o/r >/dev/null 2>&1 || true
measure review-gate-check-snapshot env -u ORCHESTRATE_NOW "$here/review-gate.sh" check --repo o/r --pr 7

# codex-lane-wait.sh (#7): an unchanged run.
run="$work/run/codex.jsonl"
mkdir -p "${run%/*}"
: >"$run.spec"
printf 'Codex alive: yes\nChanged entries: 0\n\nMost recent agent message or command:\nworking\n' >"$run.progress.state"
echo rev1 >"$run.progress.rev"
measure lane-wait-unchanged "$waiter" --log "$run" --since rev1 --timeout 0
