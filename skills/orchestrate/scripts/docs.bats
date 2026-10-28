#!/usr/bin/env bats
# Doctrine contracts: the rules the orchestrator and its roles must keep stating, so an edit that
# drops one fails here. Run: bats docs.bats

setup() {
  load test_helper
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SKILL="$ROOT/skills/orchestrate/SKILL.md"
  ROLES="$ROOT/skills/orchestrate/roles"
}

has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "lane drivers are fresh and small per task, never resumed for new work (#21)" {
  has "$SKILL" "One fresh, small driver per task."
  has "$SKILL" "never hand a long-lived lane new work with \`SendMessage\`"
  has "$SKILL" "only to ask about the work it just returned"
  has "$SKILL" "never transcripts or full"
  has "$SKILL" "about 15 lines"
  has "$SKILL" "a PR gets one event watch"
  has "$ROLES/README.md" "Every pass is a fresh agent."
  has "$ROLES/_common.md" "Keep your final report short"
}

@test "an interim 'waiting on background work' stop is not acted on, and gates run inline (#22)" {
  has "$SKILL" "An interim stop is not a result."
  has "$SKILL" "no merge, no relaunch, no verdict"
  has "$SKILL" "final notification of the same task"
  has "$ROLES/_common.md" "never in the background"
  has "$ROLES/implementation-lane.md" "never background one"
  ! grep -q "backgrounded its work and idled has done nothing" "$SKILL"
}

@test "the campaign loop documents wrap-up (#23)" {
  has "$SKILL" "\`\"\$SCRIPTS/campaign.sh\" wrap-up on\`"
  has "$SKILL" "skip Plan (4) and Fill (6)"
  has "$SKILL" "drained=yes"
}
