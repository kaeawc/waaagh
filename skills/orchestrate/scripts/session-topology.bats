#!/usr/bin/env bats
# Self-test for relay.sh (queued / delivered / acked / done relay ledger) and the session-topology
# doctrine contract. Run: bats scripts/session-topology.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SKILL="$(cd "$SCRIPTS/.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1794096000 # 2026-11-08
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # relay.sh never calls GitHub when --repo is given; any gh call fails the test.
  printf '#!/usr/bin/env bash\necho "unexpected gh call: $*" >&2; exit 9\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

R() { "$SCRIPTS/relay.sh" "$1" --repo o/r "${@:2}"; }
state_of() { awk -F'\t' -v id="$1" '$1 == id { print $3 }' "$STATE/relay.tsv"; }

@test "send records a queued message and prints the owner's words verbatim with the reply contract" {
  run R send --to triage --ref 76 --owner-quote $'start 76 in the cloud\nand keep main green' \
    --text "Dispatch #76 as a cloud routine."
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = r1 ]
  [[ "$output" == *"Owner (2026-11-08), verbatim:"* ]]
  [[ "$output" == *"> start 76 in the cloud"* ]]
  [[ "$output" == *"> and keep main green"* ]]
  [[ "$output" == *"Dispatch #76 as a cloud routine."* ]]
  [[ "$output" == *'"ACK r1"'* && "$output" == *'"DONE r1 <evidence'* ]]
  [ "$(state_of r1)" = queued ]
  [ "$(awk -F'\t' '{ print $2, $6 }' "$STATE/relay.tsv")" = "triage #76" ]
  diff <(sed 1d <<<"$output") "$STATE/relay/r1.txt"
  run R send --to manual-test --text "Round 4 on the new SHA."
  [ "${lines[0]}" = r2 ]
  [[ "$output" != *"verbatim"* ]]
}

@test "say never reports a queued or acknowledged message as done" {
  R send --to triage --text "Merge #12 when green." >/dev/null
  run R say --id r1
  [ "$output" = "r1 queued to triage 0m ago; no receipt yet, not started" ]
  R mark --id r1 --state delivered >/dev/null
  run R say --id r1
  [[ "$output" == *"delivered to triage"*"not acknowledged, not done"* ]]
  R mark --id r1 --state acked >/dev/null
  run R say --id r1
  [[ "$output" == *"acknowledged by triage"*"in progress, not done"* ]]
  [[ "$output" != *"done by"* ]]
  R mark --id r1 --state done --evidence https://github.com/o/r/pull/12 >/dev/null
  run R say --id r1
  [ "$output" = "r1 done by triage: https://github.com/o/r/pull/12" ]
}

@test "reply applies ACK and DONE lines from the right peer and records acknowledgement apart from completion" {
  R send --to triage --text "one" >/dev/null
  R send --to triage --text "two" >/dev/null
  run R reply --from triage --text $'On it.\nACK r1\nACK r2'
  [ "$status" -eq 0 ]
  [ "$output" = $'r1 acked\nr2 acked' ]
  [ "$(state_of r1)" = acked ]
  run R reply --from triage --text 'DONE r2: https://github.com/o/r/pull/5'
  [ "$status" -eq 0 ]
  [ "$(state_of r2)" = done ]
  [ "$(state_of r1)" = acked ]
  [ "$(awk -F'\t' '$1 == "r2" { print $8 }' "$STATE/relay.tsv")" = "https://github.com/o/r/pull/5" ]
  grep -q $'r1\tqueued>acked\ttriage' "$STATE/relay.log"
  grep -q $'r2\tacked>done\ttriage\thttps://github.com/o/r/pull/5' "$STATE/relay.log"
}

@test "reply refuses ids sent to another peer and unknown ids, and says when nothing was acknowledged" {
  R send --to triage --text "one" >/dev/null
  run R reply --from manual-test --text "ACK r1"
  [ "$status" -eq 3 ]
  [[ "$output" == *"r1 was sent to triage, not manual-test"* ]]
  [ "$(state_of r1)" = queued ]
  run R reply --from triage --text "ACK r9"
  [ "$status" -eq 3 ]
  run R reply --from triage --text "Busy with the merge loop, will look later."
  [ "$status" -eq 5 ]
  [ "$(state_of r1)" = queued ]
}

@test "done needs evidence and states only move forward" {
  R send --to triage --text "one" >/dev/null
  run R mark --id r1 --state done
  [ "$status" -eq 3 ]
  [[ "$output" == *"done needs --evidence"* ]]
  [ "$(state_of r1)" = queued ]
  R mark --id r1 --state acked >/dev/null
  run R mark --id r1 --state delivered
  [ "$status" -eq 3 ]
  [ "$(state_of r1)" = acked ]
  run R mark --id r1 --state acked
  [ "$status" -eq 0 ]
  [ "$output" = "r1 acked" ]
  R mark --id r1 --state failed --note "peer session ended" >/dev/null
  run R mark --id r1 --state done --evidence x
  [ "$status" -eq 3 ]
  run R mark --id r7 --state acked
  [ "$status" -eq 3 ]
  run R mark --id r1 --state finished
  [ "$status" -eq 2 ]
}

@test "check flags messages past their ack or done window with exit 4; status lists open ones" {
  R send --to triage --text "old unacked" >/dev/null
  R send --to manual-test --text "acked long ago" >/dev/null
  R mark --id r2 --state acked >/dev/null
  run R check
  [ "$status" -eq 0 ]
  [ "$output" = "no overdue messages" ]
  ORCHESTRATE_NOW=$((1794096000 + 31 * 60)) run R check
  [ "$status" -eq 4 ]
  [ "$output" = $'overdue-ack\tr1\ttriage\tqueued\t31m\told unacked' ]
  ORCHESTRATE_NOW=$((1794096000 + 241 * 60)) run R check --ack-within 600
  [ "$status" -eq 4 ]
  [ "$output" = $'overdue-done\tr2\tmanual-test\tacked\t241m\tacked long ago' ]
  R mark --id r1 --state done --evidence "issue comment" >/dev/null
  run R status --open
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == r2$'\t'manual-test$'\t'acked* ]]
  run R status --to triage
  [[ "${lines[0]}" == r1$'\t'triage$'\t'done* ]]
}

@test "relay.sh usage: -h prints exactly the header, bad input is exit 2" {
  run "$SCRIPTS/relay.sh" -h
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "# Relay ledger:"* ]]
  [[ "${lines[${#lines[@]}-1]}" == "#       ACK/DONE line for an open message of that peer" ]]
  run R send --text "no peer"
  [ "$status" -eq 2 ]
  run R send --to "bad peer" --text x
  [ "$status" -eq 2 ]
  run R bogus
  [ "$status" -eq 2 ]
  [ ! -s "$STATE/relay.tsv" ]
}

@test "session-topology doctrine names the roles, message states, fallbacks and is linked from SKILL.md" {
  doc="$SKILL/session-topology.md"
  for role in Orchestrator Triage "Manual test" "Cloud routines" "Local lanes"; do
    grep -q "\*\*$role\*\*" "$doc" || { echo "missing role $role"; false; }
  done
  for st in queued delivered acked done failed; do grep -q "^| \`$st\` |" "$doc" || { echo "missing state $st"; false; }; done
  grep -q "^## Remote Control fallback" "$doc"
  grep -q "^## Follow-up after a cloud session goes idle" "$doc"
  grep -q "^## Peer etiquette" "$doc"
  grep -qi "closing an issue is the owner's call" "$doc"
  grep -q "verbatim" "$doc"
  grep -q "30 minutes" "$doc"
  grep -q "relay.sh" "$doc"
  grep -q "session-topology.md" "$SKILL/SKILL.md"
  grep -q 'relay.sh' "$SKILL/SKILL.md"
  grep -q '^| `relay.sh` |' "$SKILL/../../README.md"
}
