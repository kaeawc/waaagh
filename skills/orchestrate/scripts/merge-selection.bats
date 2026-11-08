#!/usr/bin/env bats
# Merge-loop selection (#69): PRs are selected by author and readiness, never by branch name;
# exclusions are explicit (hold, labels, an optional head-branch regex) and a skipped PR that is
# otherwise READY is reported every pass. Lane branches are named work/<issue>-<slug>.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  # prs.json: the open PR list. threads-<n>: unresolved review threads of PR n (default 0).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api user") echo '{"login":"me"}' ;;
  *rules/branches*) echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "api graphql"*)
    q=$(printf '%s\n' "$@" | sed -n 's/^query=//p')
    printf '%s' '{"data":{"repository":{'
    sep=""
    for n in $(printf '%s\n' "$q" | grep -oE 'p[0-9]+:' | tr -d 'p:'); do
      t=$(cat "$FX/threads-$n" 2>/dev/null || echo 0)
      nodes=$(jq -cn --argjson t "$t" '[range($t) | {isResolved:false,isOutdated:false}]')
      printf '%s"p%s":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}}' "$sep" "$n" "$nodes"
      sep=,
    done
    echo '}}}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
}

OKC='[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]'
BADC='[{"name":"build","conclusion":"FAILURE","startedAt":"2026-09-27T01:00:00Z"}]'
pr() { # number branch [labels-json] [checks-json] [author]
  jq -cn --argjson n "$1" --arg b "$2" --argjson l "${3:-[]}" --argjson c "${4:-$OKC}" --arg a "${5:-me}" \
    '{number:$n,author:{login:$a},isDraft:false,isCrossRepository:false,baseRefName:"main",headRefName:$b,
      headRefOid:("abcdef0123456789"+($n|tostring)),mergeable:"MERGEABLE",
      labels:($l | map({name:.})),statusCheckRollup:$c}'
}
ready() { "$SCRIPTS/pr-ready.sh" --repo o/r --base main --author me "$@"; }

@test "PRs are judged whatever their branch is named; other authors stay out" {
  { pr 1 work/l-16900-fix; pr 2 work/lane-l-7; pr 3 work/ax-bridge-4; pr 4 work/l12-x; pr 5 claude/y
    pr 6 work/9-z '[]' "$OKC" someone-else; } | jq -s . >"$FX/prs.json"
  run ready
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c $'\tREADY\t')" -eq 5 ]
  [[ "$output" != *$'\n6\t'* ]]
  [[ "$output" == *"open=5 ready=5" ]]
  [[ "$output" != *ready-but-skipped* ]]
}

@test "a head-branch filter skips visibly and counts ready PRs it hid" {
  { pr 1 work/l-16900-fix; pr 2 work/2-ok; pr 3 work/l-3-red '[]' "$BADC"; } | jq -s . >"$FX/prs.json"
  run ready --head-match '^work/[0-9]+-'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tSKIP\tabcdef012\tMERGEABLE\t1\tbranch ready-but-skipped'* ]]
  [[ "$output" == *$'2\tREADY\t'* ]]
  [[ "$output" == *$'3\tSKIP\tabcdef012\tMERGEABLE\t0\tbranch'$'\n'* ]]   # not ready: not counted
  [[ "$output" == *"open=3 ready=1 ready-but-skipped=1 skipped-by=branch:1" ]]
  run ready --head-match '('
  [ "$status" -eq 2 ]
}

@test "label exclusions and holds are SKIP rows, and ready ones are counted by reason" {
  { pr 1 work/1-a '["dependencies"]'; pr 2 work/2-b '["hold"]'; pr 3 work/3-c; pr 4 work/4-d '["x","dependencies"]'
    pr 5 work/5-e '["dependencies"]' "$BADC"; } | jq -s . >"$FX/prs.json"
  run ready --exclude-label dependencies --hold 3
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tSKIP\tabcdef012\tMERGEABLE\t1\tlabel:dependencies ready-but-skipped'* ]]
  [[ "$output" == *$'2\tSKIP\tabcdef012\tMERGEABLE\t1\thold ready-but-skipped'* ]]
  [[ "$output" == *$'3\tSKIP\tabcdef012\tMERGEABLE\t1\thold ready-but-skipped'* ]]
  [[ "$output" == *$'4\tSKIP\tabcdef012\tMERGEABLE\t1\tlabel:dependencies ready-but-skipped'* ]]
  [[ "$output" == *$'5\tSKIP\tabcdef012\tMERGEABLE\t0\tlabel:dependencies'$'\n'* ]]
  [[ "$output" == *"open=5 ready=0 ready-but-skipped=4 skipped-by=hold:2,label:2" ]]
  # Without the exclusion the dependabot-labelled PRs are ordinary rows.
  run ready
  [[ "$output" == *$'1\tREADY\t'* ]]
}

@test "a skipped PR with unresolved review threads is not reported as ready" {
  { pr 1 x/1 '["hold"]'; pr 2 x/2 '["hold"]'; } | jq -s . >"$FX/prs.json"
  echo 2 >"$FX/threads-2"
  run ready
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tSKIP\tabcdef012\tMERGEABLE\t1\thold ready-but-skipped'* ]]
  [[ "$output" == *$'2\tSKIP\tabcdef012\tMERGEABLE\t1\thold'$'\n'* ]]
  [[ "$output" == *"ready-but-skipped=1 skipped-by=hold:1" ]]
  grep -q 'p1: pullRequest' "$FX/calls"
}

@test "lane-claim notes a lane branch not named work/<issue>-<slug>" {
  echo '[]' >"$FX/prs.json"
  err="$BATS_TEST_TMPDIR/err"
  "$SCRIPTS/lane-claim.sh" add --worktree wt-a --branch work/l-20-x --issues 20 --files a.ts --repo o/r 2>"$err"
  grep -q 'not named work/20-<slug>' "$err"
  "$SCRIPTS/lane-claim.sh" add --worktree wt-b --branch work/21-fix-login --issues 21,22 --files b.ts --repo o/r 2>"$err"
  [ ! -s "$err" ]
}

@test "doctrine: the merge bot never filters by branch name and reports ready-but-skipped" {
  grep -q 'Never filter' "$ROOT/skills/orchestrate/roles/merge-bot.md"
  grep -q 'ready-but-skipped' "$ROOT/skills/orchestrate/roles/merge-bot.md"
  grep -q '{{EXCLUDE_LABELS}}' "$ROOT/skills/orchestrate/roles/README.md"
  grep -q 'work/<issue>-<slug>' "$ROOT/skills/orchestrate/SKILL.md"
}
