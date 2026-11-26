# waaagh

A Claude Code plugin that runs a repository's delivery loop with parallel agents: plan from the
issue tracker, implement in isolated lanes, review, merge, and verify what merged.

Every agent is a Claude subagent. Each implementation lane writes its own code and tests in its own
worktree, on Sonnet for routine work and Opus for judgment work; Haiku scouts and validates
independently, one Opus reviewer checks each lane, and the orchestrator commits and pushes.
Merging, branch upkeep, tracker hygiene and post-merge verification run as single-pass roles built
on small, tested `gh` scripts, so the expensive model reads verdict lines instead of raw API output.

## Install

```
/plugin marketplace add kaeawc/waaagh
/plugin install waaagh@waaagh
```

Then ask for it (`/waaagh:orchestrate`, or "orchestrate the open bugs in this repo").

### Update

The plugin sets no `version`, so Claude Code versions an install by commit: every merge to `main`
is an update. Pull it with `/plugin marketplace update waaagh` in a session, or
`claude plugin update waaagh@waaagh` in a shell, then start a new session. Third-party
marketplaces do not auto-update by default; turn it on under `/plugin` → Marketplaces, or with
`autoUpdate` on the marketplace's `extraKnownMarketplaces` entry in your settings.

### Requirements

- `gh` (authenticated), `jq`, `git`; `jj` is supported when the checkout is colocated
- [spectra](https://github.com/kaeawc/spectra) v0.1.2 or newer (`spectra` and `spectra-mcp` on `PATH`; a build from source also counts): every
  host-level check (load and its cause, process attribution, leftover processes, booted devices)
  comes from it, and the plugin registers `spectra-mcp` as an MCP server (`.mcp.json`). It is
  required: a script that needs it stops with a named error when it is missing. Install it with
  `brew install kaeawc/tap/spectra`, or build it from source (`make build`).
- `bats` and `shellcheck` only if you want to run the self-tests

## What is in it

| Path | What |
|---|---|
| `skills/orchestrate/SKILL.md` | The doctrine: roles and routing, isolation, briefs, evidence, the campaign loop, lane cap, merge policy, interrupts, PR lifecycle and takeover |
| `skills/orchestrate/lane-safety.md`, `hooks/hooks.json` | Lane safety contract (deletion scope, no pattern kills, never quit Simulator.app, no writes around the edit hook) and the PreToolUse hook that enforces it |
| `skills/orchestrate/subagent-hygiene.md` | Background subagent hygiene: premise-first, monitor-free, line-budgeted briefs; stop message vs `TaskStop` for closed or noisy lanes; model choice by role |
| `skills/orchestrate/roles/` | Brief templates for the standing roles: merge bot, rebase bot, hygiene bot, local sweep, verify batch, verification, implementation lane, PR doctor, conflict lane, reviewer |
| `skills/orchestrate/host-load.md` | Host load: lane admission thresholds, acting on the load's cause (Spotlight/`fseventsd`, lanes, other), the worktree budget, the `.noindex` worktree root Spotlight skips, never removing a worktree that is a live process's cwd |
| `skills/orchestrate/scripts/` | The scripts below, with stubbed-`gh` self-tests |
| `skills/travel-routines-create/`, `-refine/`, `-teardown/` | Skills to set up, change and remove a repository's four traveling-mode cloud routines (`skills/orchestrate/routines.md`) |
| `actions/app-broker/` | The App broker as a composite action. A repository's `app-broker.yml` (`app-broker.sh workflow`) pins it to the commit of waaagh's newest release tag as `kaeawc/waaagh/actions/app-broker@<sha> # vX.Y.Z`, which the repository's Dependabot bumps (the Release tag workflow cuts a tag when the action changes; `dev/release-tag.sh`), so a cloud session can have the repository's GitHub App post `orchestrate/review` or merge without ever holding the App's key |

### Scripts

| Script | Purpose |
|---|---|
| `pr-ready.sh` | One verdict per open PR: `READY`, `BEHIND` (green but behind a base that requires up-to-date branches), `WAIT`, `BLOCK` (with reasons) or `SKIP`; falls back to smaller pages when the list times out (`PR_READY_EXTRA` names PRs to classify anyway); reads over REST when GraphQL is refused |
| `merge-pass.sh` | One merge pass over the open PRs (#411), the merge bot's steps 2-3 as a script: `main-health.sh` first (red or unknown holds the pass, exit 4), `pr-ready.sh`, then each READY row (`<state dir>/merge-priority` numbers first, then oldest first) through `device-recheck.sh check` and `pr-merge.sh`, reading the rows again after each merge; `<state dir>/serial-groups` (`NAME REGEX` per line: PRs whose title matches merge one per pass), `--cap N` (default 8), `--max-untested N --workflow NAME` (merge only while fewer than N default-branch commits are past the newest green run), `--dry-run`; a `loops.sh heartbeat merge-pass` each pass; `merged`/`hold` lines and a `pass merged= held= ready= cap= untested=` summary |
| `pr-merge.sh` | Merge one PR after re-checking head, author, draft and fork state; honours the red-main hold; refuses a PR in the hold file (exit 14); `--admin` only in the fast path and only with evidence; merges over REST (`PUT pulls/N/merge` bound to the head) when GraphQL is refused |
| `merge-queue.sh` | Serial local merge queue (`add`, `run-once`, `status`, `retry`): merge base in, run the check command, hand off to `pr-merge.sh`; records a per-item outcome (a held PR parks as `held` and resumes on release) and only `merged` satisfies dependents |
| `merge-sensitive.sh` | Which merge-sensitive paths a PR touches, and whether it may merge: its head contains the base, the base moved only outside the protected paths, or a merge-result check passes on base + head; `drift` lists the protected paths main moved over (#204) |
| `review-gate.sh` | The owner's bot-review policy (off, review-at-head, reviewed-once, green-only) enforced by `pr-merge.sh`; Claude Code Review (`claude[bot]`) is the review bot; its budget outages detected and asked once; unreviewed-merges ledger; one `@claude review` request per window across all PRs, gating PRs first |
| `main-health.sh` | Sets or clears the merge hold from the default branch's newest completed runs |
| `ci-backlog.sh` | Sizes the Actions backlog: queued and in-progress jobs by runner label, from runs created inside a window; a run listing alone returns ghosts (runs listed as queued that completed weeks ago) |
| `triage-tick.sh` | One-call snapshot for a recurring triage tick (main health and classifier verdict, open PRs, merge-loop liveness, dispatch queue, free device slots, cron expiry, answered review threads to resolve now, host admission from `host-load.sh`, merge-loop holds past `--hold-hours` with their reasons, drafts with a ship verdict or green checks, marked ready in autonomous mode, ship-verdict PRs that are not READY with the reason) with one verdict line; one known-flake rerun per run (a full rerun, once per head, when a `needs` dependency did not succeed), merge-loop heartbeat |
| `campaign.sh` | Campaign ledger: merge mode, lane cap, merged-since-verification, pause label, `mode` (attended or autonomous; autonomous: the tick marks a reviewed draft ready) |
| `loops.sh` | Long-lived campaign loops installed in `<state dir>/bin/` (never a session scratchpad), a per-pass heartbeat in `<state dir>/loops/`, and the startup status: last pass N min ago, alive/stale/dead/ended/never, exit 3 when a loop is not running and 4 when its script is not installed |
| `counters.sh` | Cumulative campaign counters in the ledger (merged, dispatched, closed, owner blockers; today and campaign total) for the tick report (`skills/orchestrate/reporting.md`) |
| `learning.sh` | Campaign learnings: one file per owner rule or procedural fix, an index in the ledger, `brief --role` for briefs, consolidation (`supersede`, `retire`) and `upstream` of repo-agnostic ones as waaagh issues (`skills/orchestrate/learnings.md`) |
| `issues-ranked.sh` | Open issues updated recently, priority labels and bugs first; `--route` filters to one route for cloud or local dispatch |
| `issue-candidates.sh` | Leads for already-fixed issues and duplicate titles; `sweep` sorts `needs-local:*` issues into A (closeable), B (fix merged, device check left), C (needs implementation) and D (unclear); `--drop-blocked` moves blocked C rows to a `blocked` bucket naming their blockers |
| `verify-on-main.sh` | Open issues whose fix merged in a PR that did not close them ("Part of #N"): `scan --apply` labels them `verify-on-main` (left out of the tick's dispatch count and of routing) unless a result on a default-branch SHA after the fix exists, which makes them `closable` (reported with the link, never closed) or, on FAIL, implementation work again; `batch` groups them by platform label for one verification lane each |
| `issue-close.sh` | Close an issue as fixed or duplicate, with required evidence, and log it |
| `pr-footer.sh` | Strip the harness-added `_Generated by [Claude Code](...)_` footer (and a `---` rule above it) from a cloud PR's body over REST, only when it is there and the sessions' brief says "No attribution" (`--policy auto`, or `strip`/`keep`; `--pattern`); `--cloud` checks every open `work/<N>-auto` PR (#261) |
| `review-followup.sh` | One review round per PR: classify unresolved review threads as first-round, later-round or the author's; file a later-round thread as a follow-up issue (or append it to one with the same root cause), reply `follow-up #N`, resolve it and route the issue `cloud-ready`; after the fix round, classify optional findings (yellow or purple circle, "(optional)") as `optional` and `decline` them: reply with a reason and resolve (#257) |
| `thread-resolve.sh` | Reply once (marker-keyed) on one review thread and resolve it, with readback and typed exits; over REST (`ccr/comments/<id>/resolve`) by the thread's first comment id where GraphQL is refused |
| `thread-sweep.sh` | Find review threads whose last reply links an issue or names a pushed fix or, on an optional finding, declines it (resolve-now vs repair per PR) and resolve them locally; reads over REST (`gh-rest-pr.sh thread-nodes`) when GraphQL is refused; cloud sessions reply but cannot resolve |
| `review-ledger.sh` | Internal review ledger: `record` the orchestrator's own review verdicts (ship, fix-first, rethink), `fix` when a fix pass starts, and `repair`/`repaired`/`settle` for a repair session in flight (no merge and no ship verdict until it ends, #212); the latest non-ship verdict holds the PR on every merge path (`pr-ready.sh` SKIP `review:<verdict>`, `pr-merge.sh` exit 14, `merge-queue.sh` `held`) and in `hold.sh` until `review-ship`; `record --findings` turns a ship whose findings lack the `input-meaning:` line or, when it says `changed`, the callers section into `incomplete` (#211); a `ship` pinned `--head` still counts after GitHub update-branch merges only (`shipped`, `review:stale`, #210); `rounds` counts fix rounds per PR for the tick's `review-loop` line (#257) |
| `shipped-blocked.sh` | Approved PRs the merge loop passes over (#269): every open PR whose latest review verdict is ship but whose `pr-ready.sh` row is not READY, one `shipped-blocked #N verdict=<v> reason=<detail>` line each (e.g. `reason=threads=1`), from a fresh `pr-ready.sh` run or its saved rows (`--rows`); `triage-tick.sh snapshot` lists the same lines with a `shipped-blocked=<n>` reason |
| `hold.sh` | Merge-loop holds: `<pr> until:<event> since:<iso>` lines with machine-checkable release conditions (device recheck, green main, a PR merged, an issue closed, a time, the owner); `check --release` frees the met ones, `release` edits the file and writes the log line together, `stale` names holds past N hours for the tick; `pr-ready.sh` skips held PRs, `pr-merge.sh` and `merge-queue.sh` refuse them |
| `freeze.sh` | Release freeze over every merge source: `start` holds every PR on every merge path and disarms every armed auto-merge (state read over REST, the method logged), `sweep` catches PRs armed since, `end` re-arms them with their own method; exit 6 with the owner action when GitHub refuses the GraphQL-only mutation (`skills/orchestrate/release-freeze.md`) |
| `device-recheck.sh` | Device-recheck hold: a PR that fixes a device-found regression (linked issue labelled `manual-test-regression`) carries `needs-device-recheck` until a device run on its current head passes; posts the result on the PR and each issue |
| `repair-writer.sh` | One writer per PR across cloud sessions (#214): `mark` posts the idempotent `REPAIR-START` marker that `cloud-dispatch.sh record --kind repair` leaves on the PR, which the implement brief checks before every push; `check` (triage tick, `repair-writers=<n>`) flags a PR under repair whose commits since the dispatch carry two writers or whose branch was force-pushed |
| `claim-check.sh` | Confirm a delegated claim (merged, open, closed, evidence comment, no device check needed) with one read of the source of truth before relaying it |
| `branch-idle.sh` | Was a PR's branch written to recently? Reads the newest commit off the base that is not a GitHub update-branch merge, not the head (#242), for "skip recently pushed PRs" guards: `idle`/`active`, last write, age |
| `issue-route.sh` | Exactly one route label per actionable issue (`cloud-ready` or `needs-local:*`): route counts and unrouted/multi-routed issues, label bootstrap, and `set` with the local-work comment and a REST fallback |
| `device-lock.sh` | Exclusive lock for emulators, simulators and attached hardware; token release, PID-reuse detection, `--no-pid`; records the holder's serials or UDIDs and `check`s ownership (AVD suffix, simctl) before device commands |
| `lane-safety.sh` | PreToolUse hook (wired by `hooks/hooks.json`) enforcing the lane safety contract on Bash calls: denies deleting protected or out-of-lane paths, pattern kills, quitting Simulator.app, shell writes outside the lane worktree, and lane writes, mutating git and edit-tool calls in the orchestrator's own checkout (`lane-forbidden`, #218); asks about backgrounded or silenced destructive commands (`skills/orchestrate/lane-safety.md`) |
| `pr-intake.sh`, `pr-claim.sh` | Find and claim your own open PRs across sessions |
| `validate.sh` | Run a validation command into a receipt outside the checkout; `check` says whether an independent, passing receipt for the exact current key can be reused |
| `supersede-check.sh` | Before a conflict repair: SUPERSEDED-CANDIDATE (exit 10) when the PR's issue was closed by another merged PR or its conflict hunks overlap lines later merged PRs added for that issue, with a file/hunk/PR table; read-only |
| `regen-merge.sh` | Merge the base into a branch; conflicts only in generated files are resolved by taking the base and regenerating (verified stable); anything else aborts |
| `lane-claim.sh` | Duplicate-work guard: refuses a lane whose issue or files an active lane or open PR already covers; keeps `lanes.tsv`; `on-issue` / `closed` name the active lanes to stop when their issue closes |
| `decision.sh` | Owner decisions: `record` the "Owner decision (YYYY-MM-DD): ..." comment and clear `needs-decision`, `batch` the open ones into one question with every recommendation listed, `default` takes a stated default instead of a blocking question and queues it, `defaults` lists those for the report, `steps` lists owner-only steps; with `campaign.sh close-policy` and `issue-close.sh --as completed` (`skills/orchestrate/owner-decisions.md`) |
| `relay.sh` | Peer-session relay ledger (`relay.tsv` in the state dir): `send` composes the message with the owner's words quoted verbatim and an ACK/DONE reply contract, `reply` applies a peer's ACK/DONE lines, `say` gives the exact queued / delivered / acknowledged / done wording for the owner, `check` exits 4 on messages past their window (`skills/orchestrate/session-topology.md`) |
| `gate-slot.sh`, `heavy-build-slot.sh` | Host-wide gate semaphore (default 3) with a per-repo gate environment; named exclusive classes (`--class db`, or `gate_class` in `gate-env.sh`) for checks that must never run at once, such as DB-backed suites (#396); Gradle/Xcode builds run alone with capped workers; each lane gets a private build output dir (TMPDIR, XDG cache, Xcode derived data, Gradle project cache) from `build-dirs.tsv` (`_build_dirs.sh`, overridable per repo); bounded waits, stale-holder reclaim |
| `shared-build.sh` | Verification and device lanes on one tree fingerprint build once: the first builds into a commit-keyed shared dir under a lock and writes a completion marker, the others wait (bounded) and reuse the artifacts read-only or as a copy; implementation lanes build privately; pruned to a keep count and size cap (`wt-cleanup.sh` build rows) |
| `update-pace.sh` | Pace CI-starting branch updates (#219): `run --pr N...` calls update-branch in the order given, `gate` / `record` pace other pushers (the merge queue's base merges, the rebase bot); a per-pass cap, a gap between updates and an optional host-load gate (HOLD, BACKOFF or a heavy build defers the rest to the next pass). Off unless `ORCHESTRATE_UPDATE_CAP` / `_GAP` / `_HOST_GATE` are set: set them when CI runs on self-hosted runners on the lanes' host |
| `push-verify.sh` | Push a commit (or SHA) to a branch, then verify with `git ls-remote` that the remote ref equals it; bounded retries, `--no-verify` for slow hooks after your own gates; exit 0 is the only success (#262) |
| `wt-cleanup.sh` | Conservative worktree cleanup: only clean, idle, pushed (confirmed by `ls-remote`), unprotected worktrees no process is in (cwds read again before each removal); squash- or rebase-merged lanes proven merged into the default branch (ancestor, `git cherry`, `merge-tree`, squash patch, merged PR head; a `<subject> (#N)` match is only *likely* and needs `--include-likely`), with the proof in each row; lane build dirs of worktrees that are gone; `--pr-closed`, and a worktree budget (`--max-count`, `--max-gb`, exit 3 over); dry run by default |
| `campaign-gc.sh` | Cleanup of old campaign state (#418), a dry run unless `--apply`: below the campaign's subdirectories, rebuildable build output (`node_modules`, `build`, `DerivedData`, ...), binaries (`.apk`, `.ipa`, `.app`), `.tmp` files and raw captures (`.pcm`, `.hprof`, gzipped rather than removed); never top-level ledgers, learnings, briefs or bin, a candidate with anything newer than `--older-than` (14 days), or an entry a process works in (spectra; `--apply` refuses with exit 5 when spectra cannot tell); per-category counts and sizes, the largest candidates, and every action in `campaign-gc.log` |
| `wt-session-hint.sh` | SessionStart hook (`hooks/hooks.json`): one line, `N merged, M likely merged worktrees`, from a cached `wt-cleanup.sh` dry-run report keyed by the git common dir; a missing or stale (12h) report is refreshed in a detached background process, so the hook costs a `git rev-parse` and a file read (about 20 ms) and never waits on `gh` or `git fetch`; never removes anything |
| `wt-root.sh` | The canonical lane worktree root, `~/worktrees.noindex/<repo>` (Spotlight skips `.noindex`; `WAAAGH_WORKTREE_HOME`, `ORCHESTRATE_WORKTREE_ROOT`): `path [NAME]` for `git worktree add` / `jj workspace add`, and `migrate` (dry run by default) that moves idle trees into it with `git worktree move`, or turns a whole directory into `DIR.noindex` plus a link (`--dir`, also for `.claude/worktrees`) |
| `worktree-guard.sh` | PreToolUse(Bash) hook (`hooks/hooks.json`, on for macOS): denies `git worktree add` / `jj workspace add` outside a `.noindex` directory, the lane root or a temp dir, naming the path to use; a call that names no worktree costs only the shell start |
| `app-broker.sh` | For cloud sessions, which never hold the waaagh-bot App's key: dispatch the `app-broker.yml` workflow to post the App's `orchestrate/review` status on a PR head, or to merge at that head once it is success; `check` reads the status back; `workflow` prints the workflow a repository commits, pinned to the `kaeawc/waaagh/actions/app-broker` composite action (#268) |
| `travel-store.sh` | Traveling mode's state store: `MODE`, the one-writer `LEASE` (take, renew, release; fast-forward-only pushes) and `journal.tsv` per target repository, plus a scan for anything resembling a credential |
| `travel.sh` | The host's traveling-mode toggle: `enter` hands a campaign to the cloud (ledgers into the store after a credential scan, MODE=traveling, self-hosted runner variable off, travel guard on), `exit` takes it back (refuses a live cloud lease, restores ledgers with a backup, guard off, variable restored), `status`; a dry run unless `--apply` |
| `travel-cycle.sh` | One traveling-mode orchestrator pass (what the hourly cloud routine runs): lease, main health, settle, merge through the App broker, review/repair/dispatch labels for the worker routines, hygiene, release; `--dry-run` writes nothing |
| `routines.sh` | The four traveling-mode routines of a repository (`skills/orchestrate/routines.md`): render the `RemoteTrigger` create, update and webhook-trigger bodies from `templates/routines/`, record what was created (`routines.tsv`) for a teardown, and the labels the routines use. The `travel-routines-create`, `-refine` and `-teardown` skills drive it |
| `travel-guard.sh` | On the host, as the owner: turn the "waaagh travel guard" ruleset on for a trip (GitHub then requires the App's `orchestrate/review` on the default branch) and off on return (#268) |
| `host-load.sh` | Lane admission with attribution, read from `spectra load`: ADMIT / HOLD / BACKOFF from 1-min load vs CPUs and free memory, a third device slot only at 12 GB free, top processes by CPU and RSS tied to their worktrees, process families, and the cause (indexing, lanes, CI runner, other, idle) with the owner action (`skills/orchestrate/host-load.md`) |
| `boot-slot.sh` | Runs one simulator or emulator boot through a host-wide gate: one boot at a time, only while the 1-minute load is below 3x the CPU count, with the slot kept for a settle time |
| `gh-read.sh` | Bounded, typed GitHub reads: per-call timeout, backoff inside a time budget, Retry-After and rate-limit reset handling with a cooldown shared by local lanes; refuses writes |
| `gh-issues.sh` | Issue-side list reads (open issues, open and merged PRs) as `gh ... --json` would print them: GraphQL first, REST when GitHub refuses GraphQL (Claude Code cloud sessions), remembered for 12 hours; used by `campaign.sh status`, `issues-ranked.sh`, `issue-candidates.sh`, `issue-route.sh status` |
| `gh-budget.sh`, `gh-shim/gh` | One API pacer for every local caller: per-priority floors (high 150, normal 1000, low 2500), calls spaced until the reset from a shared `/rate_limit` cache, exit 75 to skip a pass, endpoint-scoped backoff for a 403 with headroom; the shim budgets any `gh` call (`ORCHESTRATE_GH_BUDGET=1`) |
| `gh-snapshot.sh` | One GraphQL snapshot per pass of every open PR (head, check roll-up, last review state and commit), cached per head SHA; REST per PR where GraphQL is refused |
| `gh-rest-pr.sh` | REST reads of the PR side in `gh pr list --json` shapes (open list, one PR with mergeable and check roll-up, review threads via `ccr/review_threads` as a count or as thread nodes with their comments, files, last review), used by `pr-ready.sh`, `gh-snapshot.sh` and `lane-claim.sh` when GraphQL answers 403 (cloud sessions) |
| `gh-status.sh` | Read githubstatus.com and name non-operational components; exit 4 while Pull Requests (or a named component) is down, so merges pause instead of failing |
| `job-log.sh` | One Actions job's log via the job-scoped endpoint (works while the workflow still runs), saved per run/attempt/job and excerpted, with explicit not-available outcomes |
| `failure-triage.sh` | Rerun first, reproduce second: re-run a failing PR check once when the classifier can't place it and its domain (`check-domains`) misses the diff, refuse a second rerun on the same head, keep a failure-signature store so the next occurrence is classified, and re-run in full (not `--failed`) a check whose `needs` dependency was abandoned, cancelled or skipped, flagging the runner pool when several PRs hit that within the hour; also treats a package-mirror fetch failure (apt, pip, npm, maven) as infrastructure and reports several PRs hitting it as one outage (`mirror`, `outage`) |
| `bench.sh`, `budget.bats` | Deterministic output-budget benchmarks (bytes, rows, gh calls) and their ceilings; `--timing` adds seconds and jq process counts per case; `bench.sh CASE...` runs only those cases (and the cases they need) |
| `fingerprint.sh`, `excerpt.sh` | Key validation results by tree content, command and declared environment; excerpt long logs |
| `cloud-dispatch.sh` | Cloud dispatch via run-once routines: todo queue and `cloud-sessions.tsv` ledger in the state dir, the short per-issue brief, the `RemoteTrigger create` payload with staggered `run_once_at`, create pacing with 429 backoff, the device-to-cloud fixtures check (`fixtures`, exit 5 when captured fixtures do not travel with the issue), the standard implement/repair briefs kept in the target repo (`briefs install`/`check`, templates in `skills/orchestrate/briefs/`), one-line `--brief-ref` prompts, a blocker check (`payload` exit 8 for a blocked issue, `queue add` warns; `--no-blocker-check`), `created` to keep only the trigger id from a create response, and stale dispatches (`stale` lists dispatches with no PR after `ORCHESTRATE_DISPATCH_STALE_HOURS`, `expire` re-queues one, capped per issue by `ORCHESTRATE_DISPATCH_CAP`), and stalled runs (`stalled --runs FILE` judges a saved `RemoteTrigger list_runs`: silent past `ORCHESTRATE_RUN_STALL_MINUTES`, stopped on a permission prompt, ended with no PR, or never fired; `payload --branch`/`--note` for the redispatch) |
| `stranded-merges.sh` | PRs merged into a stacked base after the base's own PR merged, whose changes never reached the default branch (#410): for each PR merged into a non-default base, the parent PR's merged head must contain its merge commit, else its added files are looked up in the default branch's tree (a same-named file elsewhere counts as moved); `STRANDED`, `RELANDED`, `UNVERIFIED`, `ORPHAN`, `PENDING` or `OK` per PR (exit 3 stranded, 4 unreadable) |
| `open-blockers.sh` | One blocker check before any lane or cloud dispatch: native `blocked by` links plus "Blocked by #N" body lines, each blocker's state looked up; `<n> BLOCKED by #a #b` or `<n> clear` (exit 3 blocked, 4 unreadable); `issues-ranked.sh --drop-blocked` drops blocked candidates and ranks routable blockers in their place; `issue-candidates.sh sweep --drop-blocked` and `cloud-dispatch.sh payload` use it too |

## Defaults

| Setting | Default | Override |
|---|---|---|
| Implementation lanes | 16 when the bots are idle, 12 while one works, 4 during verification; an explicit number from you wins | `ORCHESTRATE_LANES=16,12,4` |
| Verification cadence | every 16 merged PRs | `ORCHESTRATE_VERIFY_EVERY` |
| Merge mode | conservative; fast path above 20 open PRs | `ORCHESTRATE_FAST_PATH_OVER` |
| Admin merges outside the fast path | refused | `ORCHESTRATE_ADMIN_MERGE=1` |
| Pause labels | `orchestrate-pause`, `fleet-pause` | `ORCHESTRATE_PAUSE_LABELS` |
| PR author | the authenticated `gh` user, cached an hour per host in `~/.claude/orchestrate/.author` | `ORCHESTRATE_AUTHOR`, `--author`, `ORCHESTRATE_AUTHOR_TTL` (seconds, 0 = no cache) |
| State directory | `~/.claude/orchestrate/<owner>__<repo>/` | `ORCHESTRATE_STATE_DIR` |
| Implementation lane model | Sonnet for routine, fully specified work; Opus for judgment work | tell the skill |

Repository-specific rules (advisory checks, CI classifier, device rules, forbidden test suites) are
not configured in this plugin. The skill reads them from your Claude memory for that repository
and from `<state dir>/lane-rules.md`.

## Safety properties

- Only PRs authored by the authenticated user (plus authors you name) are merged; fork-head PRs and
  drafts never are.
- A merge is refused when the head moved since it was judged (checked before the merge and bound
  server-side with `--match-head-commit`), and while the default branch is red.
- Admin merges need the fast path (or explicit authorization) and a logged reason.
- The hygiene bot can close issues only as fixed-by-a-merged-PR or duplicate-of-an-open-issue, with
  evidence in the closing comment; every close is logged.
- No role kills processes by pattern, and a device has one owner at a time.
- A PreToolUse hook blocks deleting `~/Library`, the Android SDK, `~/.gradle` and other protected
  roots, pattern kills and quitting Simulator.app; inside a lane worktree it also blocks deletions
  and shell writes outside the lane (`skills/orchestrate/lane-safety.md`).

## Development

```
shellcheck -S warning -x skills/orchestrate/scripts/*.sh skills/orchestrate/scripts/gh-shim/gh dev/*.sh
dev/test.sh                 # every suite, in parallel (-j N); or dev/test.sh path/to/one.bats
dev/test.sh --ignore-sigpipe   # the same with SIGPIPE ignored, as on GitHub's runners
dev/test.sh --bashcov-shellopts   # the same with bashcov's exported errexit/nounset/pipefail (CI runs this)
dev/coverage.sh             # line coverage per script (needs: gem install bashcov)
dev/coverage.sh skills/orchestrate/scripts/job-log.bats   # only these suites: partial numbers, said so
dev/coverage.sh --changed   # only the suites naming scripts changed vs origin/main, then their floors (a lane's check: seconds to a few minutes; a full run is ~20 min)
dev/coverage.sh --check dev/coverage-floor.tsv   # floors vs the last run; CI runs them on main and on PRs that change scripts (coverage.yml)
dev/coverage.sh --shard 2/4  # one shard of the suites, balanced by dev/coverage-weights.tsv; CI runs 4 and merges them
dev/coverage.sh --merge DIR...   # add up shard resultsets into coverage/ and print the table; --weights LOG... refreshes the weights
claude --plugin-dir .
```

Every suite isolates its state under `$BATS_TEST_TMPDIR`, so suites can run in parallel; CI runs
`dev/test.sh -j "$(nproc)" --bashcov-shellopts`. `cli-contract.bats` holds every script to the same command line: `-h`
prints exactly its header comment, and an unknown flag exits 2 before any GitHub call.

## License

MIT. See [LICENSE](LICENSE).
