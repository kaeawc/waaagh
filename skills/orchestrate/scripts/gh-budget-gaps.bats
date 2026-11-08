#!/usr/bin/env bats
# Gaps in gh-budget.bats: out of budget because the next slot is too far away (normal and low),
# the search resource, endpoint and resource detection for flag-heavy `api` calls, an endpoint
# backoff waited out inside the bound, and lock contention falling back to an unlocked call.
# Fake clock: waits are logged, not slept. Run: bats gh-budget-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_BUDGET_FAKE_SLEEP=1   # 2026-09-27T12:00:00Z
  unset GH_BUDGET_PRIORITY GH_BUDGET_ACTIVE GH_BUDGET_MAX_WAIT GH_BUDGET_HIGH_MAX_WAIT ORCHESTRATE_GH_BUDGET
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api rate_limit") cat "$FX/rate.json" ;;
  *) echo "ok $*" ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  B="$ORCHESTRATE_STATE_DIR/gh-budget"
}

rate() { # CORE GRAPHQL SEARCH [RESET_IN]: remaining per resource (limits 5000/5000/30)
  jq -n --argjson c "$1" --argjson g "$2" --argjson s "$3" --argjson r $((ORCHESTRATE_NOW + ${4:-1000})) \
    '{resources: {core: {limit: 5000, remaining: $c, reset: $r}, graphql: {limit: 5000, remaining: $g, reset: $r},
      search: {limit: 30, remaining: $s, reset: $r}}}' >"$FX/rate.json"
}
budget() { "$SCRIPTS/gh-budget.sh" "$@"; }
count() { grep -c -- "$1" "$FX/calls" 2>/dev/null || true; }

@test "a next slot past the wait bound is out of budget (exit 75) for normal and low, not high" {
  local p fails=""
  for p in normal:1002 low:2502; do
    rm -rf "$ORCHESTRATE_STATE_DIR" "$FX/calls"
    rate "${p#*:}" 5000 30     # two spare: the second call has one spare over 1000 s, its slot 1000 s out
    run budget run "${p%%:*}" -- api repos/o/r
    [ "$status" -eq 0 ] || fails="$fails
[$p first] $status $output"
    run budget run "${p%%:*}" -- api repos/o/r
    [ "$status" -eq 75 ] && [ "$output" = "gh-budget: out-of-budget priority=${p%%:*} resource=core remaining=$((${p#*:} - 1)) floor=$((${p#*:} - 2)) retry-at=2026-09-27T12:16:40Z" ] ||
      fails="$fails
[$p second] $status $output"
    [ "$(count '^api repos/o/r')" -eq 1 ] || fails="$fails
[$p] gh ran $(count '^api repos/o/r') times"
    [ ! -d "$B/lock" ] || fails="$fails
[$p] lock left behind"
  done
  [ -z "$fails" ] || { echo "$fails"; return 1; }
  # A wider bound lets the same call wait for its slot.
  GH_BUDGET_MAX_WAIT=2000 run budget run low -- api repos/o/r
  [ "$status" -eq 0 ]; [[ "$output" == *"gh-budget: wait 1000"* ]]
}

@test "search commands are paced against the search resource" {
  rate 5000 5000 5      # search floor for normal: 1000 * 30 / 5000 = 6
  run budget run normal -- search prs --author x
  [ "$status" -eq 75 ]
  [[ "$output" == "gh-budget: out-of-budget priority=normal resource=search remaining=5 floor=6 "* ]]
  [ "$(count '^search')" -eq 0 ]
  run budget run normal -- api repos/o/r
  [ "$status" -eq 0 ]
  rate 5000 5000 30
  rm -f "$B/rate_limit.json"
  run budget run normal -- search issues repo:o/r
  [ "$status" -eq 0 ]; [ "$output" = "ok search issues repo:o/r" ]
  [ "$(jq .resources.search.remaining "$B/rate_limit.json")" -eq 29 ]
  [ "$(jq .resources.core.remaining "$B/rate_limit.json")" -eq 5000 ]
}

@test "flag-heavy api calls: value flags are skipped to find the path; flags alone are 'api' on core" {
  rate 5000 5000 30
  local args want fails=""
  mkdir -p "$B"
  while IFS='|' read -r want args; do
    [ -n "$args" ] || continue
    rm -f "$B"/endpoint-*
    # A backoff recorded under the expected endpoint name must be found for this call.
    printf '%s\n%s\n' $((ORCHESTRATE_NOW + 500)) "$want" >"$B/endpoint-$(printf '%s' "$want" | tr -c 'A-Za-z0-9._-' '_')"
    # shellcheck disable=SC2086
    set -f; run budget run normal -- $args; set +f
    [ "$status" -eq 75 ] && [[ "$output" == "gh-budget: endpoint-backoff endpoint=$want priority=normal "* ]] ||
      fails="$fails
[$args] want endpoint $want: $status $output"
  done <<'CASES'
repos/o/r/pulls/N|api -H Accept:application/json --method GET /repos/o/r/pulls/12?per_page=1
repos/o/r/issues/N/comments|api -X GET -q .[] --jq .id -t x --template y repos/o/r/issues/7/comments
repos/o/r/commits|api --header A:b -f a=1 -F b=2 --field c=3 --raw-field d=4 --input f repos/o/r/commits
repos/o/r/actions/runs|api --hostname github.com --cache 1h -p v3 --preview x --paginate repos/o/r/actions/runs
api|api --method GET --paginate
CASES
  [ -z "$fails" ] || { echo "$fails"; return 1; }
  [ ! -f "$FX/calls" ] || ! grep -q '^api -' "$FX/calls"   # gh never ran
  # Flags with no path: endpoint "api", paced on core.
  rm -f "$B"/endpoint-*
  run budget run normal -- api --method GET --paginate
  [ "$status" -eq 0 ]
  [ "$(jq .resources.core.remaining "$B/rate_limit.json")" -eq 4999 ]
}

@test "an endpoint backoff inside the wait bound is waited out, then the call runs" {
  rate 5000 5000 30
  mkdir -p "$B"
  printf '%s\n%s\n' $((ORCHESTRATE_NOW + 30)) "repos/o/r/pulls" >"$B/endpoint-repos_o_r_pulls"
  run budget run normal -- api repos/o/r/pulls
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-budget: wait 30"* ]]
  [[ "$output" == *"ok api repos/o/r/pulls"* ]]
}

@test "a lock held by a live process past the retry window: the call proceeds unlocked" {
  rate 1100 5000 30
  mkdir -p "$B/lock"
  echo $$ >"$B/lock/pid"     # this test process: alive for the whole run
  # sleep is an exported no-op function (bash scripts inherit it, no fork), so the ~10 s
  # contention window passes at once; each retry is logged.
  sleep() { echo "$*" >>"$FX/sleeps"; }
  export -f sleep
  run budget run normal -- api repos/o/r
  [ "$status" -eq 0 ]; [ "$output" = "ok api repos/o/r" ]
  [ "$(wc -l <"$FX/sleeps" | tr -d ' ')" -eq 200 ]
  # The holder's lock is not taken over or removed.
  [ "$(cat "$B/lock/pid")" = "$$" ]
}

@test "a lock left by a dead process is reclaimed" {
  rate 5000 5000 30
  mkdir -p "$B/lock"
  sh -c 'echo $$' >"$B/lock/pid"   # that shell has exited
  run budget run normal -- api repos/o/r
  [ "$status" -eq 0 ]; [ "$output" = "ok api repos/o/r" ]
  [ ! -d "$B/lock" ]
}
