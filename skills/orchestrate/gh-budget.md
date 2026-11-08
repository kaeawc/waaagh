# GitHub API budget: pacing every local caller

A merge loop, a triage tick, several local lanes and a manual-test round all spend one account's
GitHub budget. `gh-read.sh` makes each read bounded and rate-limit aware, but it does not pace a
fleet: on one campaign the core REST budget hit 0/5,000 mid-afternoon, and for about 45 minutes the
merge loop and triage could not see main health, PR readiness or reviews. These rules keep the
hour's budget lasting the hour.

## One shared pacer

`"$SCRIPTS/gh-budget.sh" run <high|normal|low> -- <gh args>` runs one gh command under the budget.

- It reads `/rate_limit` (free), caches it about 20 s in the state root and shares it with every
  caller on the host. Core, GraphQL and search are tracked separately.
- Each priority spends only down to its floor (for a 5,000-call resource): **high 150** (merges,
  main health), **normal 1000** (ticks, repairs, lanes), **low 2500** (review nudges, backfills,
  sweeps).
- Above the floor, calls are spaced evenly until the reset: min gap = seconds_to_reset / spare.
- Out of budget: high waits for the reset. Normal and low wait at most 60 s, then exit 75 and the
  caller skips the pass. Through `gh-read.sh` that comes back as exit 9 `budget` with `retry-at`.
  Treat it like `rate-limited`: no GitHub work for that priority until `retry-at`, and no retry
  loop.
- `gh-budget.sh status` prints the remaining budget, each floor and any endpoint backoffs.

## Every caller goes through it

- Run loop scripts with `ORCHESTRATE_GH_BUDGET=1`. Sourcing `_lib.sh` then puts the `gh-shim/gh`
  shim first on `PATH`, so every `gh` call is budgeted, including third-party and skill scripts
  nobody edited. The shim drops itself from `PATH` before the real `gh` runs. To budget a loop that
  does not source `_lib.sh`, prepend `skills/orchestrate/scripts/gh-shim` to its `PATH` yourself.
- Each waaagh script that calls GitHub declares its priority with `orch_gh_priority high|normal|low`
  (a test enforces this). Other callers set `GH_BUDGET_PRIORITY`; the default is normal.
- The pacer governs **local callers only**. Cloud sessions use their own GitHub auth and budget.

## Fewer calls per pass

- **One GraphQL snapshot per pass**: `"$SCRIPTS/gh-snapshot.sh"` reads every open PR's head SHA,
  check roll-up, last review state and last review commit in one call per 100 PRs. Use it instead
  of per-PR `gh pr view`, compare and reviews calls. Rows are cached per head SHA: skip per-PR
  work on `cache=same`. `triage-tick.sh snapshot` makes this call once per tick (its `prs` line
  carries the last-review counts), and `review-gate.sh check` reads a fresh row (younger than
  `ORCHESTRATE_SNAPSHOT_TTL`, default 300 s) for the PR's head instead of its own head read, and
  instead of its reviews read when the row shows no review. `bench.sh`/`budget.bats` hold the
  counts (triage tick with 50 open PRs: 6 calls over GraphQL, 206 over REST).
- **Avoid commands that make hidden requests in loops.** `gh run list` also calls
  `GET actions/workflows` to resolve names, and that endpoint can be rate limited on its own while
  `actions/runs` still works. `main-health.sh` reads `actions/runs` directly for this reason. A
  test flags `run list`, `run watch`, `workflow list|view` and `pr checks --watch` in the scripts.

## Endpoint-scoped limits

A rate-limit 403 while `/rate_limit` still shows headroom on that resource is a per-endpoint or
secondary limit. Back off on that endpoint only, never on the whole budget. The pacer does this for
you: it logs `gh-budget: endpoint-limit endpoint=<e> ... retry-at=<iso>` and refuses that endpoint
(exit 75) until then, while other endpoints keep working. With no headroom left, it logs
`gh-budget: exhausted resource=<r> retry-at=<iso>` instead.
