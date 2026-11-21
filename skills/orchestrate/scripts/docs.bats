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

@test "lanes are fresh and small per task, never resumed for new work (#21)" {
  has "$SKILL" "One fresh, small lane per task."
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

@test "lanes are claimed against duplicates and lanes re-verify state before asserting it (#24)" {
  has "$SKILL" "lane-claim.sh\" add"
  has "$ROLES/implementation-lane.md" "Search the open PRs for the issue number"
  # Every manifest that compiles a touched file is built, not only the nearest one (#316).
  has "$ROLES/implementation-lane.md" "Build every manifest that compiles a file you touched"
  has "$ROLES/implementation-lane.md" "swift build --package-path"
  has "$ROOT/skills/orchestrate/SKILL.md" "does not prove the aggregate build"
  has "$ROLES/_common.md" "re-read it with"
}

@test "generated-file conflicts go through regen-merge.sh (#25)" {
  has "$ROLES/rebase-bot.md" "regen-merge.sh --worktree"
  has "$SKILL" "Merge the base immediately"
  has "$ROLES/README.md" "generated-files.tsv"
}

@test "red main covers per-test timing budget breaches, and failing checks need logged evidence (#26)" {
  has "$SKILL" "**Per-test timing budgets.**"
  has "$SKILL" "\`pr-merge.sh --main-fix\`"
  has "$SKILL" "A lane saying \"infra\" is not evidence."
}

@test "the desktop PR monitor call sequence is documented exactly (#27)" {
  has "$SKILL" "\`bind_pr\` with \`url\` = the full PR URL"
  has "$SKILL" "\`set_monitor\` with the same \`url\` plus at least one of \`auto_fix: true\`"
  has "$SKILL" "\`auto_archive_on_close: true\`"
  has "$SKILL" "needs no fix pass and no"
}

@test "traveling mode: labels start workers, one lease-held writer, verdicts as head-bound statuses" {
  T="$ROOT/skills/orchestrate/traveling-mode.md"
  has "$T" "A cloud session cannot start cloud sessions; labels can"
  has "$T" "the push must fast-forward"
  has "$T" "If the push is rejected, another writer exists. Stop without acting."
  has "$T" "worker-review has the App broker post the commit status \`orchestrate/review\`"
  has "$T" "GitHub refuses an author's own approval"
  has "$T" "Pushes made with Actions' \`GITHUB_TOKEN\` start no workflows"
  has "$T" "No credential is ever written to the store or to a prompt."
  has "$T" "starts a worker through that worker routine's own **GitHub event trigger** (#264)"
  has "$T" "**new private git repository**"
  has "$T" "**one folder per target repository**"
  has "$T" "The dedicated GitHub App merges (#265), never the session's own identity."
  has "$T" "Automation never creates the App, never creates, reads, rotates or stores the"
  has "$T" "A cloud session never sees the key or an installation token."
  has "$T" "\`actions/create-github-app-token\`"
  has "$T" "## Decisions and rejected options"
  [ "$(grep -cF "in one of two ways" "$T" || true)" -eq 0 ] || { echo "traveling-mode.md still offers two trigger paths"; return 1; }
  has "$ROLES/cloud-orchestrator.md" "Exit at once, with no changes, unless it added the label cloud-dispatch"
  has "$ROLES/cloud-orchestrator.md" "merge  --repo {{REPO}} --pr N --sha <head>"
  has "$ROLES/cloud-orchestrator.md" '"$SCRIPTS/travel-cycle.sh" run --repo {{REPO}} --store "$STORE"'
  has "$ROLES/cloud-orchestrator.md" "merges only through the App broker"
  has "$ROLES/cloud-orchestrator.md" "Never merge or post orchestrate/review with your own identity"
  has "$ROLES/cloud-orchestrator.md" "Never post that status with your own identity."
  has "$ROLES/cloud-orchestrator.md" "No session creates, enables or fires a"
  has "$SKILL" "\`traveling-mode.md\`"
  has "$ROLES/README.md" "\`cloud-orchestrator.md\`"
}
