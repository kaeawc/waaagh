#!/usr/bin/env bats
# Reporting to the owner (#60): cumulative counters in the campaign ledger (counters.sh) and the
# doctrine contract for the tick report and the owner-blocker format (reporting.md). Run:
# bats reporting.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  ST="$ORCHESTRATE_STATE_DIR/o__r"
}

has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "bump counts today and for the campaign, in the ledger campaign.sh created" {
  run "$SCRIPTS/counters.sh" bump closed --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'closed_today=1\nclosed_total=1')" ]
  run "$SCRIPTS/counters.sh" bump closed --by 2 --repo o/r
  [ "$output" = "$(printf 'closed_today=3\nclosed_total=3')" ]
  [ "$(jq -r .started_at "$ST/campaign.json")" = 2026-09-27T12:00:00Z ]
  [ "$(jq -r .counters.total.closed "$ST/campaign.json")" = 3 ]
}

@test "bump keeps the rest of the ledger" {
  "$SCRIPTS/campaign.sh" close-policy verified --repo o/r >/dev/null
  "$SCRIPTS/counters.sh" bump merged --repo o/r >/dev/null
  [ "$("$SCRIPTS/campaign.sh" close-policy --repo o/r)" = verified ]
  [ "$(jq -r .counters.today.merged "$ST/campaign.json")" = 1 ]
}

@test "show lists every counter by name, and a never-bumped NAME as zero" {
  "$SCRIPTS/counters.sh" bump dispatched --by 4 --repo o/r >/dev/null
  "$SCRIPTS/counters.sh" bump closed --repo o/r >/dev/null
  run "$SCRIPTS/counters.sh" show --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'day=2026-09-27\nclosed_today=1\nclosed_total=1\ndispatched_today=4\ndispatched_total=4')" ]
  run "$SCRIPTS/counters.sh" show owner_blockers --repo o/r
  [ "$output" = "$(printf 'day=2026-09-27\nowner_blockers_today=0\nowner_blockers_total=0')" ]
  run "$SCRIPTS/counters.sh" show --repo x/y
  [ "$output" = "day=2026-09-27" ]
}

@test "today restarts on a new UTC day; totals carry on" {
  "$SCRIPTS/counters.sh" bump closed --by 5 --repo o/r >/dev/null
  export ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 86400))
  run "$SCRIPTS/counters.sh" show closed --repo o/r
  [ "$output" = "$(printf 'day=2026-09-28\nclosed_today=0\nclosed_total=5')" ]
  run "$SCRIPTS/counters.sh" bump closed --repo o/r
  [ "$output" = "$(printf 'closed_today=1\nclosed_total=6')" ]
}

@test "bad names, counts and commands are usage errors that leave the ledger alone" {
  run "$SCRIPTS/counters.sh" bump --repo o/r
  [ "$status" -eq 2 ]
  run "$SCRIPTS/counters.sh" bump Closed --repo o/r
  [ "$status" -eq 2 ]
  run "$SCRIPTS/counters.sh" bump closed --by -1 --repo o/r
  [ "$status" -eq 2 ]
  run "$SCRIPTS/counters.sh" reset closed --repo o/r
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: counters.sh bump NAME"* ]]
  [ ! -f "$ST/campaign.json" ]
}

@test "reporting doctrine: fixed tick order, owner-blocker format, counters from the ledger (#60)" {
  R="$ROOT/skills/orchestrate/reporting.md"
  has "$R" "main health, merges, dispatches, closes, owner blockers"
  has "$R" "**Action** — **where** — **exact names**"
  has "$R" "the moment it appears"
  has "$R" "\"\$SCRIPTS/counters.sh\" show"
  has "$R" "recommendation first"
  has "$ROOT/skills/orchestrate/SKILL.md" "reporting.md"
  has "$ROOT/README.md" "\`counters.sh\`"
}
