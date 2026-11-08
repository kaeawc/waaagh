# Cloud dispatch — orchestrator procedure ({{REPO}})

One no-click cloud session per `cloud-ready` issue, each started by a **run-once routine**. This is
not a subagent brief: subagents do not have `RemoteTrigger`. **Only the main session can dispatch**,
so the orchestrator runs these steps itself. The per-issue brief each cloud session receives is
`cloud-session-brief.md` (override per repository with `{{STATE}}/cloud-brief.md`), rendered by
`{{SCRIPTS}}/cloud-dispatch.sh brief`.

Use it only when the owner asked for cloud sessions started without a click. Why routines:
`start_session` with a cloud target works only while the session is on screen (it returns
`not_on_screen` otherwise), and the cloud session it creates waits as a card until a human starts
it. A run-once routine (`RemoteTrigger create` with `run_once_at` about a minute out) starts a fresh
cloud session by itself.

## What runs where

| Runs in the cloud | Stays local |
|---|---|
| Linux, no devices, no Xcode: `cloud-ready` issues (`../routing.md`) — code with tests that run on Linux (JVM, Node, scripts), CI, docs, design or reading research | `needs-local:*` issues: anything that needs an emulator, simulator, attached device, macOS or Xcode, or a local measurement; device verification of a cloud PR marked `Part of #N` |

A cloud lane that finds it needs a device opens its PR as `Part of #N` and lists what is left; the
issue then gets a local route for that remainder (`issue-route.sh set`), never a second cloud lane.

## Inputs, once per campaign

- `ENV`: the cloud environment id (`env_…`) the sessions run in, and `SOURCE`: the repository URL
  (or one `session_context.sources` entry as JSON). `MODEL` if the owner named one.
- `GATES`: the repository's gate commands, as one short line for the brief.
- **The standard briefs, in the repository** (the default once installed; see "Briefs in the
  repository" below): `cloud-dispatch.sh briefs check --remote` must pass before you dispatch with
  `--brief-ref`. Until it does, dispatch with the rendered brief (no `--brief-ref`).

## Steps

1. **Queue.** `{{SCRIPTS}}/issues-ranked.sh --route cloud-ready --skip-in-pr --drop-blocked` (blocked issues out: `open-blockers.sh`; after the router has
   run), then `cloud-dispatch.sh queue add <N>...`. The queue (`{{STATE}}/cloud-queue.txt`) and the
   ledger (`{{STATE}}/cloud-sessions.tsv`: issue, trigger id, run_at, created_at) live in the state
   directory, so dispatch resumes after a compaction from `cloud-dispatch.sh status` and `next`;
   never from memory of what was sent.
2. **Batch.** Take `cloud-dispatch.sh next --count 4` (batches of 3 to 5). For each issue:
   1. `cloud-dispatch.sh pace` → `wait <s>`; wait that long first (non-zero after a 429 or at the
      per-minute cap).
   2. `cloud-dispatch.sh payload --issue N --env ENV --source SOURCE [--model MODEL] --gates
      "GATES"` prints the create object: `run_once_at` staggered 20 s after the last dispatched
      run (and at least 60 s out), `job_config.ccr.environment_id`, `session_context.sources` and
      `model`, and the brief as `events[0].data.message`. Exit 3: already dispatched, skip it.
      It first runs the **fixtures check** (`../device-cloud-handoff.md`): an issue that mentions
      captured fixtures must carry them (a `<details>` comment or a linked fixtures PR), and the
      brief then says "commit the fixtures from <url> verbatim". Exit 5: they are missing — `queue
      drop N` and route it back to the local lane; never dispatch it to invent them. Exit 7: the
      issue could not be read; leave it for the next batch.
      With `--brief-ref implement` the message is one line, `Follow .claude/briefs/implement.md
      for issue #N (branch work/N-auto).`, plus ` Fixtures: <url>... (commit verbatim).` when the
      fixtures check names any; the session reads the brief from its own checkout.
      Map its fields onto the `RemoteTrigger create` call; if the tool's schema places a field
      elsewhere, follow the tool.
   3. `RemoteTrigger create`. On HTTP 429 ("Try again in Ns"): `cloud-dispatch.sh backoff
      --message "<the error line>"` (20 s when it names no wait), then retry the same issue.
   4. On success: `cloud-dispatch.sh record --issue N --trigger <trigger id> --run-at
      <run_once_at>`, before anything else.
3. Between batches, let the triage loop run (below); continue until `next` is empty.

## Hazards

- **Never `run` a routine that is still enabled with a future `run_once_at`**: it fires it twice
  (two sessions, two PRs for one issue). Let it fire on its own; if you must start it now, disable
  it right after `run`.
- **Creation is rate limited** at about 10 per minute; a burst of 5 can already return 429. Keep
  batches of 3 to 5 with staggered `run_once_at`, and back off on every 429.
- **Echo cost.** Every create response repeats the prompt about four times (derived_state,
  job_config, session_request, events): a 900-character brief costs about 3k tokens of orchestrator
  context per dispatch, a one-line `--brief-ref` prompt about 100. So dispatch with `--brief-ref`
  once the briefs are in the repository; otherwise keep the brief short (the template is under 1500
  characters; `cloud-dispatch.bats` holds it there). Never paste a response anywhere and keep only
  the trigger id: a response that reaches you as text or a file (an API call rather than the tool)
  goes through `cloud-dispatch.sh created --issue N`, which prints `created <trigger> <run_at>`,
  records it and drops the echoed prompt.
- **Finished routines pile up** at claude.ai/code/routines and the tool cannot delete them. Tell the
  owner once, at the end of the campaign, how many were created (`status` → `dispatched`) so they
  can clear them.

## Briefs in the repository

The standard implement and repair briefs live in the target repository as
`.claude/briefs/implement.md` and `.claude/briefs/repair.md`, so a brief change lands as a reviewed,
versioned PR and stops drifting between ticks (a repository knob such as a test wall-clock timeout
goes into the file once, not into every prompt by hand). waaagh's templates (`../briefs/`, first
line `<!-- waaagh-brief <kind> v<V> -->`) are the default:

1. `cloud-dispatch.sh briefs install --dir <checkout> --base <base> --gates "GATES"` writes both
   with the repository, base and gates filled (the per-issue values stay in the one-line prompt);
   it never overwrites a different file without `--force`. Commit them on a branch and merge them
   by PR like any change; edit them later only by PR.
2. `cloud-dispatch.sh briefs check --remote` reads them from the base branch: `ok`, `custom` (no
   version line: the repository wrote its own; kept), `outdated` (waaagh's template is newer:
   re-install, review the diff, PR) or `missing`. Exit 6 on missing or outdated: dispatch the
   rendered brief instead until it passes.
3. Dispatch with `payload --brief-ref implement`. To send a cloud session back to its own red or
   reviewed PR: `payload --issue N --pr P --brief-ref repair` (`Follow .claude/briefs/repair.md for
   PR #P (issue #N, branch work/N-auto).`), then `record --kind repair`; a repair is never refused
   as a second dispatch and never counts as one.

## Results come back only through PRs

Cloud sessions cannot message the orchestrator. Their only output is the PR on `work/<N>-auto` and,
when blocked, one comment on the issue. So the triage loop reads them: `pr-ready.sh` and
`pr-intake.sh` pick up the PRs (merge bot, rebase bot and PR doctor treat them like any other PR of
the author), and an issue in the ledger with no PR after a few hours gets its comments read. A
`Part of #N` PR leaves the issue open for its local remainder. Do not dispatch an issue twice: the
ledger refuses it, and a stuck one is re-routed or handed to a local lane instead.
