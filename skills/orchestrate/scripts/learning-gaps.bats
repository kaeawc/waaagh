#!/usr/bin/env bats
# learning.sh paths learnings.bats does not reach: `index` rebuilds INDEX.md and the ledger entry
# from the entry files after they changed by hand. Run: bats scripts/learning-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1794096000 # 2026-11-08
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
}

L() { run "$SCRIPTS/learning.sh" "$1" --repo o/r "${@:2}"; }

@test "index rebuilds INDEX.md and the ledger count from the files on disk" {
  for t in "Alpha rule holds" "Beta rule holds"; do
    L add --title "$t" --rule R --why W --how H --source S --trigger procedural --scope repo --roles all
    [ "$status" -eq 0 ]
  done
  [ "$(jq -r .learnings.active "$STATE/campaign.json")" = 2 ]
  rm "$STATE/learnings/2026-11-08-beta-rule-holds.md"
  L index
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE/learnings/INDEX.md" ]
  grep -q '^1 active\.' "$STATE/learnings/INDEX.md"
  grep -q 'alpha-rule-holds' "$STATE/learnings/INDEX.md"
  [ "$(grep -c 'beta-rule-holds' "$STATE/learnings/INDEX.md" || true)" -eq 0 ]
  [ "$(jq -r .learnings.active "$STATE/campaign.json")" = 1 ]
}
