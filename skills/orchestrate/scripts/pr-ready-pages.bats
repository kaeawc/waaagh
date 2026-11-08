#!/usr/bin/env bats
# pr-ready.sh: smaller-page fallback when the statusCheckRollup list times out, and PR_READY_EXTRA
# for named PRs a full page left out (#62).

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  # $FX/fail-limits: list limits that answer HTTP 504; $FX/list-status: HTTP status to fail with.
  # The list serves the first <limit> rows of prs.json; pr view serves view-<n>.json.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api user") echo '{"login":"me"}' ;;
  *rules/branches*) echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  "pr list"*)
    lim=$(printf '%s\n' "$*" | sed -nE 's/.*--limit ([0-9]+).*/\1/p')
    if grep -qx "$lim" "$FX/fail-limits" 2>/dev/null; then
      echo "HTTP $(cat "$FX/list-status" 2>/dev/null || echo 504): Gateway Timeout" >&2; exit 1
    fi
    jq --argjson l "$lim" '.[:$l]' "$FX/prs.json" ;;
  "pr view"*) n=$3; [ -f "$FX/view-$n.json" ] || { echo "HTTP 502" >&2; exit 1; }; cat "$FX/view-$n.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
}

OKC='[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]'
pr_row() { # number [state]
  jq -cn --argjson n "$1" --argjson c "$OKC" --arg s "${2:-}" \
    '{number:$n,author:{login:"me"},isDraft:false,isCrossRepository:false,baseRefName:"main",
      headRefOid:("abcdef0123456789"+($n|tostring)),mergeable:"MERGEABLE",labels:[],statusCheckRollup:$c}
     + (if $s == "" then {} else {state:$s} end)'
}
prs() { # first last: green PRs, newest first like gh
  for ((i = $2; i >= $1; i--)); do pr_row "$i"; done | jq -s . >"$FX/prs.json"
}
ready() { "$SCRIPTS/pr-ready.sh" --repo o/r --base main --author me --no-threads "$@"; }

@test "a timed-out page of 300 falls back to smaller pages and says so" {
  prs 1 100
  printf '300\n120\n' >"$FX/fail-limits"
  run ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"limit 300 failed"*"retrying with limit 120"* ]]
  [[ "$output" == *"limit 120 failed"*"retrying with limit 60"* ]]
  [ "$(printf '%s\n' "$output" | grep -c $'\tREADY\t')" -eq 60 ]
  [[ "$output" == *"open=60 ready=60 truncated=yes page=60"* ]]
  # Two tries per failing size (the same size rarely recovers), then 60 once.
  [ "$(grep -c -- '--limit 300' "$FX/calls")" -eq 2 ]
  [ "$(grep -c -- '--limit 120' "$FX/calls")" -eq 2 ]
  [ "$(grep -c -- '--limit 60' "$FX/calls")" -eq 1 ]
}

@test "an EXTRA PR missing from the smaller page is read on its own and classified" {
  prs 1 100   # the page of 60 holds 41..100; PR 3 is old
  printf '300\n120\n' >"$FX/fail-limits"
  pr_row 3 OPEN >"$FX/view-3.json"
  pr_row 5 MERGED >"$FX/view-5.json"
  PR_READY_EXTRA="3 5 77" run ready
  [ "$status" -eq 0 ]
  [[ "$output" == *$'3\tREADY\tabcdef012'* ]]
  [[ "$output" != *$'\n5\t'* ]]                  # not open any more
  [ "$(grep -c '^pr view' "$FX/calls")" -eq 2 ]  # 77 was on the page
  [[ "$output" == *"open=61 ready=61"* ]]
  # --pr names a PR the same way.
  rm "$FX/calls"
  run ready --pr 3
  [ "$(printf '%s\n' "$output" | grep -c $'\tREADY\t')" -eq 1 ]
  [[ "$output" == *$'3\tREADY'* ]]
}

@test "an unreadable EXTRA PR is reported, not silently dropped" {
  prs 1 100
  printf '300\n120\n' >"$FX/fail-limits"
  PR_READY_EXTRA="4" run ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"extra-unreadable=4"* ]]
  [[ "$output" == *"diagnostics="* ]]
}

@test "a page that is not full needs no extra reads" {
  prs 1 10
  PR_READY_EXTRA="3 999" run ready
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pr view' "$FX/calls" || true)" -eq 0 ]
  [[ "$output" == *"open=10 ready=10"* ]]
  [[ "$output" != *"page="* ]]
}

@test "every limit failing exits 3 with no verdicts; a non-transient error does not fall back" {
  prs 1 10
  printf '300\n120\n60\n30\n' >"$FX/fail-limits"
  run ready
  [ "$status" -eq 3 ]
  [[ "$output" != *READY* ]]
  [[ "$output" == *"no verdicts"* ]]
  grep -q -- '--limit 30' "$FX/calls"
  rm "$FX/calls"
  echo 401 >"$FX/list-status"
  run ready
  [ "$status" -eq 3 ]
  [ "$(grep -c '^pr list' "$FX/calls")" -eq 1 ]
}
