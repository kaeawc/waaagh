---
name: travel-routines-create
description: "Create the four waaagh traveling-mode cloud routines (orchestrator, worker-implement, worker-repair, worker-review) for one or more GitHub repositories, disabled, with their GitHub webhook triggers, after checking or installing what they need: the GitHub App and its secrets, the App broker workflow (the kaeawc/waaagh actions/app-broker composite action), the briefs, the labels, the state store and a cloud environment. USE WHEN the user wants to set up traveling mode, cloud routines or the cloud orchestrator for a repository, or to recreate routines that were torn down."
---

# Create the traveling-mode routines

The full reference is `../orchestrate/routines.md`. Read it first. Also read
`../orchestrate/traveling-mode.md` if you have not read it in this session.

`SCRIPTS` below is `../orchestrate/scripts`, relative to this skill's base directory. Run every
`gh` command as the owner. If the waaagh gh shim is installed, set `WAAAGH_GH_SHIM=off`.

## Rules

- Create routines **disabled**. Never enable, run or fire one from this skill. Enabling belongs to
  the owner, after `travel.sh enter --apply`.
- Never ask for, print or handle the App's private key or a token. The App acts only through the
  broker workflow.
- Commit changes to a target repository (the broker workflow, the briefs) through a PR, never
  straight to its default branch.
- Record every routine you create, right away, before you create the next one.

## Steps

1. **Repositories.** Confirm with the user which `owner/repo`s to set up, and which minute each
   orchestrator runs at: different minutes, e.g. 7 and 37.
2. **Existing routines.** Run `RemoteTrigger list`. For each repository, look for routines named
   `travel: … (owner/repo)` and for rows in `"$SCRIPTS/routines.sh" list --repo R`. If some exist,
   stop and ask the user: refine them (`travel-routines-refine`), or tear them down first
   (`travel-routines-teardown`).
3. **Prerequisites.** Check items 1–6 under "Create" in `routines.md` for each repository. Fix the
   ones you can:
   - The labels: `routines.sh labels --repo R --apply`.
   - The broker workflow: open a PR with `"$SCRIPTS/app-broker.sh" workflow` as
     `.github/workflows/app-broker.yml`. In the same PR, add a `github-actions` entry to
     `.github/dependabot.yml` if it has none, so each waaagh release tag reaches the pin as a bump PR.
   - The briefs: `cloud-dispatch.sh briefs install --gates "<gates>"` in a checkout, then a PR. Ask
     the user for the gate commands if `CLAUDE.md` does not name them.
   - The cloud environment: take its ID from an existing routine's
     `job_config.ccr.environment_id`, or ask the user.

   Stop and ask the user about what only they can do: installing the GitHub App, its secrets,
   creating the private state store, creating a cloud environment.
4. **Create.** For each repository and each role in `routines.sh roles` (orchestrator first):
   - `"$SCRIPTS/routines.sh" render --role ROLE --repo R --env ENV [--minute M]`. Add
     `[--store S] [--waaagh W] [--model M]` only if the user asked.
   - Send the printed JSON with `RemoteTrigger create`. Take `trigger.id` from the response.
   - `"$SCRIPTS/routines.sh" record --role ROLE --repo R --trigger-id ID`.
   - For a worker role: send `"$SCRIPTS/routines.sh" hook --role ROLE --repo R --trigger-id ID`
     with `RemoteTrigger create_webhook_trigger`.
5. **Check.**
   - `RemoteTrigger get` each ID: `enabled` is false, and the prompt names the right repository.
   - Run the dry pass from `routines.md`: `travel-cycle.sh run --dry-run` against a throwaway store
     set to traveling.
6. **Report.** For each repository, give:
   - the routine names, their IDs and claude.ai links (`https://claude.ai/code/routines/<id>`);
   - that the routines are disabled;
   - the commands to start traveling: `travel.sh enter --repo R... --store <checkout> --app-id N
     [--runner-var NAME] --apply`, then `RemoteTrigger update {"enabled": true}` for each routine;
   - and to come back: disable the routines, then run `travel.sh exit ... --apply`.
