#!/usr/bin/env bats
# pr-claim.sh paths the other suites do not reach: an unknown subcommand, a heartbeat by the holder,
# and losing the race for a stale claim (another contender moved it first).
# Run: bats scripts/pr-claim-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1000
  CLAIM="$ORCHESTRATE_STATE_DIR/prs/o__r__7/claim"
}

pc() { run "$SCRIPTS/pr-claim.sh" "$1" --repo o/r --pr 7 "${@:2}"; }

@test "an unknown subcommand is a usage error (exit 2) and claims nothing" {
  pc grab --owner a
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: pr-claim.sh"* ]]
  [ ! -e "$CLAIM" ]
}

@test "heartbeat by the holder refreshes the claim's heartbeat" {
  pc claim --owner a
  [ "$status" -eq 0 ]
  export ORCHESTRATE_NOW=1500
  pc heartbeat --owner a
  [ "$status" -eq 0 ]
  [ "$output" = "heartbeat" ]
  [ "$(cat "$CLAIM/heartbeat")" = 1500 ]
  [ "$(cat "$CLAIM/owner")" = a ]
}

@test "a stale claim another contender moves first is reported held (exit 3), not taken" {
  pc claim --owner a
  export ORCHESTRATE_NOW=9000
  # The stale rename fails, as it does for the loser of a takeover race.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  real=$(command -v mv)
  printf '#!/usr/bin/env bash\ncase "$*" in *"/stale."*) exit 1 ;; esac\nexec %s "$@"\n' "$real" >"$BATS_TEST_TMPDIR/bin/mv"
  chmod +x "$BATS_TEST_TMPDIR/bin/mv"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" pc claim --owner b
  [ "$status" -eq 3 ]
  [ "$output" = "held by a (heartbeat 8000s ago)" ]
  [ "$(cat "$CLAIM/owner")" = a ]
}
