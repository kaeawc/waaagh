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

## Lane-private build output

Lanes on one host must never share a build output directory. An iOS lane once failed with a
missing `.pcm` module file: its derived-data path in `/tmp` was shared with other lanes, so it
read another lane's half-built module cache. A shared default looks like a flaky or broken build
and costs a whole lane run to diagnose. So this is not left to each lane's judgment:

- **Every gate gets a lane-private directory.** `gate-slot.sh` and `heavy-build-slot.sh` export
  `ORCHESTRATE_LANE_BUILD_DIR` (`<state dir>/build/<lane id>`; `ORCHESTRATE_BUILD_ROOT` moves the
  root) and point each tool's output into it. The lane id is the worktree's name plus a checksum of
  its path, or `ORCHESTRATE_LANE_ID`. Commands that run outside the gate wrappers do not get it.
- **Defaults ship as data**, in `scripts/build-dirs.tsv`: `TMPDIR` and `XDG_CACHE_HOME` for every
  gate, `-derivedDataPath` for `xcodebuild` (derived data and its module cache), the fastlane
  derived-data variables, and `--project-cache-dir` for Gradle. Gradle's `build/` directories are
  already inside the worktree. An argument the command already passes (an explicit
  `-derivedDataPath`) is kept, with a note on stderr; make sure it is lane-private.
- **Per repo**, put a table at `<state dir>/<owner>__<repo>/build-dirs.tsv` (next to
  `gate-env.sh`). It replaces the defaults, so start from a copy. Rows are
  `MATCH<TAB>KIND<TAB>NAME<TAB>VALUE`. MATCH is `*` or tool names joined by `|`. KIND is `env`
  (export) or `arg` (inserted after the tool word). VALUE may use `{dir}`, `{id}` and `{worktree}`.
  `ORCHESTRATE_BUILD_DIRS=<file>` names another table, and `ORCHESTRATE_BUILD_DIRS=off` turns
  this off. `gate-env.sh` is sourced afterwards and can override any of it.
- A tool reached only inside a `bash -c` string gets the env rows but not the argument rows. Run
  the tool as the gate's own command (`gate-slot.sh -- xcodebuild ...`), or have the build read
  `$ORCHESTRATE_LANE_BUILD_DIR`.
- **Cleanup.** `wt-cleanup.sh` lists a lane's build dir as a `build` row once its worktree is
  gone, whether it removed the worktree or someone else did. With `--apply` it removes the dir,
  unless a process is working inside it. Only directories under the build root that have a
  `.worktree` marker naming a missing path are touched.

## One build per commit for verification lanes

A manual-test round once started four device lanes on the same main commit. Each built its own
copy in its own worktree: two or three built the same Android debug APK, plus the iOS runner. Host
load reached 161 on 16 CPUs, which slowed every lane and the CI runners on the host. Lanes that
verify the same tree need its artifacts once, not once each:

- **Build through `scripts/shared-build.sh`** in verification and device lanes:
  `shared-build.sh --class device --name android-debug --artifact app/build/outputs/apk/debug --
  gate-slot.sh -- ./gradlew assembleDebug`. The last stdout line is
  `shared-build<TAB>built|reused|private<TAB><dir>`; point the test at `<dir>` (an APK path
  override, a prebuilt runner path). `--copy DEST` gives a writable copy for a tool that writes
  next to its inputs.
- **Keyed by tree fingerprint** (`fingerprint.sh`: commit plus any uncommitted diff) and a build
  name: `<state dir>/build/shared/<fingerprint>--<name>`. A lane on another commit, or with local
  changes, builds its own.
- **The first lane builds, under a lock**, into a staging dir, and renames it into place after
  writing the `.done` marker. Later lanes wait (bounded, `--wait`; exit 75) for the marker, then
  reuse the read-only artifacts without running the build. A failed build, a missing `--artifact`
  or a killed builder leaves no marker, so the next lane rebuilds. A lock whose holder died, or
  older than `ORCHESTRATE_SHARED_BUILD_MAX_AGE` (2 h), is broken.
- **Opt-in per class.** `--class` (or `ORCHESTRATE_LANE_CLASS`) names the lane's class; the
  classes in `ORCHESTRATE_BUILD_SHARE` (default `verify device`) share. Implementation lanes
  (`impl`, the default) build into their private lane dir as above, since their trees differ
  anyway. Only artifacts are shared: TMPDIR and tool caches stay lane-private.
- **Cleanup and a disk cap.** After each build, and in `wt-cleanup.sh` as `build` rows, shared
  builds past `ORCHESTRATE_SHARED_BUILD_KEEP` (3, by last use) or `ORCHESTRATE_SHARED_BUILD_MAX_MB`
  (20480) are removed, as are partial builds; the newest and any a process is working inside stay.
  A lane that runs long on a reused build should take `--copy`.
- **Stagger device boots.** Start the build first, then boot devices one at a time rather than
  every emulator at once, through `scripts/boot-slot.sh` (below).

## Device boots are gated on load

Three local lanes once booted simulators within the same minute: a watchOS simulator, an iOS 18
simulator for a runtime matrix, and a foldable. The 1-minute load on a 16-CPU Mac went from about
25 to 235. The device-lane cap (4) was not exceeded: one matrix lane may boot several runtimes, and
each boot starts many CoreSimulator processes, most of them after the boot command has returned.
With ten lanes and one heavy-build slot the load still reached 130 when a boot, a test run and a
build overlapped. The lane count is the wrong unit; booted devices and boots per minute drive it.

- **Every boot goes through `"$SCRIPTS/boot-slot.sh" -- <boot command>`**: one boot at a time on
  the host, started only while the 1-minute load is below 3x the CPU count (48 on 16 CPUs;
  `--load-factor`, `ORCHESTRATE_BOOT_LOAD_FACTOR`), and the slot is kept 30 seconds afterwards
  (`--settle`) so the next boot does not land on this one's start-up. Bounded wait (`--wait`,
  default 900 seconds); exit 75 means it did not start: report it, do not retry in a loop.
- **One booted device per lane.** A matrix over runtimes or devices runs them one at a time,
  shutting each down before booting the next.
- **The gate is in the lane's brief**, not left to the orchestrator noticing a spike
  (`roles/verification.md`, `roles/verify-batch.md`).
- **On a spike, pause lanes; do not abort them.** Message the running device lanes to stop
  starting new boots and builds until `host-load.sh` admits again. An aborted lane loses its booted
  device and its build, and rebuilding both is the load you were trying to shed.

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
