# Owner decisions and closing issues

How a campaign asks the owner things, records the answers, closes issues, and stops lanes whose
issue just closed. `SKILL.md` points here; the scripts are `decision.sh`, `issue-close.sh`,
`campaign.sh close-policy` and `lane-claim.sh`.

## Close policy

When an issue may be closed **as completed** (its work is done) is the owner's rule, and owners
change it mid-campaign. It lives in the campaign ledger, not in memory or a brief:

```bash
"$SCRIPTS/campaign.sh" close-policy                 # prints the policy (owner-only by default)
"$SCRIPTS/campaign.sh" close-policy verified        # the owner changed the rule
```

| Policy | An issue closes as completed when |
|---|---|
| `owner-only` (default) | the owner said yes, recorded on the issue as an owner decision |
| `verified` | the owner said yes, **or** a merged PR covers it and there is device evidence for every platform the change touches |

Every completed close goes through `issue-close.sh --as completed`, which reads the policy and
refuses what it does not allow:

```bash
# owner-only, or any policy once the owner has decided:
"$SCRIPTS/issue-close.sh" --issue N --as completed --pr P --evidence "<what P did, file:line>"
# verified:
"$SCRIPTS/issue-close.sh" --issue N --as completed --pr P --evidence "<what P did>" \
  --platforms android,ios --device "android=<device, OS, build: what was seen>" --device "ios=<...>"
```

`--platforms` names every platform the change touches (`none` when no device-facing code changed);
each needs its own `--device` evidence from a verification or verify batch. When the touched
platforms are wider than the evidence (verified on an emulator, the issue is about hardware), file
the physical-device follow-up issue first, then close the scope that was verified. An issue
labelled `needs-decision` is never closed: decide it first. Closing as already fixed or duplicate
(`--as fixed|duplicate`, the hygiene bot's closes) is evidence that the defect is gone and does not
depend on the policy. Any other close (stale, out of scope, won't fix) is a proposal for the owner.

Read the policy back to the owner when they state a new rule ("close when a merged PR plus device
evidence covers every touched platform" is `verified`), set it, and say so in the next status.

## Decision record

An owner's answer is recorded on its issue, never only in chat or memory:

```text
Owner decision (YYYY-MM-DD): <the decision, in one or two sentences, in the owner's terms>

Owner steps:
- [ ] <a step only the owner can take>
```

```bash
"$SCRIPTS/decision.sh" record --issue N --text "<decision>" [--step "<owner step>"]...
```

`record` posts that comment (date defaults to today, UTC), removes `needs-decision`, ticks the
issue's line in `decisions.md` and logs it in `decisions.log`. A rerun never posts a second copy.
The record is what `issue-close.sh --as completed` accepts as the owner's yes under `owner-only`, so
record only an actual yes-to-close as a closing decision; a "not yet" is recorded too, with the
condition, and the issue stays open.

`decisions.md` keeps one line per open question, with the recommendation in its own field:

```text
- [ ] #N question — option / option — recommend: X — what it blocks
```

## Batched decisions

Never ask pending decisions one by one in chat. When several are open, ask once:

```bash
"$SCRIPTS/decision.sh" batch
```

prints one question: option 1 applies all your recommendations and lists every item with its
recommendation in the option text, so the owner can approve the whole set without opening each;
option 2 goes one at a time; option 3 leaves them. The recommendation comes first. Items without a
recommendation are listed apart and asked one at a time either way. Ask it with the question tool
when one is available, otherwise as one message.

On "apply all", launch one agent (hygiene-bot rights plus `decision.sh record` and
`issue-close.sh --as completed`) that records each decision, files any follow-up issues first (a
physical-device check left after an emulator pass), then closes what the policy now allows, and
returns the owner steps.

## Owner steps

Some decisions need actions only a human can take: creating accounts, adding secrets, granting
access, enrolling devices, paying for a plan. Record each as a `--step` on the decision. Name the
account, the setting and the secret **name**; never a secret value. Collect them for the owner:

```bash
"$SCRIPTS/decision.sh" steps --issues 12,14,30
```

prints one `- [ ] #N step` line per unchecked step. Put that checklist in the report that follows
the decisions, and once more at wrap-up while any is unchecked. Work blocked on an owner step is
not "in progress": label or note it as waiting on the owner.

## Stop lanes on close

A lane working an issue that just closed is wasted work, and it keeps going until told. After
every close:

- `issue-close.sh` prints one `stop: lane WT branch B agent A issue N` line per active lane in
  `lanes.tsv` on that issue. Agents that run it (hygiene bot, local sweep, verify batch, the
  apply-decisions agent) copy those lines into their report.
- Issues also close without `issue-close.sh` (a merged PR's `Fixes #N`, the owner, a bot). After a
  closing sweep, after merges, and on each campaign tick, run
  `"$SCRIPTS/lane-claim.sh" closed`, which reads each active lane's issues and prints the same
  stop lines for closed ones.

For every stop line: send that lane a stop message (the issue is closed; leave the worktree as it
is and report), then `lane-claim.sh set --worktree WT --status closed`. A stop line names the closed issue: a lane
that also covers open issues drops the closed one instead, and stops once all of its issues are
closed or re-planned; say which in the message.
