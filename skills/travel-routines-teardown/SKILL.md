---
name: travel-routines-teardown
description: "Tear down the waaagh traveling-mode cloud routines of a repository: disable them, delete them on claude.ai (the RemoteTrigger tool cannot delete), verify they are gone, clear the record, and optionally remove the labels, briefs and App broker workflow. USE WHEN the user wants to remove, delete, tear down or clean up the traveling-mode routines (orchestrator, worker-implement, worker-repair, worker-review), or one of them."
---

# Tear down the traveling-mode routines

The full reference is `../orchestrate/routines.md` (the "Tear down" section). Read it first.

`SCRIPTS` below is `../orchestrate/scripts`, relative to this skill's base directory.

Deleting a routine is permanent: its run history and its webhook triggers go with it.

- **When to delete.** Delete only the routines the user named: all of a repository's, or one role.
  Before deleting, name them to the user unless the request already did.
- **The confirmation dialog.** On claude.ai, read the dialog before you confirm. It quotes the
  routine's name, and it must match.

## Steps

1. **Find the routines.**
   - Run `"$SCRIPTS/routines.sh" list --repo R` for the recorded ones.
   - Run `RemoteTrigger list` for every routine named `travel: … (R)`.
   - Merge the two lists. If a routine exists but is not recorded, still tear it down. If a
     recorded one is gone, just forget it.
2. **Take the campaign back first.** If the store says `MODE=traveling`
   (`travel-store.sh mode --store <checkout> --repo R`):
   - disable all the routines (step 3);
   - then have the user run `travel.sh exit --repo R --store <checkout> [--runner-var NAME]
     --apply`, or run it yourself if they asked. It refuses while a cloud run holds the lease, so
     wait and retry.
3. **Disable each routine.** Send `RemoteTrigger update <id>` with `{"enabled": false}`, and read
   it back with `get`. This stops new runs at once, even if a deletion stalls.
4. **Delete each routine.** The RemoteTrigger tool has no delete. Use the claude.ai page in a
   browser where the user is signed in. Claude in Chrome usually is; the built-in browser often is
   not.
   1. Open `https://claude.ai/code/routines/<id>`.
   2. Open the menu beside the routine's name ("More options for travel: …"), then choose
      **Delete**.
   3. Check the dialog's routine name, then confirm. The page sends `DELETE /v1/code/triggers/<id>`.

   If no browser is signed in, give the user the links, and continue once they say the routines
   are deleted.
5. **Verify.**
   - `RemoteTrigger list` shows no `travel: … (R)` routine.
   - `RemoteTrigger get <id>` fails for each deleted routine.
   - Run `"$SCRIPTS/routines.sh" forget --repo R --trigger-id ID` for each one.
6. **Optional cleanup.** Do this only if the user asked, and if the repository will not travel
   again:
   - delete the labels: `gh label delete <name> --repo R --yes`, for `cloud-ready`,
     `cloud-dispatch`, `cloud-dispatched`, `cloud-repair` and `cloud-review`;
   - remove `.claude/briefs/` and `.github/workflows/app-broker.yml` by PR;
   - make sure `travel-guard.sh status --repo R` reports off.
7. **Report.** List what was disabled, deleted and verified, and anything left in place.
