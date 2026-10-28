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
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  *graphql*) jq -n --args '{data: {repository: (reduce $ARGS.positional[] as $n ({};
      .["p" + $n] = {reviewThreads: {pageInfo: {hasNextPage: false}, nodes: []}}))}}' \
      $(printf '%s\n' "$*" | grep -oE ' p[0-9]+:' | tr -dc '0-9\n') ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "issue list"*) cat "$FX/issues.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$work/bin/gh"
export FX="$work/fx" PATH="$work/bin:$PATH" ORCHESTRATE_STATE_DIR="$work/state" ORCHESTRATE_AUTHOR=me
export ORCHESTRATE_NOW=1790510400

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

# codex-lane-wait.sh (#7): an unchanged run.
run="$work/run/codex.jsonl"
mkdir -p "${run%/*}"
: >"$run.spec"
printf 'Codex alive: yes\nChanged entries: 0\n\nMost recent agent message or command:\nworking\n' >"$run.progress.state"
echo rev1 >"$run.progress.rev"
measure lane-wait-unchanged "$waiter" --log "$run" --since rev1 --timeout 0
