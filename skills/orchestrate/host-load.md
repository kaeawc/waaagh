# Host load: admission, attribution, worktree budget

Read with the "Host load" section of `SKILL.md`. That section covers gates and heavy builds; this
file covers when a new lane may start, what the load is made of, and how many worktrees a host can
carry. Learned on a campaign where the 1-minute load sat at 80 to 130 on a 16-CPU Mac for hours
and no lane was the cause.

## Admission: number and cause

Before starting a lane (and in every tick that wants to refill), run:

```bash
"$SCRIPTS/host-load.sh"          # exit 0 ADMIT, 3 HOLD, 4 BACKOFF
```

`triage-tick.sh snapshot` runs it too: its last line is `host <verdict> cause=<c> ...`, and a
HOLD or BACKOFF turns the `dispatch=<n>` reason into `host-hold`.

- **Admit** only with the 1-minute load below 1.5x the CPU count and at least 8 GB free (free +
  inactive + speculative pages on macOS, `MemAvailable` on Linux).
- **Hold** (exit 3): start nothing new, keep running lanes. **Back off** (exit 4, under 4 GB
  free): start nothing and let running lanes finish before refilling.
- **Device slots:** a third device slot per platform only at 12 GB free or more; the
  `device-slots` row says 2 or 3. Pass it on to `triage-tick.sh --device-slots`.
- A hold is never just a number. Report the `cause` and `hint` rows in the status: the top
  processes by CPU and by RSS, each tied to the worktree it runs in.

## Acting on the cause

| `cause` | What it means | What to do |
|---|---|---|
| `indexing` | `fseventsd` or Spotlight (`mds`, `mds_stores`, `mdworker`) leads, usually churning on many worktrees full of `node_modules` and build output | Shrink the worktree set first (`wt-cleanup.sh --apply`). Then raise an owner blocker: exclude the worktree root from Spotlight (System Settings > Spotlight > Search Privacy). `fseventsd` keeps its memory until a restart, so if its RSS stays high, ask the owner to plan a reboot. Waiting does not fix it. |
| `lanes` | Processes whose working directory is in a lane worktree lead | Hold; check gates go through `gate-slot.sh` and that finished lanes stopped the PIDs they started. The worktree column names the lane. |
| `other` | Something outside the lanes leads (a backup, a browser, an IDE) | Tell the owner what it is. Do not stop it. |

These are owner actions or waits. Nothing in this file kills, renices or quits a process.

## Worktree budget

Every worktree adds files for the indexer and the file-event daemon to watch. Removing 18 finished
worktrees (12 GB) took the load from about 120 to 32 within minutes.

- **Cap live worktrees** by count and size. A starting point for one machine: 30 worktrees or
  60 GB; lower it when `indexing` keeps showing up.
- **Collect finished worktrees every tick**:

  ```bash
  "$SCRIPTS/wt-cleanup.sh" --repo-dir <main checkout> --older-than-hours 2 --pr-closed \
    --max-count 30 --max-gb 60 --apply
  ```

  Finished means: the branch's PRs are all merged or closed, the tree is clean, its HEAD is
  pushed, and it has been idle for 2 hours or more. Exit 3 means the budget is still exceeded after
  collection: start no new worktree until it is back under, and report the budget row.
- Over budget is not a reason to remove an unfinished tree. Finish or close its PR first.

## Never remove a worktree someone is in

A cleanup once removed the worktree a live orchestrator session was using as its working
directory; the session lost its cwd until the directory was recreated. `wt-cleanup.sh` therefore:

- keeps any worktree that is a process's working directory, or contains one (`lsof -d cwd`;
  `/proc/<pid>/cwd` when lsof is missing or its listing does not even include the script's own
  cwd);
- reads the working directories again immediately before each `git worktree remove`;
- removes nothing when neither lsof nor `/proc` can be read;
- never passes `--force`, so git also refuses trees with changes.

A session that must keep its worktree regardless (for example while it sits idle for hours)
locks it: `git worktree lock --reason "<session>" <path>`. Locked worktrees are never removed;
unlock when done. Do not delete worktrees with `rm -rf`; go through the script.
