#!/usr/bin/env bats
# BEHIND under strict branch protection (#251): pr-ready.sh reads mergeStateStatus (GraphQL) or
# mergeable_state (REST, lowercase) and the strict "require up to date" setting (rulesets, then
# classic protection, whose read may 404 without admin: unknown is not strict), and reports a green
# PR behind its base as BEHIND; merge-queue.sh then merges the base into the front on its next pass
# even when the drift touches no protected path. Stubbed gh, real git for the queue.
# Run: bats scripts/pr-ready-behind.bats

setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  load selftest_helper
  load rest_stub
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  stub_gh_router
  rest_wrap
  # Classic protection's required_status_checks: stub_gh_router's own route (#233), from
  # $FX/protection.json when it exists, else the 404 a token without admin rights gets.
}
protection_calls() { grep '/protection' "$FX/calls" || true; }

STRICT_RULES='[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"build"}]}}]'
PENDING='[{"name":"build","status":"IN_PROGRESS","conclusion":""}]'
row() { # number mergeable mergeStateStatus [checks]
  pr_row "$1" me false false "$2" "${4:-$OKC}" | jq -c --arg s "$3" '. + {mergeStateStatus: $s}'
}
ready() { "$SCRIPTS/pr-ready.sh" --repo o/r --author me "$@"; }
verdict() { printf '%s\n' "$output" | awk -F'\t' -v n="$1" '$1 == n { print $2 "\t" $6 }'; }

@test "a green PR behind its base under a strict ruleset is BEHIND; without strict it stays READY" {
  { row 1 MERGEABLE BEHIND; row 2 MERGEABLE CLEAN; } | jq -s . >"$FX/prs.json"
  echo "$STRICT_RULES" >"$FX/rules.json"
  run ready
  [ "$status" -eq 0 ]
  [ "$(verdict 1)" = $'BEHIND\tbehind' ]
  [ "$(verdict 2)" = $'READY\t-' ]
  [[ "$output" == *"open=2 ready=1 behind=1"* ]]
  [[ "$(grep -c 'pr list.*mergeStateStatus' "$FX/calls" || true)" -eq 1 ]]
  echo '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"build"}]}}]' >"$FX/rules.json"
  run ready
  [ "$(verdict 1)" = $'READY\t-' ]
  [[ "$output" == *"open=2 ready=2"* ]]
  [[ "$output" != *"behind="* ]]
}

@test "pending or blocked rows behind under strict protection carry the behind token" {
  { row 1 MERGEABLE BEHIND "$PENDING"; row 2 CONFLICTING BEHIND; row 3 MERGEABLE BLOCKED "$PENDING"; } | jq -s . >"$FX/prs.json"
  echo "$STRICT_RULES" >"$FX/rules.json"
  run ready
  [ "$status" -eq 0 ]
  [ "$(verdict 1)" = $'WAIT\tpending:build behind' ]
  [ "$(verdict 2)" = $'BLOCK\tconflict behind' ]
  [ "$(verdict 3)" = $'WAIT\tpending:build' ]
  [[ "$output" == *"open=3 ready=0"* ]]
}

@test "a BEHIND row is still judged for review threads and policy" {
  row 4 MERGEABLE BEHIND | jq -s . >"$FX/prs.json"
  echo "$STRICT_RULES" >"$FX/rules.json"
  echo '{"4":[{"isResolved":false,"isOutdated":false}]}' >"$FX/threads.json"
  run ready
  [ "$(verdict 4)" = $'BLOCK\tbehind threads=1' ]
  [[ "$output" != *"behind="* ]]
}

@test "classic protection: strict comes from protection/required_status_checks; a 404 counts as not strict" {
  row 1 MERGEABLE BEHIND | jq -s . >"$FX/prs.json"
  echo '[]' >"$FX/rules.json"
  echo '{"protected":true,"protection":{"required_status_checks":{"contexts":["build"]}}}' >"$FX/branch.json"
  echo '{"strict":true,"contexts":["build"]}' >"$FX/protection.json"
  run ready
  [ "$(verdict 1)" = $'BEHIND\tbehind' ]
  [ "$(protection_calls)" = "api repos/o/r/branches/main/protection/required_status_checks" ]
  rm "$FX/protection.json"
  run ready
  [ "$status" -eq 0 ]
  [ "$(verdict 1)" = $'READY\t-' ]
  [[ "$output" != *"policy=unknown"* ]]
  [[ "$output" != *"diagnostics="* ]]
  # An unprotected branch, or a strict ruleset, needs no classic read.
  : >"$FX/calls"
  echo '{"protected":false}' >"$FX/branch.json"
  run ready
  [ -z "$(protection_calls)" ]
  echo "$STRICT_RULES" >"$FX/rules.json"
  echo '{"protected":true}' >"$FX/branch.json"
  run ready
  [ "$(verdict 1)" = $'BEHIND\tbehind' ]
  [ -z "$(protection_calls)" ]
}

@test "rest: mergeable_state behind gives the BEHIND row GraphQL gives" {
  { row 1 MERGEABLE BEHIND; row 2 MERGEABLE CLEAN; row 3 MERGEABLE BEHIND "$PENDING"; } | jq -s . >"$FX/prs.json"
  echo "$STRICT_RULES" >"$FX/rules.json"
  touch "$FX/rest-mode"
  run ready --no-threads
  [ "$status" -eq 0 ]
  [ "$(verdict 1)" = $'BEHIND\tbehind' ]
  [ "$(verdict 2)" = $'READY\t-' ]
  [ "$(verdict 3)" = $'WAIT\tpending:build behind' ]
  [[ "$output" == *"open=3 ready=1 behind=1"*"api=rest"* ]]
  run "$SCRIPTS/gh-rest-pr.sh" view --repo o/r --pr 1
  [ "$(jq -r .mergeStateStatus <<<"$output")" = BEHIND ]
  run "$SCRIPTS/gh-rest-pr.sh" list --repo o/r
  [ "$(jq -r '.[0].mergeStateStatus' <<<"$output")" = UNKNOWN ]
}

# --- merge-queue.sh: the real queue beside pr-ready.sh and pr-merge.sh stubs ------------------

queue_setup() {
  export ORCHESTRATE_AUTHOR=me ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_MERGE_MANIFESTS ORCHESTRATE_DIRECT_MERGE MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_UPDATE_BEHIND
  seed_origin_copy
  STATE="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$STATE"
  QB="$BATS_TEST_TMPDIR/qbin"; mkdir -p "$QB"
  cat >"$QB/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/qcalls"
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  "pr list"*"--state open"*) jq -n --arg h "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/q)" '[{number: 5, headRefOid: $h}]' ;;
  "pr view"*) echo '{"state":"OPEN"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$QB/gh"
  export PATH="$QB:$PATH"
  # Stubs for pr-merge.sh, main-health.sh and pr-ready.sh; every other script is the real one (#233).
  S="$BATS_TEST_TMPDIR/s"; mkdir -p "$S"
  export ORCHESTRATE_SCRIPTS_DIR="$S"
  printf '#!/usr/bin/env bash\necho "$*" >>"$FX/pm-calls"\nexit "$(cat "$FX/pm-rc")"\n' >"$S/pr-merge.sh"
  printf '#!/usr/bin/env bash\necho green\n' >"$S/main-health.sh"
  # pr-ready.sh stub: one row for PR 5 at the pushed head, verdict and detail from $FX/verdict.
  cat >"$S/pr-ready.sh" <<'STUB'
#!/usr/bin/env bash
h=$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/q)
IFS='|' read -r v d <"$FX/verdict"
printf '5\t%s\t%s\tMERGEABLE\t1\t%s\n' "$v" "${h:0:9}" "$d"
STUB
  chmod +x "$S/pr-merge.sh" "$S/main-health.sh" "$S/pr-ready.sh"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/q" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/q" switch -q -c q
  echo q >"$BATS_TEST_TMPDIR/q/q.txt"
  git -C "$BATS_TEST_TMPDIR/q" add -A
  git -C "$BATS_TEST_TMPDIR/q" commit -qm q
  echo body >"$BATS_TEST_TMPDIR/body.md"
  "$SCRIPTS/merge-queue.sh" add --repo o/r --id q --worktree "$BATS_TEST_TMPDIR/q" --branch q --title t \
    --body-file "$BATS_TEST_TMPDIR/body.md"
  echo 'WAIT|pending:build' >"$FX/verdict"
  echo 0 >"$FX/pm-rc"
  run "$SCRIPTS/merge-queue.sh" run-once --repo o/r
  [[ "$output" == *"q: waiting"* ]]
  pushed=$(pushed_now)
}
pushed_now() { git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/q; }
main_moves() { # FILE: a new commit on origin/main that edits FILE
  echo "$RANDOM" >>"$BATS_TEST_TMPDIR/seed/$1"
  git -C "$BATS_TEST_TMPDIR/seed" add -A
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm "main $1"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
}

@test "merge-queue: a BEHIND front gets the base merged in on the next pass, even over unprotected drift" {
  queue_setup
  main_moves docs.md
  echo 'BEHIND|behind' >"$FX/verdict"
  run "$SCRIPTS/merge-queue.sh" run-once --repo o/r
  [[ "$output" == *"q: waiting"*"main requires up-to-date branches, next pass merges it in"* ]]
  [ "$(pushed_now)" = "$pushed" ]   # resumed over unrelated drift, nothing pushed this pass
  [ -f "$STATE/merge-queue/q.refresh" ]
  [ ! -f "$FX/pm-calls" ]
  echo 'READY|-' >"$FX/verdict"
  run "$SCRIPTS/merge-queue.sh" run-once --repo o/r
  [[ "$output" == *"q: merged"* ]]
  [ "$(pushed_now)" != "$pushed" ]
  git -C "$BATS_TEST_TMPDIR/origin.git" merge-base --is-ancestor refs/heads/main refs/heads/q
  [ ! -f "$STATE/merge-queue/q.refresh" ]
}

@test "merge-queue: a pending row behind waits with a refresh; a real blocker behind stays blocked" {
  queue_setup
  echo 'WAIT|pending:build behind' >"$FX/verdict"
  run "$SCRIPTS/merge-queue.sh" run-once --repo o/r
  [[ "$output" == *"q: waiting"*"pending:build behind; main requires up-to-date branches"* ]]
  [ -f "$STATE/merge-queue/q.refresh" ]
  rm "$STATE/merge-queue/q.refresh"
  echo 'BLOCK|pending:build behind' >"$FX/verdict"
  run "$SCRIPTS/merge-queue.sh" run-once --repo o/r
  [ -f "$STATE/merge-queue/q.refresh" ]
  rm "$STATE/merge-queue/q.refresh"
  echo 'BLOCK|conflict behind' >"$FX/verdict"
  run "$SCRIPTS/merge-queue.sh" run-once --repo o/r
  [[ "$output" == *"q: blocked"*"conflict behind"* ]]
  [ ! -f "$STATE/merge-queue/q.refresh" ]
  [ ! -f "$FX/pm-calls" ]
}
