#!/usr/bin/env bats
# lane-claim.sh paths the other suites do not reach: an unknown subcommand, and a leftover lanes.tsv
# lock (older than 5 minutes) that a writer breaks. A live lock is held 30 s before exit 4; that
# wait is not tested here. Run: bats scripts/lane-claim-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$STATE" "$BATS_TEST_TMPDIR/bin"
  # No subcommand tested here reads GitHub.
  printf '#!/usr/bin/env bash\necho "gh $*" >>"%s/gh-calls"; exit 9\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "an unknown subcommand is a usage error (exit 2), and nothing is read or written" {
  run "$SCRIPTS/lane-claim.sh" claim --issues 1 --repo o/r
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: lane-claim.sh check"* ]]
  [ ! -e "$STATE/lanes.tsv" ]
  [ ! -e "$BATS_TEST_TMPDIR/gh-calls" ]
}

@test "a lock left over for more than 5 minutes is broken and the write goes through" {
  printf 'wt-a\twork/1-a\t1\ta.ts\t-\tactive\n' >"$STATE/lanes.tsv"
  mkdir "$STATE/.lanes.lock"
  touch -t 202001010000 "$STATE/.lanes.lock"
  run "$SCRIPTS/lane-claim.sh" set --worktree wt-a --status done --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "lane wt-a: done" ]
  [ "$(cut -f6 "$STATE/lanes.tsv")" = done ]
  [ ! -e "$STATE/.lanes.lock" ]
}
