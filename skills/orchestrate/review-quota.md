# Bot reviews: policy, quota outages and request throttling

Some campaigns merge only after the review bot has reviewed the PR. The review bot is **Claude Code
Review** ([docs](https://code.claude.com/docs/en/code-review)), Anthropic's managed reviewer for
Team and Enterprise organizations, installed as the Claude GitHub App. It posts as `claude[bot]`:
inline findings, a summary in a pull request review, and a check run named `Claude Code Review`.
It is not unlimited. Each review is billed to the organization, and when a monthly spend limit or
the usage-credit balance runs out, Claude skips the review and comments "⚠️ Code review skipped"
instead. Then PRs with green checks pile up, a loop that re-asks every waiting PR hourly mostly
gets more skip notices back, and each notice wakes the orchestrator for a turn that changes
nothing. `SKILL.md` points here; the script is `scripts/review-gate.sh`.

## What the gate assumes, and how to change it

| Fact | Default | Override | Source |
|---|---|---|---|
| Bot login | `claude[bot]` | `ORCHESTRATE_REVIEW_BOT_LOGIN` | GitHub search `reviewed-by:claude[bot]` finds its reviews; the docs name the Claude GitHub App |
| Request phrase | `@claude review` | `ORCHESTRATE_REVIEW_TRIGGER` (empty: never post) | [comment commands](https://code.claude.com/docs/en/code-review-pull-requests#comment-commands) |
| Check run name | `Claude Code Review` | `ORCHESTRATE_REVIEW_CHECK` (empty: never read) | [check run output](https://code.claude.com/docs/en/code-review-pull-requests#check-run-output) |
| Quota notices | "spending cap", "no extra usage", "too low to start another review", "Code review declined" | `ORCHESTRATE_REVIEW_QUOTA_RE` (extended regex, case-insensitive) | [budget messages](https://code.claude.com/docs/en/code-review-troubleshooting) |

`@claude review` starts one review of the whole PR and does not subscribe it to later pushes (since
July 2026; `@claude review always` subscribes, and the gate never posts it). It has to be a new
top-level PR comment from a person with write access: **comments from bots start no review**, so
the `gh` account that posts requests must be a person's (Claude replies with a "No review was
started" tip otherwise). Where the repository runs reviews automatically (after every push, or once
per PR), set `ORCHESTRATE_REVIEW_TRIGGER=` to only wait for them; the throttle and the outage rules
below still apply. If the repository also runs the Claude Code GitHub Action with its default
`@claude` trigger, `@claude review` starts that Action too: give the Action another trigger phrase.

## The review policy is the owner's setting

```bash
"$SCRIPTS/review-gate.sh" policy                    # prints it (off unless set)
"$SCRIPTS/review-gate.sh" policy review-at-head --note "owner: merge only after a bot review"
```

| Policy | A PR with a READY row merges when |
|---|---|
| `off` (default) | always: no review gate in the scripts |
| `review-at-head` | the bot completed a review of the current head |
| `reviewed-once` | the bot completed a review of any head; a never-reviewed PR still waits for one |
| `green-only` | always; every such merge goes into the unreviewed-merges ledger |

Set it only on the owner's word; each change is logged in `decisions.log`. When a policy is set,
`pr-merge.sh` runs `review-gate.sh check` for the exact head and refuses with exit 13 (`needs
review`) when the policy is not met; `merge-queue.sh` keeps that item `waiting`. A merge made
without a review at its head (`green-only`, an exemption) is added to `unreviewed-merges.tsv`.

A review counts when `claude[bot]` submitted it (not pending) and it is not a quota notice. With
no such review at the head, the bot's newest completed `Claude Code Review` check run on the head
counts too, because a review with no findings may leave only a note and the check run. A run titled
`Code review skipped — no new changes` or `Code review not repeated — earlier findings still open`
kept an earlier review's result: it counts as an earlier review (enough for `reviewed-once`, not
for `review-at-head`; request a fresh review for that). A queued, in-progress, declined, failed or
timed-out run, or one the gate cannot read, counts for nothing. A budget notice never counts.

## Detect the outage once, ask the owner once

- **Filter review-bot notices before spending a turn.** For a new PR comment from `claude[bot]`,
  pipe its body to `review-gate.sh notice --author <login> --pr N`. `quota claude known` needs
  nothing at all: no turn, no reply, no re-request. `quota claude new` sets the
  `reviewer-out-of-quota` flag; ask the owner (next step). `bot claude` is an ordinary bot comment
  (a tip, for example).
- `review-gate.sh scan --pr N` does the same from a PR's comments and reviews (for a PR you did not
  watch), and clears the bot when a completed review is newer than its last notice (`recovered`).
- A budget outage ends when an admin restores the budget (at claude.ai/admin-settings/usage) or
  the next billing period starts; nothing on GitHub says so. A failed or timed-out review is not
  an outage: Claude retries an interrupted session once by itself, and one more throttled request
  covers the rest.
- **Ask once per outage, not per PR**: `review-gate.sh outage ask --waiting <n>` prints one
  question with the owner's ladder, then marks the outage asked (a rerun prints `already asked`):
  1. green checks only for one urgent PR (`review-gate.sh exempt --pr N --reason ...`), e.g. the
     fix gating a manual-test round;
  2. green checks only for all PRs until reviews return (`policy green-only`), every merge ledgered;
  3. reviewed once is enough (`policy reviewed-once`);
  4. keep waiting, with requests throttled (below).
  Ask it with the question tool when one is available. Record the answer with `policy` or `exempt`
  and say the active policy in the next status. The owner may also restore the budget instead.

## When reviews are back

`review-gate.sh outage clear --bot claude` (or a `scan` that prints `recovered`) ends the outage
and names the unreviewed merges. For each, `review-gate.sh ledger pending` → request a review on
the merged PR through the throttle → `ledger requested --pr N`. Findings on a merged PR become
follow-up issues (`review-followup.sh`), never a revert by default. Return the policy to what the
owner had before the outage (`policy review-at-head`) when they agree; the ladder steps were for
the outage.

## One request throttle, across all PRs

Never re-ask every waiting PR on a timer. Every review request goes through the queue:

```bash
"$SCRIPTS/review-gate.sh" request --pr N [--priority high]   # queue N; post the next one if due
"$SCRIPTS/review-gate.sh" request --bot claude               # drain: post the next one if due
```

At most one `@claude review` every `ORCHESTRATE_REVIEW_EVERY` seconds (default 1200, i.e. 20
minutes) across all PRs; while the bot is out of quota, one probe every
`ORCHESTRATE_REVIEW_PROBE_EVERY` (default 3600), and only through `--bot claude` (a queued
request). `--priority high` puts PRs that gate other work (release blockers, manual-test gates, a
red-main fix) ahead of the rest; otherwise oldest first. `throttled` means the request is queued:
do nothing more for it this pass. Requests are logged in `review-requests.log`. `request --pr N`
while the bot is out of quota prints `out-of-quota claude pr=N` and queues nothing; with an empty
`ORCHESTRATE_REVIEW_TRIGGER` it prints `not-requested claude pr=N ...`, posts nothing and the PR
waits for an automatic review. Since each review costs money, the throttle is also the spend cap
on what the gate asks for.

A PR refused with `pr-merge.sh` exit 13 (`needs review:`) gets exactly one `request --pr N` per
head, never one per pass. `merge-queue.sh run-once` does this itself and records the answer in the
item's outcome detail (`review requested from claude`, `review throttled until <iso>`, `waiting for
an automatic review from claude`); after a `throttled`, it only drains the queue (`request --bot
claude`) on later passes, so the PR keeps its place. A merge bot outside the queue follows the same
rule (`roles/merge-bot.md`). A draft gets no automatic review, but a requested one does run.

## State

Under `<state dir>`: `review-policy`, `review-exempt.tsv`, `reviewer-out-of-quota.tsv` (bot,
first seen, last seen, asked), `unreviewed-merges.tsv` (time, PR, head, how, pending|requested),
`review-queue/claude.tsv` and `claude.last`, `review-requests.log`.
