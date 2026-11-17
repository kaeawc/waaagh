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
      Before the fixtures check it runs `open-blockers.sh` for the issue (REST). Exit 8: an open
      issue blocks it (the error names the blockers) — `queue drop N` and route the blocker
      first. Exit 7 also covers blockers that could not be read: unverified is not clear, so
      leave it for the next batch. `--no-blocker-check` skips the check only when you have just
      run `open-blockers.sh` yourself. `queue add` runs the same check and warns
      (`warning: #N BLOCKED by ...`); drop a warned issue then rather than at payload time.
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
line `<!-- waaagh-brief <kind> v<V> -->`) are the default; a change to one bumps its version and
appends a row to `versions.tsv` (the bump rule, `../briefs/README.md`):

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
   PR #P (issue #N, branch work/N-auto).`), then `record --kind repair --pr P`; a repair is never
   refused as a second dispatch and never counts as one.
4. **A repair is in flight until it ends** (#212). `record --kind repair --pr P` marks PR P
   `repairing` with the trigger id as the session (`review-ledger.sh repair`): P does not merge on
   any path and `review-ledger.sh record --verdict ship` is refused (exit 6), because a session's
   first pushed commit is not the end of its repair. A second repair of P is refused (`payload`
   exit 3) while one is in flight. It ends when the session posts its closing comment
   (`REPAIR-END done:`, `REPAIR-END blocked:` or `SUPERSEDED-CANDIDATE`, from `repair.md`):
   `review-ledger.sh settle`, which every triage tick runs, records it `repaired`. When the
   session's run ended without that comment (the routine shows it finished or failed), record it
   yourself: `review-ledger.sh repaired --pr P --session <trigger> --note "run ended"`. A
   `repaired` PR still waits for a review of its final head; only that `ship` lets it merge.
5. **One writer once a repair is sent** (#214). The session that opened P is still a writer: it
   wakes on P's CI, review and bot events and can push after the repair session has. So `record
   --kind repair --pr P` also posts one marker comment on P, starting `REPAIR-START session <trigger>:`
   with the hidden key `<!-- waaagh:repairing pr=P session=<trigger> -->` (`repair-writer.sh mark`;
   it reads P's comments over REST first and posts nothing when the key is there). The implement
   brief (v4) reads P's comments before every push and stops at a `REPAIR-START`. Exit 10 means
   the row and the `repairing` mark stand but the marker was not posted: run the `repair-writer.sh
   mark` line it prints before the repair session starts. The triage tick runs `repair-writer.sh
   check`: a `repair-writers` line names a PR under repair whose commits since the dispatch carry
   two writers (session trailer, else author email) or whose branch was force-pushed. It cannot
   tell two sessions apart that commit under one identity with no trailer, or see when an older
   commit was pushed: GitHub's commit metadata names no pusher. So the marker is the guard and the
   check is a backstop.

## Results come back only through PRs

Cloud sessions cannot message the orchestrator. Their only output is the PR on `work/<N>-auto` and,
when blocked, one comment on the issue. So the triage loop reads them: `pr-ready.sh` and
`pr-intake.sh` pick up the PRs (merge bot, rebase bot and PR doctor treat them like any other PR of
the author). A `Part of #N` PR leaves the issue open for its local remainder. The ledger refuses a
second dispatch of a live one.

## Stale dispatches (#259)

A dispatch is not handled forever. A session that failed, stopped early or never opened a PR
leaves its issue in the ledger with nothing to show for it, and both the queue and the tick's
`dispatch` count leave a live dispatch out. So:

- `cloud-dispatch.sh stale` lists every live dispatch older than `--hours` (default
  `ORCHESTRATE_DISPATCH_STALE_HOURS`, 6, from its `run_at`) whose issue is still open and that no
  open or merged PR cross-references: `stale #N dispatches=K/CAP since=<run_at> age=<h>h`, or
  `capped #N ...` once it was dispatched `--cap` times (default `ORCHESTRATE_DISPATCH_CAP`, 3).
  The triage tick runs it for its suspects and prints the `dispatch-stale` line.
- For a stale issue, read its comments first (a blocked session leaves one), then
  `cloud-dispatch.sh expire --issue N`: it checks again, appends an `expired` row to the ledger
  and puts N back on the queue, and `next`, `payload` and `record` take it as a new dispatch. It
  refuses (exit 3) a dispatch that is not stale yet, has a PR (repair that instead) or is closed;
  `--force` skips that check when you know the session died. It always refuses at the cap: an issue
  whose sessions keep ending without a PR is re-routed or handed to a local lane instead.

## Stalled runs (#260)

Six hours is too long to wait on a run that died early. A routine run can go silent while it still
reports `status: active, worker_status: running`, stop on a permission prompt nobody will answer,
end its turn with no PR, or never start at all. Only the main session can see this:
`RemoteTrigger list_runs` and `get_run_log` are its tools, not commands a script can call. So the
main session fetches the runs and `cloud-dispatch.sh stalled` judges them, offline:

1. **When to look.** Each tick, for every live dispatch whose issue has no PR yet: about 15
   minutes after its `run_at`, then from about an hour after it, call `RemoteTrigger list_runs`
   for its trigger and save the JSON to a file in the state directory (one file per trigger;
   never paste it into a brief or a comment).
2. `cloud-dispatch.sh stalled --runs FILE --issue N` prints one line per run that needs you, and
   nothing for a run still producing events or a trigger not yet due. It reads `status`,
   `worker_status` and `last_event_at` and tolerates missing fields; a run it cannot judge is
   `unknown` (exit 7): look at it yourself.
   - `stalled #N run=R ... silent=<m>m`: running, but no event for more than `--minutes` (default
     `ORCHESTRATE_RUN_STALL_MINUTES`, 45). Read `get_run_log` for what the run learned (for
     example: the target file was at its size cap, so start from a separate module). Then
     `cloud-dispatch.sh expire --issue N --force` (the run is dead though it is under the stale
     hours) and dispatch again with a **new trigger and a new branch**: `payload --issue N ...
     --brief-ref implement --branch work/N-auto-2 --note "<what it learned, one line>"`, then
     `record` the new trigger as usual. The new branch keeps a run that wakes up late from
     pushing over the new one. The cap still holds.
   - `blocked #N run=R status=.../requires_action`: the run stopped on a permission prompt
     (`get_run_log` ends with a `permission prompt` event) and will sit until it expires. Treat
     it as dead. It wrote nothing, so re-fire the same trigger (`RemoteTrigger run`, then
     `update {"enabled": false}`); no second writer lands on the branch. When the prompt was for
     a compound command, tell the next dispatch in `--note`: one plain command per Bash call, no
     globs outside the repository.
   - `ended #N run=R status=.../idle`: the run ended cleanly with no PR. **Read its final message
     first** (`get_run_log`): it often stopped on a real question, which goes to
     `needs-decision` (post the question on the issue), not to a redispatch. Check the log also
     for a commit it never pushed (a gate moved to the background when the turn ended): a run
     whose PR head is older than the run's start is not done either. Redispatch, as for
     `stalled`, only when the log shows neither a question nor work worth keeping.
   - `unfired #N trigger=T run_at=... late=<m>m`: the run-once trigger never started a run, more
     than `ORCHESTRATE_RUN_UNFIRED_MINUTES` (15) after `run_at`. Fire it with `RemoteTrigger run`,
     then `update {"enabled": false}` at once, so the late scheduler cannot start a second run on
     the same branch.

**The attribution footer (#261).** A cloud session's PR body can end with `_Generated by [Claude
Code](https://claude.ai/code/session_…)_` even though the brief says "No attribution lines": the
harness adds it when it creates the PR, and repeating the rule in the brief does not stop it. Once
per merge-loop pass (`roles/triage-tick.md`), or when a cloud PR appears, run
`{{SCRIPTS}}/pr-footer.sh --cloud`: for every open PR on a `work/<N>-auto` branch it removes that
trailing line and a `---` rule left above it over REST (`PATCH pulls/N`) and reads the body back;
a body without the footer is not written. A body edit does not move the head, so it needs no
re-review. It strips only while the brief the sessions follow says "No attribution"
(`--policy auto`, the default: `{{STATE}}/cloud-brief.md`, else `cloud-session-brief.md`; with
`--brief-ref`, pass `--brief <checkout>/.claude/briefs/implement.md`). A repository that keeps the
attribution says so in its brief, or sets `ORCHESTRATE_PR_FOOTER_POLICY=keep`; another footer
wording goes in `--pattern` (or `ORCHESTRATE_PR_FOOTER_PATTERN`).
