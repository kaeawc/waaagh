#!/usr/bin/env bats
# Doctrine contracts for background subagent hygiene (#59): premise-first, monitor-free,
# line-budgeted briefs; TaskStop vs stop messages; model choice by role. Run: bats subagent-hygiene.bats

setup() {
  load test_helper
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SKILL="$ROOT/skills/orchestrate/SKILL.md"
  HYG="$ROOT/skills/orchestrate/subagent-hygiene.md"
  COMMON="$ROOT/skills/orchestrate/roles/_common.md"
}

has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "every role checks the premise first and stops its monitors before finishing" {
  has "$COMMON" "Check the premise first"
  has "$COMMON" "stop every monitor, watch or background task you armed (\`TaskStop\`)"
  has "$COMMON" "line budget, which wins"
  has "$HYG" "**Check the premise first.**"
  has "$HYG" "**Stop every monitor before finishing.**"
  has "$HYG" "**Report in N lines.**"
}

@test "closed or noisy lanes get a stop message or TaskStop, never a resume" {
  has "$HYG" "The lane's issue closed elsewhere"
  has "$HYG" "Send it a stop message"
  has "$HYG" "only later notifications come from stale monitors"
  has "$HYG" "Do not resume it to clean up"
  has "$SKILL" "**Stop what is done or only noisy** (\`subagent-hygiene.md\`)"
  has "$ROOT/skills/orchestrate/owner-decisions.md" "## Stop lanes on close"
}

@test "model choice by role: Haiku for single-issue lanes, Sonnet for routers, sweeps, batches, fixes" {
  has "$HYG" "| Single-issue lane driver, premise check"
  has "$HYG" "| Router, local sweep, hygiene bot, rebase bot | \`sonnet\`"
  has "$HYG" "| Verify batch over several issues, verification | \`sonnet\`"
  has "$HYG" "conflict fix or a static-analysis fix (Detekt"
  has "$SKILL" "\`model: \"haiku\"\` for a single-issue lane or premise check"
}

@test "the hygiene doc is indexed in the README" {
  has "$ROOT/README.md" "skills/orchestrate/subagent-hygiene.md"
}
