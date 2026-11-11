#!/usr/bin/env bats
# Doctrine contracts for Claude-only implementation lanes (#220): a Sonnet or Opus subagent writes
# the code and tests itself, the orchestrator commits, and validation and review stay independent.
# Nothing that only existed to drive, supervise or budget an external implementer CLI remains.
# Run: bats claude-lanes.bats

setup() {
  load test_helper
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  D="$ROOT/skills/orchestrate"
  SKILL="$D/SKILL.md"
  LANE="$D/roles/implementation-lane.md"
}

has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "the external-implementer runner, agents and reference are gone" {
  for p in agents bin lanes skills/orchestrate/scripts/usage-report.sh; do
    run test -e "$ROOT/$p"
    [ "$status" -ne 0 ] || { echo "still present: $p"; false; }
  done
}

@test "the doctrine names no external implementer and none of its supervision rules" {
  local f hits=""
  for f in "$SKILL" "$D/subagent-hygiene.md" "$D/lane-safety.md" "$D"/roles/*.md "$ROOT/README.md" \
           "$ROOT"/.claude-plugin/*.json "$D/scripts/validate.sh"; do
    hits+=$(grep -HniE 'codex|gpt-|openai|luna|\bsol\b|implementer-(unavailable|capacity)|smoke-test|usage-report|REASONING:' "$f" || true)
  done
  [ -z "$hits" ] || { echo "$hits"; false; }
}

@test "routing: Sonnet lanes for routine work, Opus lanes for judgment, both general-purpose" {
  has "$SKILL" "| Implementation lane — routine, fully specified work"
  has "$SKILL" "| Implementation lane — judgment work (PR doctor, conflict lane, supersede evidence"
  has "$SKILL" "**The lane implements, and someone else checks it.**"
  has "$D/roles/README.md" "| Implementation lane | \`implementation-lane.md\` | \`general-purpose\`, \`model: \"sonnet\"\`"
  for r in pr-doctor conflict-lane supersede-evidence; do
    has "$D/roles/README.md" "\`$r.md\` | \`general-purpose\`, \`model: \"opus\"\`"
  done
}

@test "the lane writes code and tests itself, leaves them uncommitted, and its own run is not evidence" {
  has "$LANE" "you write the code"
  has "$LANE" "Commit and push nothing"
  has "$LANE" "fail before the fix"
  has "$LANE" "(no \`--independent\`"
  has "$SKILL" "Implementation lanes leave changes uncommitted and run no mutating VCS commands; you commit and"
  has "$SKILL" "(the Haiku validator) passes \`--independent\`"
  has "$D/scripts/validate.sh" "never the lane itself"
}

@test "the implementation spec keeps six parts and puts the model on the Agent call" {
  has "$SKILL" "5. **Tests**"
  has "$SKILL" "6. **Verification**"
  has "$SKILL" "Agent call's \`model\`"
  has "$SKILL" "move it from Sonnet"
}
