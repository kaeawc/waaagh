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
     re-run once: it is a real red now; report it as `main-red`.
   - `rerun-pending`: a re-run is still going; merges stay held. Nothing to do.
   - `main-red` (unclassified, investigate, or a re-run that failed again): report the runs; the
     orchestrator gives the first free lane the fix. File the failure on the tracking issue, or
     append the run and the classifier verdict to it, once per run id.
   - `main-unknown`: change nothing; an existing hold stays.
   - `merge-loop-<state>` (`absent`, `stale`, `dead`, `expired`, `ended`) while PRs are open: the
     merge loop is not running. Report it first; do not restart it yourself (see below).
   - `dispatch=<n>`: report the `next=` issues and the free `slots` by type. New issues without a
     route label go to the router first (`{{SCRIPTS}}/../routing.md`, `roles/router.md`); pass
     `--ready-label cloud-ready` so the queue holds only issues a cloud lane can take.
   - `host-hold` (in place of `dispatch=<n>`): the last line, `host HOLD|BACKOFF cause=<c>
     free_gb=<g> load=<l> limit=<x>`, says this host should start no lane now (`host-load.sh`).
     Report the `dispatch` queue as waiting on the host, with the cause; for `cause=indexing` the
     owner action from `host-load.sh` (fewer worktrees, Spotlight exclusion). `host unknown` (the
     read failed) holds nothing: dispatch is reported as usual.
   - `cron-expiring`: the session cron dies within a day; report it so it is re-created.
   - `resolve-now=<n>`: the `threads` line's `resolve-now=` PRs have every unresolved review
     thread answered (an issue link or a pushed fix in the last reply). They are not repair
     targets: for each, `"{{SCRIPTS}}/thread-sweep.sh" resolve --repo {{REPO}} --pr <n>` (exit 5
     or 9: rerun once). Only `repair=` PRs need a lane. See `{{SCRIPTS}}/../thread-resolution.md`.
   - `hold-stale=<m>`: each `hold-stale #<pr> age=<h>h until:<event> reason=<text>` line is a
     merge-loop hold older than `--hold-hours` (default 12, `ORCHESTRATE_HOLD_STALE_HOURS`), or an
     old-format line of unknown age. Run `"{{SCRIPTS}}/hold.sh" check --repo {{REPO}} --release`:
     it releases every hold whose condition is met, writing the file and `holds.log` together.
     Report the rest with age, condition and reason; `manual` (owner, or an old line with no
     condition) needs the owner or a re-add with `hold.sh add --until <event>`. Never report a hold
     as released unless `hold.sh` printed `released:`.
   - `repaired=<n>`: the `repairs` line's `settled=` PRs had a repair session in flight that has
     now posted its closing comment (`review-ledger.sh settle` recorded `repaired`). Report them:
     each needs a review of its final head before a `ship` verdict lets it merge (#212).
   - `repair-stale=<m>`: each `repair-stale #<pr> session:<id> since:<iso>` line is a repair in
     flight longer than `--hold-hours` with no closing comment. Report it; the orchestrator checks
     the session and, if its run ended, records `review-ledger.sh repaired --pr <pr> --session
     <id>`. Never record `repaired` or `ship` for a repair yourself.
3. Re-run the snapshot only if you wrote something in step 2, and report its verdict line.

## Report (under 150 words)
The final verdict line; stale holds (PR, age, condition, reason) and any released; reruns
requested (run id, issue noted); red runs needing a fix lane; merge loop state with `last_merge`;
dispatch candidates by slot type; anything denied.

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
so the stop is seen at the next tick. A loop that dies without `--end` shows up as `stale` (no beat
for `--loop-stale` seconds, default 1800) or `dead` (its PID is gone).

**Red main from a known flake.** A known flake on `{{BASE}}` holds every merge until the failed job
is re-run. The tick re-runs it (`triage-tick.sh rerun`), notes the re-run on the tracking issue, and
keeps merges held until `{{BASE}}` is green: while the re-run is in progress, `MAIN_RED` stays even
if an older completed run is green. Each run is re-run at most once; a known flake that fails again
is a real red.

**Device slots.** A device lane records its slot type in `lane-claim.sh add --agent <type>:<agent>`
(for example `android:sonnet`); the snapshot counts active lanes per type against
`--device-slots` (or `ORCHESTRATE_DEVICE_SLOTS`).
