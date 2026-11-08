#!/usr/bin/env bats
# Self-test for learning.sh (the per-campaign learnings store) and the learnings doctrine contract.
# Run: bats scripts/learnings.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SKILL="$(cd "$SCRIPTS/.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1794096000 # 2026-11-08
  unset ORCHESTRATE_UPSTREAM_REPO ORCHESTRATE_LEARNINGS_CONSOLIDATE_EVERY
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1 $2 $3 $4" >>"$FX/calls"
case "$1 $2" in
  "issue create") [ ! -f "$FX/create-fail" ] || exit 1; echo "https://github.com/kaeawc/waaagh/issues/321" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

L() { "$SCRIPTS/learning.sh" "$1" --repo o/r "${@:2}"; }
add() { # add TITLE SCOPE ROLES [extra...]
  L add --title "$1" --rule "Rule for $1." --why "Because of $1." --how "Do $1." \
    --source "session event" --trigger procedural --scope "$2" --roles "$3" "${@:4}"
}
FREEZE=2026-11-08-merge-freeze-messages-can-expire-undelivered

@test "add writes one file with rule, why, how, date and source, and indexes it from the ledger" {
  run add "Merge freeze messages can expire undelivered" global merge-bot,orchestrator
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE/learnings/$FREEZE.md" ]
  f="$STATE/learnings/$FREEZE.md"
  grep -qx "id: $FREEZE" "$f"
  grep -qx "date: 2026-11-08" "$f"
  grep -qx "source: session event" "$f"
  grep -qx "trigger: procedural" "$f"
  grep -q '^\*\*Rule:\*\* Rule for' "$f"
  grep -q '^\*\*Why:\*\* ' "$f"
  grep -q '^\*\*How to apply:\*\* ' "$f"
  grep -q "\`$FREEZE\` \[merge-bot,orchestrator\] global" "$STATE/learnings/INDEX.md"
  [ "$(jq -r .learnings.index "$STATE/campaign.json")" = "$STATE/learnings/INDEX.md" ]
  [ "$(jq -r .learnings.active "$STATE/campaign.json")" = 1 ]
  # The ledger keeps campaign.sh's first shape, so its verification count still starts.
  [ "$(jq -r .started_at "$STATE/campaign.json")" = "2026-11-08T00:00:00Z" ]
  [ "$(jq -r .last_verification_sha "$STATE/campaign.json")" = null ]
}

@test "add refuses a missing field, a bad trigger or scope, and an existing id" {
  run L add --title T --rule R --why W --how H --trigger owner --scope repo --roles all
  [ "$status" -eq 2 ]
  run L add --title T --rule R --why W --how H --source S --trigger hunch --scope repo --roles all
  [ "$status" -eq 2 ]
  run L add --title T --rule R --why W --how H --source S --trigger owner --scope team --roles all
  [ "$status" -eq 2 ]
  run L add --title T --rule R --why W --how H --source S --trigger owner --scope repo --roles "Merge Bot"
  [ "$status" -eq 2 ]
  add "Close policy" repo all
  run add "close policy!" repo all
  [ "$status" -eq 3 ]
  [[ "$output" == "refused: learning 2026-11-08-close-policy exists"* ]]
}

@test "brief loads the index plus only the entries tagged with the role or all" {
  add "Merge freeze messages can expire undelivered" global merge-bot
  add "Close policy" repo all
  add "Review threads need replies" repo review
  run L brief --role merge-bot
  [ "$status" -eq 0 ]
  [[ "$output" == "# Learnings — o/r"* ]]
  [[ "$output" == *"3 active."* ]]
  [[ "$output" == *"## Merge freeze messages can expire undelivered"* ]]
  [[ "$output" == *"## Close policy"* ]]
  [[ "$output" == *"**How to apply:** Do Close policy."* ]]
  [[ "$output" != *"## Review threads need replies"* ]]
  [[ "$output" != *"Rule for Review threads"* ]]
  [[ "$output" != *"## History"* ]]
  [[ "$output" != *"trigger:"* ]]
  run L list --role review
  [ "$(printf '%s\n' "$output" | awk -F'\t' '{ print $1 }')" = "$(printf '2026-11-08-close-policy\n2026-11-08-review-threads-need-replies')" ]
}

@test "consolidate finds duplicates; supersede folds one into the other and keeps a history line" {
  add "Merge freeze messages can expire undelivered" global merge-bot
  add "merge freeze messages, can EXPIRE undelivered" repo orchestrator --date 2026-11-09
  add "Unrelated" repo all
  dup=2026-11-09-merge-freeze-messages-can-expire-undelivered
  run L status
  [[ "$output" == *"added_since_consolidation=3"* && "$output" == *"consolidation_due=no"* ]]
  ORCHESTRATE_LEARNINGS_CONSOLIDATE_EVERY=3 run L status
  [[ "$output" == *"consolidation_due=yes"* ]]
  run L consolidate
  [ "$status" -eq 0 ]
  [[ "$output" == *"dup	$FREEZE	$dup"* ]]
  [[ "$output" == *"upstream	$FREEZE"* ]]
  [[ "$output" != *Unrelated* ]]
  run L supersede --id "$dup" --by "$FREEZE" --note "same delivery gap"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE/learnings/$dup.md" ]
  grep -q "absorbed $dup (merge freeze messages, can EXPIRE undelivered): same delivery gap" "$STATE/learnings/$FREEZE.md"
  grep -q "superseded $dup" "$STATE/learnings/history.log"
  [ "$(jq -r .learnings.active "$STATE/campaign.json")" = 2 ]
  ! grep -q "$dup" "$STATE/learnings/INDEX.md"
  run L consolidate --done
  [[ "$output" == *"consolidated at 2026-11-08T00:00:00Z"* ]]
  run L status
  [[ "$output" == *"added_since_consolidation=0"* && "$output" == *"last_consolidation_at=2026-11-08T00:00:00Z"* ]]
}

@test "retire drops a rule with a history line; unknown ids are refused" {
  add "Old rule" repo all
  run L retire --id 2026-11-08-old-rule
  [ "$status" -eq 2 ]
  run L retire --id 2026-11-08-old-rule --note "owner reversed it"
  [ "$status" -eq 0 ]
  grep -q "retired 2026-11-08-old-rule (Old rule): owner reversed it" "$STATE/learnings/history.log"
  run L list --all
  [[ "$output" == "history	2026-11-08	retired 2026-11-08-old-rule"* ]]
  run L show --id 2026-11-08-old-rule
  [ "$status" -eq 3 ]
  [[ "$output" == "refused: no learning 2026-11-08-old-rule" ]]
  run L supersede --id ../etc --by 2026-11-08-old-rule
  [ "$status" -eq 3 ]
}

@test "upstream: repo learnings stay local; a global one is printed, then created once and recorded" {
  add "Repo only" repo all
  run L upstream --id 2026-11-08-repo-only
  [ "$status" -eq 3 ]
  [[ "$output" == *"repo-specific"* ]]
  add "Merge freeze messages can expire undelivered" global merge-bot
  run L upstream --id "$FREEZE"
  [ "$status" -eq 0 ]
  [[ "$output" == "repo: kaeawc/waaagh"* ]]
  [[ "$output" == *"title: Doctrine: Merge freeze messages can expire undelivered"* ]]
  [[ "$output" == *"waaagh:learning id=$FREEZE"* ]]
  [ ! -f "$FX/calls" ]
  run L upstream --id "$FREEZE" --create
  [ "$status" -eq 0 ]
  [ "$output" = "upstreamed: https://github.com/kaeawc/waaagh/issues/321" ]
  grep -qx "upstream: https://github.com/kaeawc/waaagh/issues/321" "$STATE/learnings/$FREEZE.md"
  [ "$(jq -r .state "$STATE/ops/upstream-$FREEZE.json")" = done ]
  grep -q "upstream https://github.com/kaeawc/waaagh/issues/321" "$STATE/learnings/INDEX.md"
  run L upstream --id "$FREEZE" --create
  [ "$output" = "upstreamed: https://github.com/kaeawc/waaagh/issues/321" ]
  [ "$(wc -l <"$FX/calls")" -eq 1 ]
  run L status
  [[ "$output" == *"global_not_upstreamed=0"* ]]
}

@test "upstream --create with no URL back is unverified and journaled" {
  add "Global rule" global all
  touch "$FX/create-fail"
  ORCHESTRATE_UPSTREAM_REPO=me/fork run L upstream --id 2026-11-08-global-rule --create
  [ "$status" -eq 9 ]
  [[ "$output" == *"search me/fork for 'waaagh:learning id=2026-11-08-global-rule'"* ]]
  [ "$(jq -r .state "$STATE/ops/upstream-2026-11-08-global-rule.json")" = unknown ]
  grep -qx "upstream:" "$STATE/learnings/2026-11-08-global-rule.md"
}

@test "-h prints exactly the header" {
  run "$SCRIPTS/learning.sh" -h
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "# Campaign learnings:"* ]]
  [[ "${lines[${#lines[@]} - 1]}" == "#       issue was sent but its URL is unknown"* ]]
}

@test "doctrine: learnings.md covers the triggers and is wired into SKILL.md, the roles and README" {
  d="$SKILL/learnings.md"
  for s in "owner instruction" "procedural" "upstream" "consolidat" "learning.sh brief --role" "Why" "How to apply"; do
    grep -qi -- "$s" "$d"
  done
  grep -q "learnings.md" "$SKILL/SKILL.md"
  grep -q "learning.sh brief --role" "$SKILL/roles/_common.md"
  grep -q "learnings" "$SKILL/roles/README.md"
  grep -q '`learning.sh`' "$SKILL/../../README.md"
}
