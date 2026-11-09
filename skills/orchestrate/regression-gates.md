# Regression and device gates

Three gates between "a lane says it is done" and "it is on main and reported". `SKILL.md` points
here from the PR lifecycle, the merge policy and evidence discipline. Learned on the auto-mobile
campaign (2026-11-06/07):

- A merged PR's review findings were resolved after its one review round without asking whether
  any was a regression. One was, and it reached main.
- A manual-test round found two device regressions (Duo inner panel `sendKeys`, `systemTray`).
  The orchestrator said their fix PR "needs no simulator re-check". Only a device run had caught
  the bug, so only a device run could confirm the fix; the PR was held and rechecked on a device.
- The orchestrator reported a PR as merged while it was still open.

## 1. Regression check before resolving review findings

Before any review finding is resolved, filed as a follow-up, or answered "not applicable", ask of
each one: **is this a regression of existing behaviour?** That is, does the PR break something
that worked on the base branch (a caller, a default, an ordering, a platform path), as opposed to a
flaw in new code or a missed improvement?

- **Yes:** hold the PR (no merge, no `follow-up #N`) and fix it on this PR first, even after the
  fix pass is consumed and even in the fast path. This is the one exception to "one review round,
  then follow-up issues" (`review-followup.sh`, `roles/pr-doctor.md`). If the PR cannot be fixed
  in this pass, report it as held with the finding; never merge it.
- **No:** handle it as usual: fix pass, follow-up issue, or a reasoned reply.
- **Unsure:** treat it as yes until a read of the base branch's code path says otherwise.

The reviewer marks every finding `regression: yes|no` with the evidence (`roles/review.md`); the
PR doctor checks the mark before it files or resolves any thread, first round or later.

## 2. Device evidence for fixes of device-found regressions

A PR that fixes a regression found on a device (a manual-test round, a device verification run, a
physical-device report) may merge only after a device run on **its current head** passes. CI, a
unit test or a simulator-free review is not evidence for it; "needs no device re-check" is never
the orchestrator's call for such a PR.

The hold is the `needs-device-recheck` label plus a record in `<state dir>/device-recheck/`
(`scripts/device-recheck.sh`):

```bash
"$SCRIPTS/device-recheck.sh" scan  --repo <o/r> --pr <n>   # when the PR opens or its body changes
"$SCRIPTS/device-recheck.sh" check --repo <o/r> --pr <n>   # before every merge; exit 3 = held
"$SCRIPTS/device-recheck.sh" pass  --repo <o/r> --pr <n> --head <sha> --device "<device/serial>" \
  --evidence "<what ran and passed>"                     # or `fail` with what failed
```

- `scan` holds a PR automatically when its body says `Closes/Fixes/Resolves/Part of #M` and
  issue M carries a manual-test regression label (`manual-test-regression`, `device-regression`;
  `ORCHESTRATE_DEVICE_REGRESSION_LABELS`). Label such issues when the manual-test round files them.
  `hold --reason ... [--issue M]` sets it by hand when the issue lacks the label.
- `check` is read-only and authoritative: held when the label is on, a record is held or failed, a
  linked regression issue has no passing recheck, or the recheck passed on an older head (a push
  after the recheck needs a new one; `scan` re-labels it). An unreadable PR or issue (exit 4)
  counts as held.
- The recheck runs on a device lane (`roles/verification.md`, `device-lock.sh`) built from the
  PR head, not from main. `pass` refuses a head that is not the PR's current head, posts the
  result on the PR and on each linked regression issue, then removes the label. `fail` posts the
  same way and keeps the hold. A rerun after a failed post (exit 5) posts only what is missing.
- The merge loop honours it: `pr-ready.sh --exclude-label needs-device-recheck` keeps labelled
  PRs out of the READY rows, and the merge bot runs `check` before each `pr-merge.sh`
  (`roles/merge-bot.md`), which also catches a head that moved after the recheck.
- A merge-loop hold kept for the recheck goes in the hold file with its release condition:
  `hold.sh add --repo <o/r> --pr <n> --until device-recheck --reason "<what must pass>"`. After
  `pass`, `hold.sh check --release` frees it (or `hold.sh release --pr <n>`), and only that writes
  the release to `holds.log`. A hold whose recheck passed but whose line stayed shows up at the
  next tick as `hold-stale` (#196: a verified fix sat unmerged 33 h behind a released-in-the-log
  hold).

## 3. Delegated reports are claims

Before relaying "merged", "closed", "verified" or "no device check needed" to the owner (tick
report, final report, issue comment), confirm it with one cheap read of the source of truth
(`scripts/claim-check.sh`; exit 0 confirmed, 3 refuted, 4 unverified):

| Claim from a lane or bot | Confirm with |
|---|---|
| PR N merged | `claim-check.sh merged --pr N` |
| issue N closed (as completed / not planned) | `claim-check.sh closed --issue N [--reason completed]` |
| PR or issue still open | `claim-check.sh open --pr N` / `--issue N` |
| verified / evidence posted | `claim-check.sh evidence --pr N --match "<marker or phrase>" [--since ISO]` |
| no device check needed / device verified | `claim-check.sh device-clear --pr N` |

Refuted: report the source's state, not the claim, and fix whatever relied on it (the counters,
the decision queue, the lane's next step). Unverified: say "unconfirmed" and check again next tick;
never relay it as fact. `pr-merge.sh` exit 0 is itself a read of the PR state, so a merge you ran
needs no second check; a merge a lane or bot reports does.
