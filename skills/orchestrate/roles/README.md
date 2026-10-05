# Role briefs

Each file is a complete brief for one single-pass agent. To launch a role:

1. Copy the template to `<state dir>/briefs/<role>.md` (`scripts/campaign.sh path`) the first time,
   filling every `{{PLACEHOLDER}}`. Reuse the filled copy on later passes; change it only when a
   rule changes.
2. Put the repository's own rules in `<state dir>/lane-rules.md` (things a fresh agent cannot
   guess: forbidden test suites, device and daemon rules, formatter quirks). Every brief tells its
   agent to read `_common.md` and that file first. Add a rule there when a lane trips on something
   — once, for every later lane.
3. The agent's prompt is then short: the brief's path plus this pass's inputs (PR list, holds,
   issue numbers, lane worktree, effort).

| Placeholder | Meaning |
|---|---|
| `{{REPO}}` | `owner/name` |
| `{{STATE}}` | the repo's state directory |
| `{{SCRIPTS}}` | absolute path of the skill's `scripts/` directory |
| `{{BASE}}` | default branch |
| `{{AUTHORS}}` | `--author` flags for the PRs this campaign may merge (the user, plus bots the user named) |
| `{{IGNORE_CHECKS}}` | `--ignore-check` flags for advisory checks, from memory |
| `{{CI_CLASSIFIER}}` | the repo's CI failure classifier and known-flakes list, or "none" |
| `{{REBASE_GATES}}` | commands that must pass before a branch update is pushed |
| `{{GENERATED_FILES}}` | conflict-prone generated files and the command that regenerates each |
| `{{VERIFY_SKILL}}` | the repo's verification skill (for example a manual-test skill) |
| `{{DEVICES}}` | the devices this batch may use, and the ones it must never touch |

| Role | Template | Agent | Writes |
|---|---|---|---|
| Merge bot | `merge-bot.md` | `general-purpose`, `model: "haiku"` | merges only |
| Rebase bot | `rebase-bot.md` | `general-purpose`, `model: "sonnet"` | base merges into PR branches |
| Hygiene bot | `hygiene-bot.md` | `general-purpose`, `model: "sonnet"` | labels, links, evidence-backed closes |
| Verification | `verification.md` | `general-purpose`, `model: "sonnet"` | new issues for findings |
| Implementation lane | `implementation-lane.md` | `waaagh:sol-implementer` | uncommitted diff in its worktree |
| PR doctor | `pr-doctor.md` | `waaagh:sol-implementer`, `REASONING: high` | commits on its own PR branches |
| Conflict lane | `conflict-lane.md` | `waaagh:sol-implementer` | resolved markers, uncommitted |
| Reviewer | `review.md` | `general-purpose`, `model: "sonnet"` (or `"opus"`) | findings file |
