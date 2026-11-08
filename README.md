# waaagh

A Claude Code plugin that runs a repository's delivery loop with parallel agents: plan from the
issue tracker, implement in isolated lanes, review, merge, and verify what merged.

Codex lanes write the code (GPT-6 Luna for routine work, GPT-6.1 Sol for judgment work). Claude is a budget: Sonnet drives each lane, Haiku scouts and validates, one Opus reviewer checks each lane. Merging, branch upkeep,
tracker hygiene and post-merge verification run as single-pass roles built on small, tested `gh`
scripts, so the expensive model reads verdict lines instead of raw API output.

## Install

```
/plugin marketplace add kaeawc/waaagh
/plugin install waaagh@waaagh
```

Then ask for it (`/waaagh:orchestrate`, or "orchestrate the open bugs in this repo").

### Requirements

- `gh` (authenticated), `jq`, `git`; `jj` is supported when the checkout is colocated
- the OpenAI [Codex CLI](https://github.com/openai/codex), authenticated, for implementation lanes
- `bats` and `shellcheck` only if you want to run the self-tests

## What is in it

| Path | What |
|---|---|
| `skills/orchestrate/SKILL.md` | The doctrine: roles and routing, isolation, briefs, evidence, the campaign loop, lane cap, merge policy, interrupts, PR lifecycle and takeover |
| `skills/orchestrate/subagent-hygiene.md` | Background subagent hygiene: premise-first, monitor-free, line-budgeted briefs; stop message vs `TaskStop` for closed or noisy lanes; model choice by role |
| `skills/orchestrate/roles/` | Brief templates for the standing roles: merge bot, rebase bot, hygiene bot, local sweep, verify batch, verification, implementation lane, PR doctor, conflict lane, reviewer |
| `skills/orchestrate/scripts/` | The scripts below, with stubbed-`gh` self-tests |
| `agents/codex-implementer.md` | Routine implementation lane (GPT-6 Luna, `medium`): wraps one supervised `codex exec` run and verifies it |
| `agents/sol-implementer.md` | Judgment implementation lane (GPT-6.1 Sol, `medium` or `high`): same runner and checks |
| `bin/codex-lane-run.sh` | Lane runner: spec/worktree identity check, spec snapshot, stall and hard timeouts |
| `bin/codex-lane-start.sh` | Start one lane run: run directory, spec with the worktree header and preamble, detached runner |
| `lanes/codex-lane-reference.md` | What the implementer agents read only off the normal path: exit codes, interrupts, fast tier, why the safeguards exist |
| `bin/codex-lane-wait.sh` | Bounded wait on one run: returns on completion, a semantic progress change, or a small `no-change` |

### Scripts

| Script | Purpose |
|---|---|
| `pr-ready.sh` | One verdict per open PR: `READY`, `WAIT`, `BLOCK` (with reasons) or `SKIP`; falls back to smaller pages when the list times out (`PR_READY_EXTRA` names PRs to classify anyway) |
| `pr-merge.sh` | Merge one PR after re-checking head, author, draft and fork state; honours the red-main hold; `--admin` only in the fast path and only with evidence |
| `merge-queue.sh` | Serial local merge queue (`add`, `run-once`, `status`, `retry`): merge base in, run the check command, hand off to `pr-merge.sh`; records a per-item outcome and only `merged` satisfies dependents |
| `merge-sensitive.sh` | Which merge-sensitive paths a PR touches, and whether it may merge: its head contains the base, or a merge-result check passes on base + head |
| `main-health.sh` | Sets or clears the merge hold from the default branch's newest completed runs |
| `triage-tick.sh` | One-call snapshot for a recurring triage tick (main health and classifier verdict, open PRs, merge-loop liveness, dispatch queue, free device slots, cron expiry, answered review threads to resolve now) with one verdict line; one known-flake rerun per run, merge-loop heartbeat |
| `campaign.sh` | Campaign ledger: merge mode, lane cap, merged-since-verification, pause label |
| `counters.sh` | Cumulative campaign counters in the ledger (merged, dispatched, closed, owner blockers; today and campaign total) for the tick report (`skills/orchestrate/reporting.md`) |
| `learning.sh` | Campaign learnings: one file per owner rule or procedural fix, an index in the ledger, `brief --role` for briefs, consolidation (`supersede`, `retire`) and `upstream` of repo-agnostic ones as waaagh issues (`skills/orchestrate/learnings.md`) |
| `issues-ranked.sh` | Open issues updated recently, priority labels and bugs first; `--route` filters to one route for cloud or local dispatch |
| `issue-candidates.sh` | Leads for already-fixed issues and duplicate titles; `sweep` sorts `needs-local:*` issues into A (closeable), B (fix merged, device check left), C (needs implementation) and D (unclear) |
| `issue-close.sh` | Close an issue as fixed or duplicate, with required evidence, and log it |
| `review-followup.sh` | One review round per PR: classify unresolved review threads as first-round, later-round or the author's; file a later-round thread as a follow-up issue (or append it to one with the same root cause), reply `follow-up #N`, resolve it and route the issue `cloud-ready` |
| `thread-resolve.sh` | Reply once (marker-keyed) on one review thread and resolve it, with readback and typed exits |
| `thread-sweep.sh` | Find review threads whose last reply links an issue or names a pushed fix (resolve-now vs repair per PR) and resolve them locally; cloud sessions reply but cannot resolve |
| `issue-route.sh` | Exactly one route label per actionable issue (`cloud-ready` or `needs-local:*`): route counts and unrouted/multi-routed issues, label bootstrap, and `set` with the local-work comment and a REST fallback |
| `device-lock.sh` | Exclusive lock for emulators, simulators and attached hardware; token release, PID-reuse detection, `--no-pid` |
| `pr-intake.sh`, `pr-claim.sh` | Find and claim your own open PRs across sessions |
| `validate.sh` | Run a validation command into a receipt outside the checkout; `check` says whether an independent, passing receipt for the exact current key can be reused |
| `regen-merge.sh` | Merge the base into a branch; conflicts only in generated files are resolved by taking the base and regenerating (verified stable); anything else aborts |
| `lane-claim.sh` | Duplicate-work guard: refuses a lane whose issue or files an active lane or open PR already covers; keeps `lanes.tsv`; `on-issue` / `closed` name the active lanes to stop when their issue closes |
| `decision.sh` | Owner decisions: `record` the "Owner decision (YYYY-MM-DD): ..." comment and clear `needs-decision`, `batch` the open ones into one question with every recommendation listed, `steps` lists owner-only steps; with `campaign.sh close-policy` and `issue-close.sh --as completed` (`skills/orchestrate/owner-decisions.md`) |
| `gate-slot.sh`, `heavy-build-slot.sh` | Host-wide gate semaphore (default 3) with a per-repo gate environment; Gradle/Xcode builds run alone with capped workers; bounded waits, stale-holder reclaim |
| `wt-cleanup.sh` | Conservative worktree cleanup: only clean, idle, pushed, unprotected worktrees no process is in; dry run by default |
| `gh-read.sh` | Bounded, typed GitHub reads: per-call timeout, backoff inside a time budget, Retry-After and rate-limit reset handling with a cooldown shared by local lanes; refuses writes |
| `gh-status.sh` | Read githubstatus.com and name non-operational components; exit 4 while Pull Requests (or a named component) is down, so merges pause instead of failing |
| `job-log.sh` | One Actions job's log via the job-scoped endpoint (works while the workflow still runs), saved per run/attempt/job and excerpted, with explicit not-available outcomes |
| `usage-report.sh` | Codex usage per model and verified lane status, from per-run receipts (`bin/codex-lane-usage.sh`) |
| `bench.sh`, `budget.bats` | Deterministic output-budget benchmarks (bytes, rows, gh calls) and their ceilings |
| `fingerprint.sh`, `excerpt.sh` | Key validation results by tree content, command and declared environment; excerpt long logs |
| `cloud-dispatch.sh` | Cloud dispatch via run-once routines: todo queue and `cloud-sessions.tsv` ledger in the state dir, the short per-issue brief, the `RemoteTrigger create` payload with staggered `run_once_at`, create pacing with 429 backoff, the device-to-cloud fixtures check (`fixtures`, exit 5 when captured fixtures do not travel with the issue), the standard implement/repair briefs kept in the target repo (`briefs install`/`check`, templates in `skills/orchestrate/briefs/`), one-line `--brief-ref` prompts, and `created` to keep only the trigger id from a create response |

## Defaults

| Setting | Default | Override |
|---|---|---|
| Implementation lanes | 16 when the bots are idle, 12 while one works, 4 during verification; an explicit number from you wins | `ORCHESTRATE_LANES=16,12,4` |
| Verification cadence | every 16 merged PRs | `ORCHESTRATE_VERIFY_EVERY` |
| Merge mode | conservative; fast path above 20 open PRs | `ORCHESTRATE_FAST_PATH_OVER` |
| Admin merges outside the fast path | refused | `ORCHESTRATE_ADMIN_MERGE=1` |
| Pause labels | `orchestrate-pause`, `fleet-pause` | `ORCHESTRATE_PAUSE_LABELS` |
| PR author | the authenticated `gh` user | `ORCHESTRATE_AUTHOR`, `--author` |
| State directory | `~/.claude/orchestrate/<owner>__<repo>/` | `ORCHESTRATE_STATE_DIR` |
| Codex model for the Sol lane | `gpt-6.1-sol` | `CODEX_LANE_SOL_MODEL` |
| Codex model for the routine lane | `gpt-6-luna` | none (fixed in `agents/codex-implementer.md`) |
| Claude implementer fallback | none; a lane with no codex reports `implementer-unavailable` | opt in by telling the skill |

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

## Development

```
shellcheck -S warning -x skills/orchestrate/scripts/*.sh bin/*.sh
bats skills/orchestrate/scripts/*.bats
claude --plugin-dir .
```

## License

MIT. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
