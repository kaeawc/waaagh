# Host load: admission, attribution, worktree budget

Read with the "Host load" section of `SKILL.md`. That section covers gates and heavy builds; this
file covers when a new lane may start, what the load is made of, and how many worktrees a host can
carry. Learned on a campaign where the 1-minute load sat at 80 to 130 on a 16-CPU Mac for hours
and no lane was the cause.

## Admission: number and cause

Before starting a lane (and in every tick that wants to refill), run:

```bash
"$SCRIPTS/host-load.sh"          # exit 0 ADMIT, 3 HOLD, 4 BACKOFF, 5 spectra missing or failed
```

The readings and the attribution come from spectra (`spectra load --json`, required; #330): the
load, CPUs and available memory, what leads the CPU table, the top processes and the process
families (Xcode, simulator, emulator, build tools). The admission rules below are waaagh's.

`triage-tick.sh snapshot` runs it too: its last line is `host <verdict> cause=<c> ...`, and a
HOLD or BACKOFF turns the `dispatch=<n>` reason into `host-hold`.

- **Admit** only with the 1-minute load below 1.5x the CPU count and at least 8 GB free (spectra's
  available memory; when it cannot be read, memory holds nothing).
- **Hold** (exit 3): start nothing new, keep running lanes. **Back off** (exit 4, under 4 GB
  free): start nothing and let running lanes finish before refilling.
- **Device slots:** a third device slot per platform only at 12 GB free or more; the
  `device-slots` row says 2 or 3. Pass it on to `triage-tick.sh --device-slots`.
- A hold is never just a number. Report the `cause` and `hint` rows in the status: the top
  processes by CPU and by RSS, each tied to the worktree it runs in, and the `family` rows.

## Acting on the cause

| `cause` | What it means | What to do |
|---|---|---|
| `indexing` | `fseventsd` or Spotlight (`mds`, `mds_stores`, `mdworker`) leads, usually churning on many worktrees full of `node_modules` and build output | Shrink the worktree set first (`wt-cleanup.sh --apply`). Then raise an owner blocker: exclude the worktree root from Spotlight (System Settings > Spotlight > Search Privacy). `fseventsd` keeps its memory until a restart, so if its RSS stays high, ask the owner to plan a reboot. Waiting does not fix it. |
| `lanes` | Processes whose working directory is in a lane worktree lead | Hold; check gates go through `gate-slot.sh` and that finished lanes stopped the PIDs they started. The worktree column names the lane. |
| `ci-runner` | A self-hosted CI runner on this host leads (spectra's cause once kaeawc/spectra#603 lands; until then it shows as `other` naming the runner's `_work` directory) | Lower the lane cap while it runs; do not look for a runaway lane. |
| `other` | Something outside the lanes leads (a backup, a browser, an IDE) | Tell the owner what it is. Do not stop it. |
| `idle` | Nothing leads the CPU table | The load is falling or was brief: read it again before holding. |

These are owner actions or waits. Nothing in this file kills, renices or quits a process.

## Debugging load and processes with spectra

A HOLD gives a cause and a hint. When the next step is not obvious, ask spectra (required, #329)
instead of reaching for `ps`, `lsof` or `top`. Each CLI command takes `--json`; the MCP tools
(`spectra-mcp`, registered by the plugin) answer the same questions from inside a session. Some
tools are CLI-only until kaeawc/spectra#601 adds them to the MCP server.

| Question | CLI | MCP tool | Then |
|---|---|---|---|
| Who is loading the host, by worktree and family? | `spectra load --root <worktree root>` | (CLI only until spectra#601) | As the cause table above |
| What is one lane's process tree doing? | `spectra lineage <pid>`, `spectra process` | `process` (`tree`, `sample`) | A runaway child the lane started: message the lane to stop that PID |
| Who holds a port, a file or a device path? | `spectra owner :8080`, `spectra owner <path>` | (CLI only until spectra#601) | Another lane's: leave it and pick another port or device |
| Something keeps spawning short-lived processes | `spectra spawns --pid <pid> --duration 10s` | (CLI only until spectra#601) | Name the parent in the report; a lane's retry loop is the lane's to stop |
| A Gradle or Kotlin daemon misbehaving | `spectra jvm` (`gc_stats`, `thread_dump`) | `jvm` | Let it idle out or stop that PID; never `gradle --stop` |
| Memory pressure or swap | `spectra memory` | `memory` | Under the backoff line: start nothing, let lanes finish |
| Out of file descriptors or PTYs | `spectra system` | `system` | Tell the owner; restart nothing yourself |
| How has one PID's memory trended? | `spectra memtrace <pid>` | `metrics`, `process` (`history`; daemon) | Growing without bound: report the lane and PID |
| What is left over after lanes finished? | `spectra orphans --root <worktree root>` | (CLI only until spectra#601) | The tick's `orphans` line (#332): kill nothing yourself |
| What looks wrong at all? | `spectra whatswrong` | `diagnose`, `triage` | Follow its next steps; file a spectra issue when it cannot answer |

Every row ends in one of: pause or message a lane, lower the lane cap, or tell the owner. Spectra
never kills, and neither do you: only a lane stops the PIDs it recorded.

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

## No shared Gradle daemon

Android builds on a host with several lanes once began failing in about 3 seconds with `A problem
occurred starting process 'command .../bin/jlink'` (another lane saw `javap`). The tool ran fine by
hand, and the same build had passed an hour earlier. A Gradle daemon outlives the command that
started it and is reused by every later compatible build on the host, from any lane. This one had
been started inside a lane's sandboxed shell, or on a Homebrew JDK that a `brew upgrade` then
removed, so every build that reconnected to it inherited a broken process environment.

- **`heavy-build-slot.sh` adds `-Dorg.gradle.daemon=false` to `GRADLE_OPTS`**, so a build through
  the gate wrappers starts no daemon that outlives it. `HEAVY_BUILD_GRADLE_DAEMON=1`, or a
  `GRADLE_OPTS` that already sets `org.gradle.daemon`, keeps the caller's choice. One heavy build
  runs at a time, so a warm daemon would save little.
- **A Gradle run outside the wrappers passes `--no-daemon`**, and points `JAVA_HOME` or the
  toolchain at a JDK path that survives upgrades (not a versioned Homebrew Cellar path).
- **A build that fails in seconds with "problem occurred starting process" for a JDK tool** is a
  stale daemon, not the change: re-run it once through the gate (or with `--no-daemon`) before
  reading the code. When a Gradle command fails through `heavy-build-slot.sh`, it asks spectra
  (`spectra jvm --json`) and names any Gradle or Kotlin daemon whose JDK is gone, with its PID and
  missing `java.home` (#335). The Kotlin compile daemon is reused even by a Gradle run with no
  daemon of its own, so this can still happen inside the gate. Outside the gate, run
  `spectra jvm` yourself, or `spectra rules` for the `build-daemon-jdk-gone` finding.
- **Never stop daemons to fix it.** `./gradlew --stop` stops every compatible daemon on the host,
  other lanes' running builds included; the lane-safety hook refuses it in a lane. An idle daemon
  times out by itself.

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
- **It also counts devices** (spectra's `devices` block, kaeawc/spectra#602, read through
  `host-load.sh`'s `devices` rows): a boot waits while the host has 4 or more devices booted
  (`--max-booted`, `ORCHESTRATE_BOOT_MAX_BOOTED`) or 3 or more booted in the last 5 minutes
  (`--max-boots`, `ORCHESTRATE_BOOT_MAX_RECENT`), as well as while the load is high (#334).
- **One booted device per lane.** A matrix over runtimes or devices runs them one at a time,
  shutting each down before booting the next. `boot-slot.sh` says so when the lane's own worktree
  already has a device booted.
- **The gate is in the lane's brief**, not left to the orchestrator noticing a spike
  (`roles/verification.md`, `roles/verify-batch.md`).
- **On a spike, pause lanes; do not abort them.** Message the running device lanes to stop
  starting new boots and builds until `host-load.sh` admits again. An aborted lane loses its booted
  device and its build, and rebuilding both is the load you were trying to shed.

## Never remove a worktree someone is in

A cleanup once removed the worktree a live orchestrator session was using as its working
directory; the session lost its cwd until the directory was recreated. `wt-cleanup.sh` therefore:

- keeps any worktree that is a process's working directory, or contains one, as spectra reports
  it (`spectra owner --under <worktrees> <build root>`, #331);
- asks again for that one tree immediately before each `git worktree remove`;
- removes nothing when spectra cannot answer (missing, too old for `--under`, or failing).
  Spectra's "none visible, some processes unreadable" (other users' processes) counts as none:
  only this user's processes work in this user's worktrees;
- never passes `--force`, so git also refuses trees with changes.

A session that must keep its worktree regardless (for example while it sits idle for hours)
locks it: `git worktree lock --reason "<session>" <path>`. Locked worktrees are never removed;
unlock when done. Do not delete worktrees with `rm -rf`; go through the script.
