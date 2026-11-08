# Background subagent hygiene

Background subagents (lane drivers, sweeps, routers, verify batches) cost Claude usage for as long
as they run and for every notification they send. Three habits keep them quiet and short: briefs
that close every loose end, stopping lanes whose work is gone, and the cheapest model that can do
the role. This extends the Mechanics rules in `SKILL.md` ("One fresh, small driver per task", "An
interim stop is not a result") and `roles/_common.md`; it does not replace them.

## What every brief says

Every role template inherits these from `roles/_common.md`; a one-off brief you write by hand
states them itself:

1. **Check the premise first.** Before any work, confirm the issue still describes the code: read
   the files it names at current `origin/<base>` and search open PRs for it. Already fixed, already
   covered by a PR, or closed: stop and report `already-done` with file:line or PR evidence. A
   premise check is cheap; a lane that implements a fixed issue is the most expensive no-op.
2. **Stop every monitor before finishing.** A subagent arms no background watch, `Monitor` or
   scheduled wake-up unless its brief says so; one that did stops each with `TaskStop` (and kills
   each PID it started) before its report. A self-armed monitor outlives the agent and keeps
   sending "waiting on its own background work" notifications after the report: one lane sent six
   such no-op notifications. Briefs that said "leave no background watches running" cut that
   noise to zero.
3. **Report in N lines.** Give the budget as a line count (`Report (at most 12 lines)`) and the
   format line by line, starting with a `STATUS:` line. Without a budget a report narrates; with
   one it is the result.

## Stopping lanes

| Situation | Action |
|---|---|
| The lane's issue closed elsewhere (a merged PR's `Fixes #N`, the owner, a bot, another lane's close) and the lane is still working | Send it a stop message (`owner-decisions.md`, "Stop lanes on close"): the issue is closed; leave the worktree as it is and report. Then `lane-claim.sh set --worktree WT --status closed`. |
| The lane's issue closed and the lane does not answer the stop message, or has nothing left to report | `TaskStop` its task. Record the lane as `closed` in `lanes.tsv`. |
| The lane's report is in, and its only later notifications come from stale monitors or background tasks it armed and never stopped | `TaskStop` the task. Do not resume it to clean up: a resume re-sends its whole context to stop a watch. Add "stop all monitors before finishing" to the brief for later lanes. |
| The lane's PR merged, or its work was invalidated (re-planned, superseded) | Stop message if it is still doing useful work you want reported; otherwise `TaskStop`. |
| An interim stop while its own gate still runs (`SKILL.md`, "An interim stop is not a result") | Nothing: wait for the final notification. This is not a stale monitor. |

`TaskStop` ends a task without a report, so use a stop message when the lane holds results you
still want (a partial diff, evidence); use `TaskStop` when it holds nothing but noise. Never stop
a task you did not launch.

## Model choice by role

Pick the cheapest model that has done the role well; always pass `model` explicitly.

| Role | Model | Why |
|---|---|---|
| Single-issue lane driver, premise check, validation batch, merge bot, triage tick | `haiku` | One issue, a fixed checklist, a short report: Haiku drivers did well on premise checks and verification batches. |
| Router, local sweep, hygiene bot, rebase bot | `sonnet` | Many items and cross-item judgment (duplicates, routing, clusters). |
| Verify batch over several issues, verification | `sonnet` | Multi-issue verification batches needed Sonnet. |
| Driver for a conflict fix or a static-analysis fix (Detekt, lint baselines) | `sonnet` | Both sides' intent, or a rule's intent, must survive; these fixes needed Sonnet. |
| The one independent reviewer per lane | `opus` | `SKILL.md`, "Choosing the reviewer". |
| Concept and architecture review | `fable` | `SKILL.md`, "Choosing the reviewer". |

A Haiku lane that fails its spec once is relaunched on Sonnet, as a stated decision; it is not
resumed. Implementation itself stays with the codex implementers (`SKILL.md`, "Codex implements").
