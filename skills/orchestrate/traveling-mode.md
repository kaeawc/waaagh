# Traveling mode — the campaign runs in the cloud while the owner's host is off

The owner travels with the host closed or offline. The triage tick, review, dispatch and merge
loop keep running, driven by one hourly cloud orchestrator routine. Device lanes and everything
else that needs the host pause until it returns. This file is the contract. The routine prompts
are in `roles/cloud-orchestrator.md`.

## A cloud session cannot start cloud sessions; labels can

A cloud session has no way to create or fire a routine. `/schedule` is documented as unavailable
inside one, and `RemoteTrigger` is a main-session tool: local subagents lack it too
(`roles/cloud-dispatch.md`). So the orchestrator never dispatches. It labels, and each label
starts a worker through that worker routine's own **GitHub event trigger** (#264). No secret is
involved.

- Each worker routine has an `issues` or `pull_request` event trigger on label events.
- Pull-request triggers can be filtered on labels. Issue triggers have no documented filter.
- So every worker's first step is a self-check:
  `Exit at once unless this event added the label <label>`. A run started by any other event
  ends there with no changes.

Caps to plan around:

- The minimum cron interval is 1 hour.
- At most 100 scheduled runs per hour per account.
- At most 30 fires per hour per routine. The owner accepted this cap (#264), so a burst of
  labels beyond 30 in an hour waits for the next pass.
- Runs stop when the account's usage is spent.

## Sessions

| Routine | Trigger | Model | Does |
|---|---|---|---|
| orchestrator | hourly cron | Sonnet | the cycle below; never writes code |
| worker-implement | issue labelled `cloud-dispatch` | Opus | swaps the label for `cloud-dispatched`, then follows the repository's `.claude/briefs/implement.md` |
| worker-repair | PR labelled `cloud-repair` | Opus | `.claude/briefs/repair.md`; removes the label when it ends |
| worker-review | PR labelled `cloud-review` | Sonnet, and never the model that wrote the PR | reviews the labelled head; records the verdict (below); removes the label |

Every routine:

- is created with `clear_mcp_connections: true`;
- has the target repository as a source;
- for the orchestrator only, also has the state store and kaeawc/waaagh as sources, so
  `$SCRIPTS` is the waaagh checkout's `skills/orchestrate/scripts`.

No routine holds a GitHub App credential. A routine acts as the App only by asking the App broker
(below) to act.

Cloud sessions refuse GraphQL, so every call goes over REST. The scripts fall back on their own
(`orch_gh_api`). Merging needs a REST path too (`PUT /repos/{r}/pulls/{n}/merge` with `sha`; `pr-merge.sh` has
none yet, #266). From the cloud, the App broker makes that call.
Threads cannot be resolved from the cloud (`thread-resolution.md`). A PR blocked only on
unresolved threads waits for the host.

## State store contract

The store is a **new private git repository** used only for orchestration state, for example
`kaeawc/orchestrate-state` (#263). It is private because a public target repository must not
carry the decision queue and owner quotes. It uses plain git, with no database and no service.
Its root is a state root:

- set `ORCHESTRATE_STATE_DIR` to the checkout;
- there is **one folder per target repository**, `<owner>__<repo>/`, which is that repository's
  state directory, so `reviews.tsv`, `cloud-sessions.tsv`, `holds` and `decisions.md` live there
  unchanged;
- files of a repository-specific loop that predates these scripts may sit in a subdirectory of
  that folder.

Each repository's folder adds three files, so each target repository has its own lease:

| File | Format | Rule |
|---|---|---|
| `MODE` | `local` or `traveling` | The orchestrator acts only on `traveling`. Only the host's toggle writes it. |
| `LEASE` | `holder=<host\|none\|cloud-run:<id>> expires=<epoch> since=<iso>` | One writer. Details below. |
| `journal.tsv` | `iso<TAB>actor<TAB>action<TAB>detail` | Append-only. Every merge, label, verdict and lease change gets a row. |

How the lease works:

- A run takes it when the holder is `none` or the lease has expired. It commits that change and
  pushes it, and the push must fast-forward.
- If the push is rejected, another writer exists. Stop without acting.
- A run renews the lease before any step that might outlast it, and releases it (`holder=none`)
  as its last push.
- The expiry is longer than one run (90 minutes for an hourly routine), so a crashed run frees
  the lease by the next hour but one.
- Never force-push the store, and never delete its history.

GitHub stays the source of truth for every fact it can hold. The store caches those facts and
keeps only what GitHub cannot:

- dispatched: the `cloud-dispatch` or `cloud-dispatched` label;
- repair in flight: the `cloud-repair` label;
- review verdict: a commit status;
- held: a label or the holds file;
- the ledgers' history, pacing and owner decisions: the store only.

No credential is ever written to the store or to a prompt. A prompt carries issue and PR numbers
and paths, nothing else. The host's toggle refuses to push anything that looks like a token.

## Review verdicts at the exact head

The rule from `roles/review.md` and `review-ledger.sh` still applies: the latest verdict must be
`ship`, recorded at the head being merged.

- **The verdict.** worker-review has the App broker post the commit status `orchestrate/review`
  on the head SHA it read:
  - `success` means ship;
  - `failure` means fix-first or rethink;
  - the description is `<verdict> <head9>: <one line>`;
  - the findings go in one PR comment.
- **Who posts it.** The status is posted as the dedicated GitHub App (#265), through the App
  broker. worker-review never posts it with its own identity. A status on the head whose creator
  is not the App counts as no verdict.
- **Why a status.** A status belongs to its SHA, so a push leaves the new head without a verdict
  and the PR holds. A PR approval from the session cannot carry the verdict. The author and the
  session's reviewer are usually the same GitHub user, and GitHub refuses an author's own approval.
  The App is a distinct identity, so its status can satisfy branch protection.
- **The ledger.** The orchestrator mirrors each status into `reviews.tsv`
  (`review-ledger.sh record --head`), so the other merge paths see the same verdict.
- **Update-branch merges.** The orchestrator may carry a status forward from a reviewed SHA to a
  head whose only later commits are GitHub update-branch merges (`orch_review_covers`). It posts
  the same status on the new head, through the broker, with `carried from <sha9>`.
- **Required status.** Making `orchestrate/review` a required status, with the App as its expected
  source, lets GitHub enforce the rule even against a bug in the orchestrator. Whether the
  ruleset requires it is open (#268).

A PR merges only when all of these hold:

- `pr-ready.sh` says READY, with the campaign's advisory-check list;
- `orchestrate/review` is `success` at the head, or carried as above;
- the latest ledger verdict is `ship`, and no repair is in flight;
- the PR is not held, and main is green (`main-health.sh`);
- the pass is still under the merge cap.

The merge goes in by the head SHA, through REST.

**Who merges.** The dedicated GitHub App merges (#265), never the session's own identity.
Pushes made with Actions' `GITHUB_TOKEN` start no workflows, so a merge made with that token would
skip the default branch's post-merge CI. A merge made with an App installation token does start them.
Check this on one PR before the first trip.

## The App identity and its key

The owner creates the GitHub App, installs it on the target repositories and the store, and holds
its private key. Automation never creates the App, never creates, reads, rotates or stores the
key, and never asks for it. A cloud session never sees the key or an installation token.

**How a cloud session acts as the App: the App broker** (the proposed default, pending the owner's
answer in #268):

- **Where.** A workflow, `app-broker.yml`, runs in the state store repository,
  `on: workflow_dispatch`.
- **The key.** The owner puts the App ID in an Actions variable and the private key in a secret of
  a protected Actions environment.
- **The token.** One step mints an installation token with `actions/create-github-app-token`. It
  is scoped to the one target repository and to `statuses`, `contents` and `pull-requests` write.
  The token lives only inside that job. It is never printed, passed as an output, written to the
  store, or returned to the caller.
- **Inputs.** `op` (`status` or `merge`), `repo`, `pr` and `sha`, plus `state` and `description`
  for `status`.
- **Checks before acting:**
  - `github.actor` is the expected cloud identity;
  - for `merge`, the PR head is still `sha`, and `orchestrate/review` at `sha` is `success` and
    was posted by the App.
- **The call.** The broker then calls `POST /repos/{repo}/statuses/{sha}` or
  `PUT /repos/{repo}/pulls/{pr}/merge` with `sha`.
- **The caller.** A cloud session asks for an action with
  `POST /repos/{store}/actions/workflows/app-broker.yml/dispatches`. It confirms the result on its
  next read of the PR or the status, and never assumes success from the dispatch.

**Open questions (#268), to be answered by the owner:**

- Is the broker in the store, with the key as an environment secret, acceptable?
- Should the ruleset require `orchestrate/review` from the App?
- Can the cloud identity dispatch the store's workflow through the session's GitHub proxy?

Until the owner answers, cloud runs neither merge nor post verdicts. Those PRs wait for the host.

## Hourly cycle

1. **Lease.** Exit unless `MODE=traveling` and the lease can be taken.
2. **Main health.** Run `main-health.sh`. On red, classify the failure (`failure-triage.md`), file
   an issue or append to the open one, and merge nothing.
3. **Settle.** Run `review-ledger.sh settle` and mirror new statuses into the ledger. A worker
   label older than 3 hours with no PR activity is a stalled run: remove the label, journal it,
   and route the issue again next hour, once.
4. **Merge.** Ask the App broker to merge each PR that meets the rule above. Journal each request,
   and journal the merge once the next read confirms it.
5. **Review.** Add `cloud-review` to READY PRs that have no verdict at their head, with a cap per
   pass.
6. **Repair.** Add `cloud-repair` to PRs with a failing required check or a conflict, at most once
   an hour per PR and at most 2 per stack.
7. **Dispatch.** Add `cloud-dispatch` to `cloud-ready` issues that have no PR, branch, ledger row
   or open blocker (`open-blockers.sh`), up to the campaign's busy-worker target.
8. **Hygiene.** Strip attribution lines from PR bodies the workers opened.
9. **Write back.** Push the state and release the lease.

Pace every call with `gh-budget.sh`, using the cloud identity's own quota. On exit 75, skip the
step and do not loop.

## Paused while traveling

These wait for the host and are not rerouted to the cloud:

- `needs-local:*` lanes. The router still labels issues for them.
- Device rechecks, and the PRs they hold.
- Self-hosted runners on the host. Turn off the repository variable that routes CI to them.
- Manual-test rounds and the verification cadence.
- Releases. Keep a freeze on (`freeze.sh`).
- Resolving review threads.
- Kotlin and Gradle repairs that the campaign routes to the host.

Owner questions are queued in `decisions.md` and never block. The stated defaults apply
(`owner-decisions.md`).

## Toggle on the host

One command enters and leaves traveling mode. It does a dry run by default, and it never
force-pushes.

- **enter**, in order:
  1. Refuse while the host's merge loop heartbeat is fresh or a device lock is held.
  2. Scan the state for secrets.
  3. Copy the state into the store and set `MODE=traveling` and `LEASE holder=none`.
  4. Push.
  5. Turn off the self-hosted-runner variable.
  6. Write a local `TRAVELING` marker.
  7. The owner then enables the routines.
- **exit**, in order:
  1. The owner disables the routines first.
  2. Refuse while a cloud run holds an unexpired lease.
  3. Write `LEASE holder=host` and `MODE=local`, and push.
  4. Back up the local copies and copy the store's state back.
  5. Turn the variable on and remove the marker.
  6. Restart the host loops.
- **status** prints the marker, the heartbeat age, held locks, the store's `MODE` and `LEASE`, and
  the variable.

## Failure modes

| Failure | Guard |
|---|---|
| Two writers (the host and the cloud, or two runs) | The lease, fast-forward-only pushes, and exit refusing an unexpired cloud lease |
| A stray event starts a worker | The worker checks its label first and exits |
| A worker hangs and still shows as running | The label-age sweep in step 3; route again once |
| Duplicate dispatch | The orchestrator checks the label, ledger, PR and branch; the worker checks the PR and branch again |
| A stale verdict | The status is bound to its SHA, and merging reads the status at the head |
| A forged verdict | Only a status posted by the App counts. The broker checks the head and the App's status again before it merges |
| The App key leaks | The key stays in the owner's environment secret. No session, prompt or store file ever holds the key or a token |
| Main red | No merges until green |
| Quota spent | `gh-budget.sh` reserves; skip the step |
| A secret in state or a prompt | The toggle's scan; prompts carry numbers only |
| Attribution lines or the skip-CI phrase from a worker | The briefs forbid both. The orchestrator strips attribution, and gives a skip-CI head one empty commit with a normal message |
| Usage spent | Runs stop. The state stays consistent, because every step is journalled and the lease expires |

## Decisions and rejected options

| Question | Decision | Rejected |
|---|---|---|
| State store (#263) | A new private repository, one folder per target repository, plain git with a lease file and fast-forward-only pushes | A branch of the target repository, because a public repository would expose the decision queue |
| How a label starts a worker (#264) | Each worker routine's GitHub event trigger on label events, with the label self-check, and the 30-fires-per-hour cap accepted | An Actions workflow that calls the routine's `/fire` endpoint, because it needs a routine token stored as a secret |
| Merge and verdict identity (#265) | A dedicated GitHub App, created by the owner, who holds its key | The cloud session's own identity, because it is the PR author and cannot satisfy branch protection. Actions' `GITHUB_TOKEN`, because its merges start no workflows |
| How a session acts as the App (#268) | Open. The proposed default is the App broker above | Handing a session the key or a token, because automation never handles the key. A component on the owner's host, because the host is off while traveling |
