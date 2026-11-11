#!/usr/bin/env bash
# Deterministic output-budget benchmarks: what the helper scripts put in front of a model, measured
# on fixed fixtures with a stubbed gh (no network, no model calls). Use it to compare prompt and
# output changes; budget.bats turns the numbers into ceilings.
#
# Usage: bench.sh [--timing] [CASE...]
# Output (TSV, with a header): case  stdout_bytes  rows  gh_calls
#   Bytes and rows are of stdout only. No token counts: they depend on a tokenizer, and none is
#   assumed here.
#   --timing  adds two columns, seconds (wall time of the case, 2 decimals) and jq_calls (jq
#             processes the case started, counted by a jq wrapper first on PATH; the stub gh's
#             own jq calls are not counted). They vary by machine: compare before and after a
#             change on one machine, never against a ceiling. Without it the output is unchanged.
#   CASE...   run only these cases (names as in the first column of the full output), plus the
#             cases each declares it needs, which run first and print no row. Rows come in the
#             full run's order and match its rows. With no CASE every case runs.
# Exit: 0 done, 2 bad usage. Bad usage is an unknown flag or case name; 1 means a case declares a
#   need that is not an earlier case (a bug in bench.sh itself).
set -euo pipefail
timing=0 picked=" " picked_list=()
for arg in "$@"; do
  case "$arg" in
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    --timing) timing=1 ;;
    -*) echo "bench.sh: unknown argument: $arg" >&2; exit 2 ;;
    *[!a-z0-9-]* | "") echo "bench.sh: unknown case: $arg" >&2; exit 2 ;;
    *) picked+="$arg " picked_list+=("$arg") ;;
  esac
done
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/fx"
real_jq=$(command -v jq)
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
jq() { "$REAL_JQ" "$@"; }   # the fixtures' jq: not the scripts' work, so not counted by --timing
all="$*"; printf '%s\n' "${all//$'\n'/ }" >>"$FX/calls"   # one line per call
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
  "api repos/o/r/issues?"*) cat "$FX/issues.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$work/bin/gh"
if [ "$timing" = 1 ]; then # count jq processes: one line per call, then the real jq
  printf '#!/bin/sh\necho >>"$FX/jq-calls"\nexec "$REAL_JQ" "$@"\n' >"$work/bin/jq"
  chmod +x "$work/bin/jq"
fi
export FX="$work/fx" PATH="$work/bin:$PATH" ORCHESTRATE_STATE_DIR="$work/state" ORCHESTRATE_AUTHOR=me
export REAL_JQ="$real_jq"
export ORCHESTRATE_NOW=1790510400
# triage-tick.sh reads host-load.sh: fixed readings, not this machine's load
export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768

# Wall clock in seconds: EPOCHREALTIME (bash 5) has microseconds; bash 3.2 falls back to whole seconds.
clock() { local t=${EPOCHREALTIME:-$(date +%s)}; printf '%s\n' "${t/,/.}"; }

measure() { # NAME CMD...: run CMD, report its stdout size, row count and gh calls (and with --timing, seconds and jq calls)
  local name=$1 out start end
  shift
  : >"$FX/calls"
  : >"$FX/jq-calls"
  start=$(clock)
  out=$("$@" 2>/dev/null || true)
  end=$(clock)
  printf '%s\t%s\t%s\t%s' "$name" "$(printf '%s' "$out" | wc -c | tr -d ' ')" \
    "$(if [[ -n $out ]]; then printf '%s\n' "$out" | wc -l | tr -d ' '; else echo 0; fi)" \
    "$(wc -l <"$FX/calls" | tr -d ' ')"
  if [ "$timing" = 1 ]; then
    printf '\t%s\t%s' "$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e - s }')" \
      "$(wc -l <"$FX/jq-calls" | tr -d ' ')"
  fi
  printf '\n'
}


# The cases, in output order. `bench_case NAME [NEED...]` declares the function case_NAME below it
# (dashes as underscores). Each case writes the fixtures it reads; a NEED is an earlier case whose
# leftover state (in $ORCHESTRATE_STATE_DIR) changes this case's row, so picking NAME alone runs its
# NEEDs first, without printing their rows.
all_cases=" " rev_cases=""
bench_case() {
  local name=$1 need
  shift
  for need in "$@"; do
    [[ $all_cases == *" $need "* ]] || { echo "bench.sh: case $name needs $need, which is not an earlier case" >&2; exit 1; }
  done
  all_cases+="$name " rev_cases="$name $rev_cases"
  printf -v "needs_${name//-/_}" '%s' "$*"
}
pr_rows() {
  jq -n --argjson n "$1" '[range(1; $n + 1) | {number: ., author: {login: "me"}, isDraft: false,
    isCrossRepository: false, baseRefName: "main", headRefOid: ("abcdef0123456789" + tostring),
    mergeable: "MERGEABLE", labels: [],
    statusCheckRollup: [{name: "build", conclusion: "SUCCESS", startedAt: "2026-09-27T01:00:00Z"}]}]' >"$FX/prs.json"
}
# The REST path (#109): the stub refuses GraphQL while $FX/rest exists. Allowing it again also
# forgets the refusal (orch_gh_api remembers it in the state root).
graphql_refused() { touch "$FX/rest"; }
graphql_allowed() { rm -f "$FX/rest" "$ORCHESTRATE_STATE_DIR/gh-no-graphql"; }

# excerpt.sh (#2): a large matching log and one megabyte line.
bench_case excerpt-20k-failures
case_excerpt_20k_failures() {
  awk 'BEGIN { for (i = 1; i <= 20000; i++) printf "error failure %d: %0100d\n", i, 0 }' >"$work/large.log"
  measure excerpt-20k-failures "$here/excerpt.sh" "$work/large.log"
}
bench_case excerpt-1mb-line
case_excerpt_1mb_line() {
  awk 'BEGIN { printf "error "; for (i = 0; i < 1000000; i++) printf "x"; print "" }' >"$work/wide.log"
  measure excerpt-1mb-line "$here/excerpt.sh" "$work/wide.log"
}

# issue-candidates.sh dupes (#3): 400 identical titles.
bench_case dupes-400-identical
case_dupes_400_identical() {
  jq -n '[range(1; 401) | {number: ., title: "Fix shared device session recovery failure"}]' >"$FX/issues.json"
  measure dupes-400-identical "$here/issue-candidates.sh" dupes --repo o/r
}

# pr-ready.sh (#4): 20 and 100 ready PRs, then an unchanged --delta pass.
bench_case pr-ready-20-ready
case_pr_ready_20_ready() {
  graphql_allowed
  pr_rows 20
  measure pr-ready-20-ready "$here/pr-ready.sh" --repo o/r --base main
}
bench_case pr-ready-100-ready
case_pr_ready_100_ready() {
  graphql_allowed
  pr_rows 100
  measure pr-ready-100-ready "$here/pr-ready.sh" --repo o/r --base main
}
bench_case pr-ready-delta-unchanged
case_pr_ready_delta_unchanged() { # the pass before it, unmeasured, is what leaves nothing changed
  graphql_allowed
  pr_rows 100
  "$here/pr-ready.sh" --repo o/r --base main --delta >/dev/null 2>&1
  measure pr-ready-delta-unchanged "$here/pr-ready.sh" --repo o/r --base main --delta
}
# The same PRs where GraphQL is refused (#109): REST costs a constant plus a few calls per ready PR.
bench_case pr-ready-rest-20-ready
case_pr_ready_rest_20_ready() {
  graphql_refused
  pr_rows 20
  measure pr-ready-rest-20-ready "$here/pr-ready.sh" --repo o/r --base main
}
# It starts over REST without asking GraphQL: the refusal the 20-PR pass remembered saves one call.
bench_case pr-ready-rest-100-ready pr-ready-rest-20-ready
case_pr_ready_rest_100_ready() {
  graphql_refused
  pr_rows 100
  measure pr-ready-rest-100-ready "$here/pr-ready.sh" --repo o/r --base main
}

# triage-tick.sh snapshot with 50 open PRs (#118): the open count and last reviews come from one
# gh-snapshot.sh call. Then the same where GraphQL is refused, where the snapshot goes REST per PR.
bench_case triage-tick-50-open
case_triage_tick_50_open() {
  graphql_allowed
  pr_rows 50
  echo '[{"number":900,"labels":[]}]' >"$FX/issues.json"
  measure triage-tick-50-open "$here/triage-tick.sh" snapshot --repo o/r --branch main
}
bench_case triage-tick-rest-50-open
case_triage_tick_rest_50_open() {
  graphql_refused
  pr_rows 50
  echo '[{"number":900,"labels":[]}]' >"$FX/issues.json"
  measure triage-tick-rest-50-open "$here/triage-tick.sh" snapshot --repo o/r --branch main
}
# review-gate.sh check for one PR: its own reads, then with a fresh snapshot row for its head.
bench_case review-gate-check-cold
case_review_gate_check_cold() {
  graphql_allowed
  pr_rows 50
  "$here/review-gate.sh" policy review-at-head --repo o/r >/dev/null
  rm -rf "$ORCHESTRATE_STATE_DIR/o__r/pr-snapshot"
  measure review-gate-check-cold env -u ORCHESTRATE_NOW "$here/review-gate.sh" check --repo o/r --pr 7
}
bench_case review-gate-check-snapshot
case_review_gate_check_snapshot() {
  graphql_allowed
  pr_rows 50
  "$here/review-gate.sh" policy review-at-head --repo o/r >/dev/null
  "$here/gh-snapshot.sh" --repo o/r >/dev/null 2>&1 || true
  measure review-gate-check-snapshot env -u ORCHESTRATE_NOW "$here/review-gate.sh" check --repo o/r --pr 7
}

# Which cases run: all of them, or the picked ones and (latest first, so needs of needs follow)
# what each needs. Every NEED is an earlier case, so one pass from the end closes the set.
want=$all_cases
if [ "$picked" != " " ]; then
  for name in "${picked_list[@]}"; do
    [[ $all_cases == *" $name "* ]] || { echo "bench.sh: unknown case: $name" >&2; exit 2; }
  done
  want=$picked
  for name in $rev_cases; do
    [[ $want == *" $name "* ]] || continue
    needs="needs_${name//-/_}"
    for need in ${!needs}; do want+="$need "; done
  done
fi

if [ "$timing" = 1 ]; then
  printf 'case\tstdout_bytes\trows\tgh_calls\tseconds\tjq_calls\n'
else
  printf 'case\tstdout_bytes\trows\tgh_calls\n'
fi
for name in $all_cases; do
  [[ $want == *" $name "* ]] || continue
  if [ "$picked" = " " ] || [[ $picked == *" $name "* ]]; then
    "case_${name//-/_}"
  else
    "case_${name//-/_}" >/dev/null
  fi
done
