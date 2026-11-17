# Review rounds: one batched fix push, then answer, do not fix (#257)

A bot reviewer that re-reviews every push turns a "no unresolved threads" merge gate into a loop.
In waaagh that reviewer is Claude Code Review (`scripts/review-gate.sh`); elsewhere it may be any
bot. Each push (a thread fix, an update-branch merge) draws a fresh review on the new head, the
review posts a few new optional findings, the next fix push draws another review, and an approved
PR cycles for hours. Seen 2026-11-11: four owner-priority PRs, each looping fix, new threads,
re-review long after their code was approved. These four rules stop it. They are generic: no rule
names a bot.

## 1. One batched fix push per round, with the base merge in it

A fix round is ONE push. Collect every finding the round fixes (all threads, every diff-caused CI
failure), fix them all locally, merge `origin/<base>` into the branch in the same local history
when the branch is behind or conflicting, run the gates once, then push once. Never push a fix and
then the base merge (or press update-branch) as a second push, and never push thread by thread:
every push is a new review round. `roles/pr-doctor.md` (steps 3 to 6) and `briefs/repair.md`
(steps 3 and 6) carry it.

## 2. After one fix round, answer the optional findings and resolve them

The PR has had its fix round once the ledger has a `fixing` or `repairing` row for it
(`review-ledger.sh fix` or a repair dispatch). From then on, a finding the reviewer marked optional
is answered with a reason and resolved, not fixed. Optional markers: Claude Code Review's yellow
circle (nit) and purple circle (pre-existing), the word "(optional)", or a
`severity: nit|optional|pre-existing` HTML comment.

- `review-followup.sh list --pr N` classifies such a thread `optional` (after round 1: a `later`
  thread, or any thread once the fix round happened; `--after-fix` forces it). Before the fix
  round an optional first-round thread stays `first`, so the one fix push may batch it.
- `review-followup.sh decline --pr N --thread ID --reason "<why it can wait>"` replies
  `Optional, not fixed: <reason>` and resolves the thread. It refuses a thread with no optional
  marker: a real defect is fixed (in the one round) or filed (`review-followup.sh file`).
- A cloud repair session cannot resolve (`thread-resolution.md`): it replies
  `Optional, not fixed: <reason>`. `thread-sweep.sh` counts that reply on an optional thread as
  answered (`declined`), so the PR is `resolve-now` and the orchestrator resolves it.
- A regression the PR itself introduces is never optional, whatever its marker
  (`regression-gates.md`).

## 3. Re-review only the delta, at once

When a fix round ends (`repaired=<n>` in the tick, or a local fix pass's report), review the new
head right away, in the same tick, before the bot reviewer posts again: `review-ledger.sh rounds
--pr N` prints `reviewed=`, the head of the newest recorded verdict, so the review reads
`git diff <reviewed>..<new head>` rather than the whole PR. Record it with `review-ledger.sh record
--head <new head>`, so the ship is pinned to that content and a later GitHub update-branch merge
does not invalidate it (`orch_review_covers`, #210).

## 4. A round counter in the tick

`review-ledger.sh rounds` counts each open PR's fix rounds (its `fixing` and `repairing` rows) and
the hours since the first. `triage-tick.sh snapshot` prints `rounds #a=1,#b=3` and one
`review-loop #<pr> rounds=<n> since=<iso> hours=<h> reviewed=<sha>` line per PR at or past
`ORCHESTRATE_REVIEW_ROUND_CAP` (default 2), raising `review-loop=<n>`. A looping PR gets no further
fix round: decline its optional threads (rule 2), file the rest as follow-ups
(`review-followup.sh file`), review the delta (rule 3), and report it if it still cannot merge.
