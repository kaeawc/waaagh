# Bot reviews: policy, quota outages and request throttling

Some campaigns merge only after a review bot (Codex, CodeRabbit) has reviewed the PR. Review bots
run out of quota: Codex answers every request with "You have reached your Codex usage limits",
CodeRabbit's free tier allows about one review per 20 to 60 minutes and drops the rest. Then PRs
with green checks pile up, a loop that re-asks every waiting PR hourly mostly gets rate-limit
notices back, and each notice wakes the orchestrator for a turn that changes nothing. `SKILL.md`
points here; the script is `scripts/review-gate.sh`.

## The review policy is the owner's setting

```bash
"$SCRIPTS/review-gate.sh" policy                    # prints it (off unless set)
"$SCRIPTS/review-gate.sh" policy review-at-head --note "owner: merge only after a bot review"
```

| Policy | A PR with a READY row merges when |
|---|---|
| `off` (default) | always: no review gate in the scripts |
| `review-at-head` | a listed bot completed a review of the current head |
| `reviewed-once` | a listed bot completed a review of any head; a never-reviewed PR still waits for one |
| `green-only` | always; every such merge goes into the unreviewed-merges ledger |

Set it only on the owner's word; each change is logged in `decisions.log`. When a policy is set,
`pr-merge.sh` runs `review-gate.sh check` for the exact head and refuses with exit 13 (`needs
review`) when the policy is not met; `merge-queue.sh` keeps that item `waiting`. A merge made
without a review at its head (`green-only`, an exemption) is added to `unreviewed-merges.tsv`.

A review counts when a bot listed in `ORCHESTRATE_REVIEW_BOTS` (default `codex coderabbit`)
submitted it and it is not a quota notice, or when the bot's comment says `Reviewed commit: <sha>`.
A notice that the bot could not review ("usage limits", "rate limited", "review limit") never
counts.

## Detect the outage once, ask the owner once

- **Filter review-bot notices before spending a turn.** For a new PR comment from a review bot,
  pipe its body to `review-gate.sh notice --author <login> --pr N`. `quota <bot> known` needs
  nothing at all: no turn, no reply, no re-request. `quota <bot> new` sets the
  `reviewer-out-of-quota` flag; ask the owner (next step). `bot <bot>` is an ordinary bot comment.
- `review-gate.sh scan --pr N` does the same from a PR's comments and reviews (for a PR you did not
  watch), and clears a bot whose completed review is newer than its last notice (`recovered`).
- **Ask once per outage, not per PR**: `review-gate.sh outage ask --waiting <n>` prints one
  question with the owner's ladder, then marks the outage asked (a rerun prints `already asked`):
  1. green checks only for one urgent PR (`review-gate.sh exempt --pr N --reason ...`), e.g. the
     fix gating a manual-test round;
  2. green checks only for all PRs until reviews return (`policy green-only`), every merge ledgered;
  3. reviewed once is enough (`policy reviewed-once`);
  4. keep waiting, with requests throttled (below).
  Ask it with the question tool when one is available. Record the answer with `policy` or `exempt`
  and say the active policy in the next status.

## When reviews are back

`review-gate.sh outage clear --bot <id>` (or a `scan` that prints `recovered`) ends the outage and
names the unreviewed merges. For each, `review-gate.sh ledger pending` → request a review on the
merged PR through the throttle → `ledger requested --pr N`. Findings on a merged PR become
follow-up issues (`review-followup.sh`), never a revert by default. Return the policy to what the
owner had before the outage (`policy review-at-head`) when they agree; the ladder steps were for
the outage.

## One request throttle per bot, across all PRs

Never re-ask every waiting PR on a timer. Every review request goes through the queue:

```bash
"$SCRIPTS/review-gate.sh" request --bot coderabbit --pr N [--priority high]
"$SCRIPTS/review-gate.sh" request --bot coderabbit          # drain: post the next one if due
"$SCRIPTS/review-gate.sh" request --pr N                    # first listed bot not out of quota
```

At most one request per bot every `ORCHESTRATE_REVIEW_EVERY` seconds (default 1200, i.e. 20
minutes) across all PRs; while the bot is out of quota, one probe every
`ORCHESTRATE_REVIEW_PROBE_EVERY` (default 3600). `--priority high` puts PRs that gate other work
(release blockers, manual-test gates, a red-main fix) ahead of the rest; otherwise oldest first.
`throttled` means the request is queued: do nothing more for it this pass. Requests are logged in
`review-requests.log`. Without `--bot`, an out-of-quota bot is never asked; with every bot out it
prints `out-of-quota all pr=N` and queues nothing.

A PR refused with `pr-merge.sh` exit 13 (`needs review:`) gets exactly one `request --pr N` per
head, never one per pass. `merge-queue.sh run-once` does this itself and records the answer in the
item's outcome detail (`review requested from <bot>`, `review throttled until <iso>`); after a
`throttled`, it only drains that bot's queue (`request --bot <bot>`) on later passes, so the PR
keeps its place. A merge bot outside the queue follows the same rule (`roles/merge-bot.md`).

## State

Under `<state dir>`: `review-policy`, `review-exempt.tsv`, `reviewer-out-of-quota.tsv` (bot,
first seen, last seen, asked), `unreviewed-merges.tsv` (time, PR, head, how, pending|requested),
`review-queue/<bot>.tsv` and `<bot>.last`, `review-requests.log`.
