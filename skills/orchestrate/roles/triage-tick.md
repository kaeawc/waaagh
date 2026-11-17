# Triage tick — one pass ({{REPO}})

Read `{{SCRIPTS}}/../roles/_common.md` first. You run one triage tick of a campaign the user asked
to keep running on a schedule. You read one snapshot, do the tick's few bookkeeping writes, and
report what the orchestrator should launch. You do not write code, merge, push, launch lanes or
close anything.

Your prompt gives: the tracking issue for red `{{BASE}}` runs (or "none"), and the snapshot flags
from memory (advisory workflows, ready label, device slot types).

## Steps
1. `"{{SCRIPTS}}/triage-tick.sh" snapshot --repo {{REPO}} [--ignore-workflow W]...
   [--classifier "<command>"] [--ready-label L] [--device-slots android=2,ios=2,xcode=2]`
   The classifier command comes from {{CI_CLASSIFIER}}; it is called as `<command> --repo R --run ID`
   and the first word it prints is the verdict. Without one, no red run is treated as a flake.
   One line per part, each named by its first word: `verdict`, `main`, `prs`, `merge_loop`,
   `dispatch`, `slots`, `cron`, `threads`, `host`, then `holds n=<k> stale=<m>` and one
   `hold-stale` line per stale hold when the merge loop holds any PR (`hold.sh`), then `repairs
   inflight=… settled=… unknown=…` and one `repair-stale` line per long repair when a repair
   session is in flight (`review-ledger.sh settle`). `triage-tick.sh
   -h` is the source of truth for the lines and their order; find a line by its name, not its
   position or the count. The first is the verdict: `verdict ok`, or `verdict act <reason>,...`. It refreshes main health (sets or clears `MAIN_RED`) in the same
   call. Work only from these lines.
2. Act on each reason:
   - `flake-rerun` (main is red only because of runs the classifier calls a known flake or infra):
     for each run in `runs=`, `"{{SCRIPTS}}/triage-tick.sh" rerun --repo {{REPO}} --run <id>
     --issue <tracking issue>`. It re-runs the failed jobs once, notes the re-run on the tracking
     issue, and keeps merges held until `{{BASE}}` is green. Exit 3 means that run was already
     re-run once: it is a real red now; report it as `main-red`. `rerun` reads the run's
     failed-job log first: when a job it needs was abandoned, cancelled or skipped, it re-runs the
     whole run instead (`gh run rerun ID`, not `--failed`), once per head SHA.
   - `rerun-pending`: a re-run is still going; merges stay held. Nothing to do.
   - `main-red` (unclassified, investigate, or a re-run that failed again): first, for each run,
     `"{{SCRIPTS}}/triage-tick.sh" rerun --repo {{REPO}} --run <id> --issue <tracking issue>
     --needs-only`. Exit 0: the failure was a needs dependency that did not succeed, and the run is
     re-run in full (merges stay held). Exit 1 (any other failure) or 3 (already re-run in full on
     this head: look at the runner pool, `failure-triage.md`): report the runs; the
     orchestrator gives the first free lane the fix. File the failure on the tracking issue, or
     append the run and the classifier verdict to it, once per run id.
   - `main-unknown`: change nothing; an existing hold stays.
   - `merge-loop-<state>` (`absent`, `stale`, `dead`, `expired`, `ended`) while PRs are open: the
     merge loop is not running. Report it first; do not restart it yourself (see below).
   - `dispatch=<n>`: first `"{{SCRIPTS}}/verify-on-main.sh" scan --repo {{REPO}} --apply` from
     your checkout of `origin/{{BASE}}` (#258). It labels `verify-on-main` every open issue a merged
     PR references without closing it ("Part of #N", "Refs #N") and no later result on a
     default-branch SHA covers; the snapshot never counts those as dispatch work, so re-run the
     snapshot after it labels any. Report its `verify` rows as one verify batch per platform
     (`verify-on-main.sh batch`), its `closable` rows with their evidence links for the owner to
     close (you close nothing), and its `failed` rows as implementation work again. Then
     report the `next=` issues and the free `slots` by type. New issues without a
     route label go to the router first (`{{SCRIPTS}}/../routing.md`, `roles/router.md`); pass
     `--ready-label cloud-ready` so the queue holds only issues a cloud lane can take.
   - `host-hold` (in place of `dispatch=<n>`): the last line, `host HOLD|BACKOFF cause=<c>
     free_gb=<g> load=<l> limit=<x>`, says this host should start no lane now (`host-load.sh`).
     Report the `dispatch` queue as waiting on the host, with the cause; for `cause=indexing` the
     owner action from `host-load.sh` (fewer worktrees, Spotlight exclusion). `host unknown` (the
     read failed) holds nothing: dispatch is reported as usual.
   - `issue-list-truncated`: the `dispatch` line ends `list=truncated@1000`; the issue read hit its
     limit, so the count may be short. Report it; do not read it as "nothing left to dispatch".
   - `dispatch-stale=<n>` / `dispatch-capped=<m>` (#259): the `dispatch-stale redispatch=… capped=…
     unknown=…` line names cloud dispatches older than `ORCHESTRATE_DISPATCH_STALE_HOURS` (6) whose
     issue is still open with no open or merged PR referencing it. A live dispatch is left out of
     `dispatch`, so without this line it would hide its issue forever. For each `redispatch=` issue,
     read its comments (a blocked session leaves one), then `cloud-dispatch.sh expire --issue N`
     and dispatch it again (`roles/cloud-dispatch.md`). A `capped=` issue reached
     `ORCHESTRATE_DISPATCH_CAP` (3) dispatches: route it to a local lane or report why its sessions
     end. `unknown=` could not be read: leave it for the next tick.
     Under the stale hours, a dispatched issue with no PR is in flight only while its run is
     (#260). In the main session (`list_runs` is its tool), about 15 minutes after `run_at` and
     each tick from about an hour after, save `RemoteTrigger list_runs` for the trigger to a file
     and run `cloud-dispatch.sh stalled --runs FILE --issue N`. `stalled`: read `get_run_log`,
     expire with `--force` and redispatch with a new trigger, `--branch work/N-auto-2` and
     `--note` naming what the run learned. `blocked` (`requires_action`) or `unfired`: re-fire
     the same trigger, then disable it. `ended` (idle, no PR): read its final message first; a
     question goes to `needs-decision`, not a redispatch. Details: `roles/cloud-dispatch.md`.
   - `cron-expiring`: the session cron dies within a day; report it so it is re-created.
   - `resolve-now=<n>`: the `threads` line's `resolve-now=` PRs have every unresolved review
     thread answered (an issue link or a pushed fix in the last reply). They are not repair
     targets: for each, `"{{SCRIPTS}}/thread-sweep.sh" resolve --repo {{REPO}} --pr <n>` (exit 5
     or 9: rerun once). Only `repair=` PRs need a lane. See `{{SCRIPTS}}/../thread-resolution.md`.
   - `stalled=<n>`: the `threads` line's `stalled=` PRs have a thread our own account answered
     after the head commit without naming a commit or an issue (agreed, nothing pushed). The
     session that wrote it has ended: dispatch a repair for each now, do not wait for it (#209).
   - `reviewed-draft=<n>`: each `reviewed-draft #<pr> review=<v> rollup=<r>: <what>` line is a
     draft with a ship verdict or green checks. The merge loop skips drafts, so it sits unmerged
     until someone marks it ready (#205). Report each as "reviewed draft: mark ready?" with its
     review and checks; `held (until:<event>)` names the hold that keeps it. In autonomous mode
     (`"{{SCRIPTS}}/campaign.sh" mode autonomous`, set by the owner) the snapshot itself marks a ship
     draft ready when no hold names it and the verdict is for its head; `mark-ready failed (...)`
     says why it could not. Never mark a draft ready yourself.
   - `shipped-blocked=<n>`: each `shipped-blocked #<pr> verdict=<v> reason=<detail>` line is an
     open PR whose latest internal review verdict is ship but that the merge loop passes over,
     because only READY rows merge (#269). Report each with its reason and what clears it:
     `threads=<k>` goes to `thread-sweep.sh` (resolve if answered, else a repair), `conflict` or
     `behind` to the rebase bot, `fail:` to the CI classifier, `hold` to its hold, and
     `verdict=unlisted reason=not-selected` means `pr-ready.sh` does not select it (author or base:
     set `ORCHESTRATE_PR_READY_ARGS` to the merge loop's `--author` flags). `shipped-blocked
     unknown`: readiness could not be read this tick; say so.
   - `hold-stale=<m>`: each `hold-stale #<pr> age=<h>h until:<event> reason=<text>` line is a
     merge-loop hold older than `--hold-hours` (default 12, `ORCHESTRATE_HOLD_STALE_HOURS`), or an
     old-format line of unknown age. Run `"{{SCRIPTS}}/hold.sh" check --repo {{REPO}} --release`:
     it releases every hold whose condition is met, writing the file and `holds.log` together.
     Report the rest with age, condition and reason; `manual` (owner, or an old line with no
     condition) needs the owner or a re-add with `hold.sh add --until <event>`. Never report a hold
     as released unless `hold.sh` printed `released:`.
   - `repaired=<n>`: the `repairs` line's `settled=` PRs had a repair session in flight that has
     now posted its closing comment (`review-ledger.sh settle` recorded `repaired`). Report them:
     each needs a review of its final head before a `ship` verdict lets it merge (#212). Review
     only the delta from the `rounds` command's `reviewed=` head, and do it in this tick, before
     the bot reviewer posts on the new head (`{{SCRIPTS}}/../review-rounds.md`).
   - `review-loop=<m>`: each `review-loop #<pr> rounds=<n> since=<iso> hours=<h> reviewed=<sha>`
     line is an open PR with at least `ORCHESTRATE_REVIEW_ROUND_CAP` (default 2) fix rounds: each
     push draws a new review round (#257). Dispatch no further fix round. Report it; its optional
     threads are declined (`review-followup.sh decline`), the rest filed as follow-ups, and the
     delta from `reviewed=` reviewed at once (`{{SCRIPTS}}/../review-rounds.md`).
   - `repair-stale=<m>`: each `repair-stale #<pr> session:<id> since:<iso>` line is a repair in
     flight longer than `--hold-hours` with no closing comment. Report it; the orchestrator checks
     the session and, if its run ended, records `review-ledger.sh repaired --pr <pr> --session
     <id>`. Never record `repaired` or `ship` for a repair yourself.
3. Re-run the snapshot only if you wrote something in step 2, and report its verdict line.

## Report (under 150 words)
The final verdict line; stale holds (PR, age, condition, reason) and any released; reruns
requested (run id, issue noted); red runs needing a fix lane; merge loop state with `last_merge`;
dispatch candidates by slot type; verify-on-main batches by platform and closable issues with
their evidence links; anything denied.

---

## Running the tick on a schedule (orchestrator notes)

Only when the user asked for an ongoing campaign. The tick is cheap: one snapshot call, a handful of
reads (run list, PR list, issue list, plus one read per pending re-run).

**Session cron.** `CronCreate` with `*/15 * * * *` and a prompt that launches this role (or runs the
snapshot inline). Then record it: `"$SCRIPTS/triage-tick.sh" cron --repo <o/r>`. Know its limits:
- it fires only while the REPL is idle, so a long turn delays the tick;
- it dies with the session;
- a recurring session cron expires after 7 days. The snapshot's `cron` line counts down and raises
  `cron-expiring` in the last day; re-create the cron and run `triage-tick.sh cron` again.
For a campaign that must outlive the session, use a cloud scheduled task instead.

**Merge loop wrapper.** A merge loop with a time bound must not stop silently. Write a heartbeat
every iteration and say why it stopped. Keep the script in the state dir, not a session
scratchpad, so the next orchestrator finds and restarts it when this session ends:
`"$SCRIPTS/loops.sh" install merge-loop ./merge-loop.sh`, then run `<state dir>/bin/merge-loop`.
`triage-tick.sh beat` also beats `<state dir>/loops/merge-loop.heartbeat`, which
`loops.sh status` reads at startup; any other loop (tick, review snapshot) calls
`"$SCRIPTS/loops.sh" heartbeat <name> --every <sleep seconds>` once per pass.

```bash
deadline=$(( $(date +%s) + 8 * 3600 ))
while :; do
  "$SCRIPTS/triage-tick.sh" beat --repo "$REPO" --deadline "$deadline" --pid $$
  "$SCRIPTS/merge-queue.sh" run-once --repo "$REPO"   # or one merge-bot pass
  "$SCRIPTS/shipped-blocked.sh" --repo "$REPO" || true   # approved PRs not READY, with the reason (#269)
  if (( $(date +%s) >= deadline )); then
    if [[ "${MERGE_LOOP_RESTART:-0}" == 1 ]]; then deadline=$(( $(date +%s) + 8 * 3600 )); continue; fi
    "$SCRIPTS/triage-tick.sh" beat --repo "$REPO" --end bound
    echo "merge loop: time bound reached; restart it or merges stop" >&2
    break
  fi
  sleep 600
done
```

Restart by itself (`MERGE_LOOP_RESTART=1`) only on the user's word; otherwise it ends with
`beat --end bound`, and the next snapshot reports `merge_loop ended:bound` with the last merge,
so the stop is seen at the next tick. A loop that greps only READY rows out of `pr-ready.sh` must
still print the `shipped-blocked` lines (pass the rows with `--rows FILE` to avoid a second read):
an approved, green PR held back by one unresolved thread is otherwise invisible in its log. A loop that dies without `--end` shows up as `stale` (no beat
for `--loop-stale` seconds, default 1800) or `dead` (its PID is gone).

**Red main from a known flake.** A known flake on `{{BASE}}` holds every merge until the failed job
is re-run. The tick re-runs it (`triage-tick.sh rerun`), notes the re-run on the tracking issue, and
keeps merges held until `{{BASE}}` is green: while the re-run is in progress, `MAIN_RED` stays even
if an older completed run is green. Each run is re-run at most once; a known flake that fails again
is a real red.

**Device slots.** A device lane records its slot type in `lane-claim.sh add --agent <type>:<agent>`
(for example `android:sonnet`); the snapshot counts active lanes per type against
`--device-slots` (or `ORCHESTRATE_DEVICE_SLOTS`).
