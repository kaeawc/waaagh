# Release freeze

A release that verifies a commit and then promotes it fails if the default branch moves in
between. Stopping your own merge loop is not enough: auto-merges armed earlier, by the owner or a
dependency bot, still merge the moment their checks go green (#208: auto-mobile 0.0.92, two bot
PRs merged mid-release, the run had to be redone, about 25 minutes lost). A freeze covers every
merge source.

## Steps

1. **Freeze before dispatching the release.**
   `"$SCRIPTS/freeze.sh" start --repo OWNER/REPO --reason "release 0.0.92"`
   This writes `<state dir>/FREEZE`, so every merge path this plugin owns holds every PR
   (`pr-merge.sh` exit 14, `merge-queue.sh` outcome `held`, both through `orch_hold_of`), then
   sweeps: every open PR with auto-merge armed is disarmed, read back, and recorded in
   `freeze-disarmed` with its merge method, head and who armed it.
2. **Tell the other merge sources.** Any other session or bot that merges (a second orchestrator,
   a merge bot in another session, a scheduled routine) gets a freeze message; confirm it arrived
   (re-read the target's transcript for it; a queued message can expire undelivered). If the repository uses a
   branch-protection merge queue, PRs already in it are not visible over REST and are not
   disarmed: pause the queue in the ruleset or dequeue them before the release.
3. **Keep sweeping until the release finishes.** Run `freeze.sh sweep` right before dispatching
   the release workflow and before every check of its run. A PR armed since the freeze began is
   disarmed and recorded too.
4. **End the freeze when the release is promoted (or abandoned).** `freeze.sh end` re-arms each
   recorded PR that is still open with its own merge method (merged or closed ones are skipped),
   then removes `FREEZE` and merges resume. `freeze.sh status` shows what is recorded.

## When GitHub refuses (exit 6)

GitHub has no REST call that disables or enables auto-merge: both are GraphQL mutations, and
Claude Code cloud sessions are refused GraphQL (HTTP 403, #108). The auto-merge *state* is read
over REST (`auto_merge` on `GET repos/O/R/pulls/N`), so `freeze.sh` can always see what is armed;
only the mutation needs another route. On exit 6 the output names the PRs still armed (or not
re-armed) and the owner action:

- disarm or re-arm them with the GitHub MCP tools (`disable_pr_auto_merge`,
  `enable_pr_auto_merge` with the recorded method), or from a local session; then
- run the same `freeze.sh` command again: it reads each PR back over REST and finds the work done
  (a sweep reports nothing armed; `end` counts an armed PR as re-armed and lifts the freeze).

`end` keeps the freeze while any recorded PR is not re-armed. `end --no-rearm` lifts it anyway and
prints the PRs left for the owner to re-arm.

## Caveats

- A re-arm runs as this session's account, not the one that armed it first; the record keeps the
  original login so the report can say whose PR was touched.
- A bot that merges directly (not through auto-merge) is outside what `freeze.sh` can see. Name it
  in step 2.
