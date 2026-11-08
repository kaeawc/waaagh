# Reporting to the owner

How a campaign tells the owner what happened and what it needs from them. `SKILL.md` points here
from the loop's Report step; the counters come from `counters.sh`, the decision queue from
`decision.sh` (`owner-decisions.md`).

## Tick report

Every tick report has the same five parts, in this order, so the owner can scan it the same way
each time: **main health, merges, dispatches, closes, owner blockers.** A part with nothing new is
one word ("none") or left out; the order never changes.

1. **Main health** — `ok`, `red` (what is failing and which lane fixes it) or `unknown`, from
   `main-health.sh` / `campaign.sh status`.
2. **Merges** — PRs merged since the last report (number and title), and any admin merge with its
   evidence.
3. **Dispatches** — lanes started (issue, route, model) and lanes ended without a PR.
4. **Closes** — issues closed, each with how (`fixed`, `duplicate`, `completed` with its owner
   decision or evidence).
5. **Owner blockers** — every open owner-only step, in the format below, newest first.

End with the cumulative line from the ledger, never from recall:
`"$SCRIPTS/counters.sh" show` → "today: 4 merged, 7 dispatched, 3 closed; campaign: 31 merged,
52 dispatched, 18 closed". After a compaction the counters are still right; your memory of the
morning is not.

Before a merge, close or verification goes in the report on a lane's or bot's word, confirm it
with `"$SCRIPTS/claim-check.sh"` (`regression-gates.md`); report the source's state, not the claim.

Keep it short: a status is counts and exceptions, not a log. After the five parts, a wrap-up recap
of two or three sentences says what this turn changed and what happens next.

## Counters

The orchestrator bumps the ledger as each event happens, not when writing the report:

| Event | Command |
|---|---|
| a PR merged | `"$SCRIPTS/counters.sh" bump merged` |
| a lane or cloud session dispatched | `"$SCRIPTS/counters.sh" bump dispatched` |
| an issue closed | `"$SCRIPTS/counters.sh" bump closed` |
| an owner blocker surfaced | `"$SCRIPTS/counters.sh" bump owner_blockers` |

Counts are kept per UTC day (`_today`, restarting on a new day) and for the whole campaign
(`_total`) under `.counters` in `campaign.json`. Other names are allowed (lower case, digits,
underscores) when a campaign tracks more. When a count looks wrong, check it against GitHub
(`gh pr list --state merged --search "merged:>…"`) and say which number you trust.

## Owner blockers

An owner blocker is a step only the owner can take: signing and notarization, a System Settings
approval on a device, console or app registration, a secret only they can create, a paid plan.
Write each one as one line:

```text
**Action** — **where** — **exact names**
```

- **Action**: the verb and the object ("Notarize the provider app with your Developer ID").
- **Where**: the console, settings page, device or file, precise enough to go straight there
  ("System Settings → Privacy & Security → allow the extension, on the test Mac").
- **Exact names**: the secret, variable, bundle ID, app or environment names, spelled exactly as
  the code reads them (`AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` in the `ci` environment;
  `GH_APP_ID`, `GH_APP_PRIVATE_KEY` as repository secrets), and what it unblocks (`#41` device
  verification).

Surface an owner blocker the moment it appears, in the next message to the owner, not batched
until the end of the campaign: the owner can often do it while lanes keep running. Repeat the open
ones in every tick report's last part until the owner says they are done, then drop them. Owner
steps recorded with an owner decision come from `decision.sh steps`.

## Asking the owner

When a choice is the owner's, ask with `AskUserQuestion` (where the client has it) rather than in
prose: one decision per question, the recommendation first and labelled as such, the other options
after it, and what each one blocks. Several open decisions go as one batch (`decision.sh batch`),
still one decision per question. Never bury a question inside a status report; a status may only
point to the question.
