#!/usr/bin/env bats
# Sibling scripts through one overridable directory (#233): _lib.sh's orch_run NAME runs
# $ORCHESTRATE_SCRIPTS_DIR/NAME when the test put an executable stub there, else the real NAME, so
# a test stubs one sibling (a failing hold.sh, a pr-merge.sh with a fixed exit code) while every
# other script runs from the real tree and bashcov credits it. The arms only such a stub reaches:
# an unreadable hold file in pr-merge.sh (before and after its gates) and merge-queue.sh, an
# unreadable review ledger in merge-queue.sh, and pr-merge.sh exit 14 with nothing left to show.
# Also the shared gh stubs' classic branch protection route (selftest_helper.bash).
# Real git against a local bare origin, stubbed gh. Run: bats scripts/scripts-dir.bats

setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  load selftest_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE MERGE_QUEUE_ADMIN_CHECKS ORCHESTRATE_DIRECT_MERGE \
    ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_GENERATED_FILES ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE
  seed_origin_copy
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  Q="$ST/merge-queue"
  STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
  stub_gh_merge_path
  export SCRIPTS STUBS
  echo body >"$BATS_TEST_TMPDIR/body.md"
}

# stub NAME BODY: an executable $STUBS/NAME running BODY (a bash script after the shebang).
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"; chmod +x "$STUBS/$1"; }
# A hold.sh whose list fails (as on an unreadable hold file) from its Nth list call on ($FX/hold-ok:
# the calls that still go to the real hold.sh; default none).
failing_hold() {
  stub hold.sh 'n=$(cat "$FX/hold-n" 2>/dev/null || echo 0); echo $((n + 1)) >"$FX/hold-n"
if [ "$1" = list ] && [ "$n" -ge "$(cat "$FX/hold-ok" 2>/dev/null || echo 0)" ]; then echo "error: could not read holds" >&2; exit 5; fi
exec "$SCRIPTS/hold.sh" "$@"'
}
wt() {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/$1" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/$1" switch -q -c "$1"
  echo "$1" >"$BATS_TEST_TMPDIR/$1/$1.txt"
  git -C "$BATS_TEST_TMPDIR/$1" add -A
  git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$1"
}
mq() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }
enqueue() { mq add --id "$1" --worktree "$BATS_TEST_TMPDIR/$1" --branch "$1" --title "t $1" --body-file "$BATS_TEST_TMPDIR/body.md" >/dev/null; }
outcome() { sed -n 1p "$Q/$1.outcome"; }
reason() { sed -n 2p "$Q/$1.outcome"; }
calls() { grep -c "^$1" "$FX/calls" 2>/dev/null || true; }
pushed_pr() {
  wt a
  git -C "$BATS_TEST_TMPDIR/a" push -q origin a
  echo a >"$FX/branch"
  HEAD=$(git -C "$BATS_TEST_TMPDIR/a" rev-parse HEAD)
}
pm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 5 --head "$HEAD" "$@"; }
lib() { run bash -c 'source "$1/_lib.sh"; shift; "$@"' _ "$SCRIPTS" "$@"; }

@test "orch_run: a stub in ORCHESTRATE_SCRIPTS_DIR wins for its name only; unset, or not executable, is the real script" {
  stub hold.sh 'echo "stub hold $*"; exit 7'
  ORCHESTRATE_SCRIPTS_DIR="$STUBS" lib orch_run hold.sh list --repo o/r
  [ "$status" -eq 7 ]
  [ "$output" = "stub hold list --repo o/r" ]
  # Another name in the same run is the real one.
  ORCHESTRATE_SCRIPTS_DIR="$STUBS" lib orch_run review-ledger.sh latest --repo o/r --pr 5
  [ "$status" -eq 3 ]
  # Unset: the real hold.sh (an empty hold file lists nothing).
  lib orch_run hold.sh list --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # A stub that is not executable is not used.
  chmod -x "$STUBS/hold.sh"
  ORCHESTRATE_SCRIPTS_DIR="$STUBS" lib orch_run hold.sh list --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # The helpers go through it: orch_hold_of reports a failing hold.sh as unreadable (2).
  failing_hold
  ORCHESTRATE_SCRIPTS_DIR="$STUBS" lib orch_hold_of o/r 5
  [ "$status" -eq 2 ]
}

@test "pr-merge.sh: an unreadable hold file is exit 9 before any GitHub read, in every mode" {
  pushed_pr
  failing_hold
  export ORCHESTRATE_SCRIPTS_DIR="$STUBS"
  : >"$FX/calls"
  pm
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: the hold file could not be read (hold.sh list); nothing was attempted" ]
  grep -q $'\trefused: hold file unreadable' "$ST/merges.log"
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 9 ]
  [ ! -s "$FX/calls" ]
  [ ! -f "$ST/ops/merge-pr5.json" ]
  # The real hold.sh again: it merges.
  unset ORCHESTRATE_SCRIPTS_DIR
  pm
  [ "$status" -eq 0 ]
  [ "$output" = "merged 5 feedface" ]
}

@test "pr-merge.sh: a hold file that turns unreadable while the gates ran is exit 9 and frees its locks" {
  pushed_pr
  export ORCHESTRATE_MERGE_SENSITIVE='*.txt' ORCHESTRATE_SCRIPTS_DIR="$STUBS"
  failing_hold
  echo 1 >"$FX/hold-ok"   # the first check reads the real file; the re-check after the gates fails
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: the hold file could not be read (hold.sh list); nothing was attempted" ]
  [ "$(cat "$FX/hold-n")" -eq 2 ]
  [ "$(calls 'pr merge')" -eq 0 ]
  [ "$(calls 'pr view')" -ge 1 ]
  [ -z "$(ls -A "$ST/locks")" ]
}

@test "merge-queue: an unreadable hold file, or review ledger, leaves the item waiting and merges nothing" {
  wt a
  enqueue a
  failing_hold
  ORCHESTRATE_SCRIPTS_DIR="$STUBS" run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [ "$(reason a)" = "hold file or review ledger unreadable; will re-check" ]
  [ "$(calls 'pr merge')" -eq 0 ]
  # The real hold file, but a review ledger that cannot be read: still waiting.
  mkdir "$ST/reviews.tsv"
  run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = waiting ]
  [ "$(reason a)" = "hold file or review ledger unreadable; will re-check" ]
  [ "$(calls 'pr merge')" -eq 0 ]
  rmdir "$ST/reviews.tsv"
  run mq run-once
  [ "$(outcome a)" = merged ]
}

@test "merge-queue: pr-merge.sh exit 14 with no hold left to show is held, pointing at the log" {
  wt a
  enqueue a
  stub pr-merge.sh 'exit 14'
  ORCHESTRATE_SCRIPTS_DIR="$STUBS" run mq run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = held ]
  [ "$(reason a)" = "pr-merge refused PR 5 as held, see $Q/logs/a.log" ]
}

@test "gh stubs: classic branch protection has its own route, apart from the branch" {
  run gh api repos/o/r/branches/main/protection/required_status_checks
  [ "$status" -eq 1 ]
  [[ "$output" == *"(HTTP 404)"* ]]
  run gh api repos/o/r/branches/main
  [ "$output" = '{"protected":false}' ]
  echo '{"strict":true}' >"$FX/protection.json"
  run gh api repos/o/r/branches/main/protection/required_status_checks --include
  [ "$output" = '{"strict":true}' ]
  # stub_gh_router: the same route, while branch.json answers the branch.
  stub_gh_router
  rm "$FX/protection.json"
  run gh api repos/o/r/branches/main/protection/required_status_checks
  [ "$status" -eq 1 ]
  echo '{"strict":false}' >"$FX/protection.json"
  run gh api repos/o/r/branches/main/protection/required_status_checks
  [ "$output" = '{"strict":false}' ]
  run gh api repos/o/r/branches/main
  [ "$output" = '{"protected":false}' ]
}
