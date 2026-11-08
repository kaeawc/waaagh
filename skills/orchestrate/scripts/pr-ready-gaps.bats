#!/usr/bin/env bats
# pr-ready.sh paths the other suites do not reach: review threads followed through cursors with
# unresolved threads on later pages, an unreadable later page, --hold-label, --min-pass and
# --exclude-label rows (with the ready-but-skipped summary). Stubbed gh. Run: bats scripts/pr-ready-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  # Review threads: $FX/t<n>-<page>.json holds the nodes of page <page> (1-based) of PR <n>; a
  # page file that is missing ends the PR's pages. The first page comes from the batched query,
  # later ones through the cursor c<page>. $FX/page-fails: a cursor whose page answers HTTP 502.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
page() { # N P -> reviewThreads object for page P of PR N
  jq -n --argjson nodes "$(cat "$FX/t$1-$2.json" 2>/dev/null || echo '[]')" \
    --argjson more "$([ -f "$FX/t$1-$(($2 + 1)).json" ] && echo true || echo false)" --arg c "c$(($2 + 1))" \
    '{pageInfo: {hasNextPage: $more, endCursor: (if $more then $c else null end)}, nodes: $nodes}'
}
case "$*" in
  "api user") echo '{"login":"me"}' ;;
  *rules/branches*) echo '[]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*"cursor=c"*)
    n=$(printf '%s\n' "$*" | sed -nE 's/.*-F pr=([0-9]+).*/\1/p')
    c=$(printf '%s\n' "$*" | sed -nE 's/.*-f cursor=(c[0-9]+).*/\1/p')
    echo "page $n $c" >>"$FX/pages"
    if grep -qx "$c" "$FX/page-fails" 2>/dev/null; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
    jq -n --argjson t "$(page "$n" "${c#c}")" '{data: {repository: {pullRequest: {reviewThreads: $t}}}}' ;;
  *graphql*)
    out='{}'
    for n in $(printf '%s\n' "$*" | grep -oE ' p[0-9]+:' | tr -dc '0-9\n'); do
      out=$(jq -c --arg k "p$n" --argjson t "$(page "$n" 1)" '.[$k] = {reviewThreads: $t}' <<<"$out")
    done
    jq -n --argjson r "$out" '{data: {repository: $r}}' ;;
  "pr list"*) cat "$FX/prs.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
}

OKC='[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]'
pr_row() { # number [labels-json] [checks-json]
  jq -cn --argjson n "$1" --argjson l "${2:-[]}" --argjson c "${3:-$OKC}" \
    '{number:$n,author:{login:"me"},isDraft:false,isCrossRepository:false,baseRefName:"main",headRefName:("b"+($n|tostring)),
      headRefOid:("abcdef0123456789"+($n|tostring)),mergeable:"MERGEABLE",labels:$l,statusCheckRollup:$c}'
}
threads() { # N PAGE RESOLVED UNRESOLVED -> a page of that many resolved and unresolved threads
  jq -n --argjson r "$3" --argjson u "$4" \
    '[range(0; $r) | {isResolved: true, isOutdated: false}] + [range(0; $u) | {isResolved: false, isOutdated: false}]' >"$FX/t$1-$2.json"
}
ready() { "$SCRIPTS/pr-ready.sh" --repo o/r --base main --author me "$@"; }
row() { printf '%s\n' "$output" | awk -F'\t' -v n="$1" '$1 == n { print $2 "\t" $6 }'; }

@test "unresolved threads on later pages are added up through the cursors" {
  pr_row 7 | jq -s . >"$FX/prs.json"
  threads 7 1 99 1
  threads 7 2 98 2
  threads 7 3 0 0
  run ready
  [ "$status" -eq 0 ]
  [ "$(row 7)" = $'BLOCK\tthreads=3' ]
  [ "$(cat "$FX/pages")" = $'page 7 c2\npage 7 c3' ]
  [[ "$output" == *"open=1 ready=0"* ]]
}

@test "an unreadable later thread page makes the count unknown, never zero, and is noted" {
  pr_row 7 | jq -s . >"$FX/prs.json"
  threads 7 1 100 0
  threads 7 2 100 0
  echo c2 >"$FX/page-fails"
  run ready
  [ "$status" -eq 0 ]
  [ "$(row 7)" = $'BLOCK\tthreads=unknown' ]
  diag=$(printf '%s\n' "$output" | sed -n 's/.*diagnostics=//p')
  [ -n "$diag" ]
  grep -q 'PR 7: review thread page after c2 unreadable' "$diag"
}

@test "--hold-label replaces the default hold label; a held ready PR is counted as ready-but-skipped" {
  { pr_row 1 '[{"name":"parked"}]'; pr_row 2 '[{"name":"hold"}]'; } | jq -s . >"$FX/prs.json"
  run ready --hold-label parked
  [ "$status" -eq 0 ]
  [ "$(row 1)" = $'SKIP\thold ready-but-skipped' ]
  [ "$(row 2)" = $'READY\t-' ]
  [[ "$output" == *"open=2 ready=1 ready-but-skipped=1 skipped-by=hold:1"* ]]
  run ready
  [ "$(row 1)" = $'READY\t-' ]
  [ "$(row 2)" = $'SKIP\thold ready-but-skipped' ]
}

@test "--min-pass blocks a PR with fewer passing checks than required" {
  pr_row 3 | jq -s . >"$FX/prs.json"
  run ready --min-pass 2 --no-threads
  [ "$(row 3)" = $'BLOCK\tfew-checks=1' ]
  [[ "$output" == *"ready=0"* ]]
  pr_row 3 '[]' '[{"name":"build","conclusion":"SUCCESS"},{"name":"lint","conclusion":"SKIPPED"}]' | jq -s . >"$FX/prs.json"
  run ready --min-pass 2 --no-threads
  [ "$(row 3)" = $'READY\t-' ]
}

@test "--exclude-label rows: the first excluded label is named, and only an otherwise ready PR counts as skipped-ready" {
  {
    pr_row 1 '[{"name":"bug"},{"name":"dependencies"},{"name":"ci"}]'
    pr_row 2 '[{"name":"ci"}]' '[{"name":"build","conclusion":"FAILURE"}]'
    pr_row 3 '[{"name":"ci"}]'
    pr_row 4
  } | jq -s . >"$FX/prs.json"
  threads 3 1 0 1
  run ready --exclude-label dependencies --exclude-label ci
  [ "$status" -eq 0 ]
  [ "$(row 1)" = $'SKIP\tlabel:dependencies ready-but-skipped' ]
  [ "$(row 2)" = $'SKIP\tlabel:ci' ]
  [ "$(row 3)" = $'SKIP\tlabel:ci' ]          # an unresolved thread: not ready, not counted
  [ "$(row 4)" = $'READY\t-' ]
  [[ "$output" == *"open=4 ready=1 ready-but-skipped=1 skipped-by=label:1"* ]]
}
