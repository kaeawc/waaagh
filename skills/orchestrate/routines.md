# Traveling-mode routines: create, refine, tear down

Traveling mode (`traveling-mode.md`) runs a repository's delivery loop from Claude Code cloud
routines while the owner's host is off. Each repository has four routines:

| Role | Trigger | Model | Sources | What it does |
|---|---|---|---|---|
| orchestrator | hourly, `M * * * *` | Sonnet | the repo, the state store, waaagh | one `travel-cycle.sh run` pass: lease, main health, settle, merge through the App broker, label work for the workers, journal |
| worker-implement | GitHub `issues` events | Opus | the repo | an issue labelled `cloud-dispatch`: implement it per `.claude/briefs/implement.md` |
| worker-repair | `pull_request` events, label `cloud-repair` | Opus | the repo | repair the PR per `.claude/briefs/repair.md` |
| worker-review | `pull_request` events, label `cloud-review` | Sonnet | the repo, waaagh | review the head SHA, then have the App broker post `orchestrate/review` |

Each prompt lives in `templates/routines/<role>.txt`, which is the only copy. `{{REPO}}`, `{{STORE}}`
and `{{WAAAGH}}` are filled in by `scripts/routines.sh render`. `roles/cloud-orchestrator.md`
explains the rules the prompts follow.

Three skills in this plugin run the procedures below:

- `travel-routines-create`
- `travel-routines-refine`
- `travel-routines-teardown`

## Ground rules

- **Routines stay disabled while the owner is home.**
  - Creating one never enables it.
  - Enabling happens only after `travel.sh enter --apply`.
  - Disabling happens before `travel.sh exit --apply`.
- **No routine holds a key or a token.** A routine acts as the GitHub App only through the App
  broker workflow in its repository (`templates/app-broker.yml` and `actions/app-broker`).
- **Every routine is recorded.**
  - `routines.sh record` writes it to `routines.tsv` in the repository's state dir
    (`~/.claude/orchestrate/<owner>__<repo>/`).
  - A teardown deletes what is recorded there, plus anything listed under a `travel: ` name.
- **The session sends the bodies.** `routines.sh` only prints them. The session sends each body
  with the RemoteTrigger tool and records the ID it gets back.

## What the RemoteTrigger API can and cannot do

Checked on 2026-11-21.

| Need | How |
|---|---|
| Create | `RemoteTrigger create` with `routines.sh render`'s body. The response's `trigger.id` (`trig_…`) is the routine |
| Wire a worker to GitHub | `RemoteTrigger create_webhook_trigger` with `routines.sh hook`'s body: `{routine_trigger_id, hook_type: "app", source: "github", scope_id: "owner/repo", events: [...], filter: {labels: [...]}}`. Other shapes are refused (`scope: {repository}`, `events: ["issues.labeled"]`, `filter: {label}`). The `labels` filter is accepted but not echoed back, so treat it as unverified until [Check the label filter](#check-the-label-filter-361) records a result: every worker prompt checks its own label first and exits on any other event. `implement` has no filter (`issues` events), on purpose |
| Change a prompt, model, sources or schedule | `RemoteTrigger update` with `routines.sh render --update`'s body, a partial update that never touches `name` or `enabled` |
| Enable or disable | `RemoteTrigger update` with `{"enabled": true}` or `{"enabled": false}` |
| Delete | **Not in the tool.** The claude.ai page deletes a routine with `DELETE /v1/code/triggers/<id>`: open `https://claude.ai/code/routines/<id>`, open the menu beside the routine's name, choose **Delete**, then confirm. This deletes its webhook triggers and run history too. A session can do this in a browser where the owner is signed in to claude.ai (Claude in Chrome), or the owner does it |
| Check the result | `RemoteTrigger list` (no routine named `travel: … (<repo>)` remains), `get <id>` (404 once it is deleted), `list_runs` and `get_run_log` to debug a run |

## Create

Prerequisites, per target repository. Check each one, and fix any that is missing first.

1. **The GitHub App** (waaagh-bot, or the owner's own) is installed on the repository, with these
   permissions:
   - Contents: write
   - Pull requests: write
   - Commit statuses: write

   The repository has the secrets `GH_APP_ID` and `GH_APP_PRIVATE_KEY`.
2. **The App broker workflow.** Commit the output of `scripts/app-broker.sh workflow` as
   `.github/workflows/app-broker.yml`, through a PR, on the default branch. It pins
   `kaeawc/waaagh/actions/app-broker` to the commit of waaagh's newest release tag
   (`@<sha> # vX.Y.Z`). Give the repository a Dependabot `github-actions` entry, so each new
   waaagh release reaches it as a bump PR (#359). If the repository limits which Actions may
   run, allow `kaeawc/waaagh/actions/app-broker@*`. Optionally, the repository variable
   `APP_BROKER_ACTORS` lists who may start the broker; it defaults to the owner.
3. **The briefs.** Install them with `scripts/cloud-dispatch.sh briefs install --gates "<the repo's
   gate commands>"`, then commit `.claude/briefs/implement.md` and `repair.md` through a PR.
4. **The labels.** Run `scripts/routines.sh labels --repo R --apply`.
5. **The state store.**
   - A private repository, `<owner>/orchestrate-state` by default.
   - Every routine's GitHub access must reach it.
   - Check its folder with `travel-store.sh mode --store <checkout> --repo R`.
6. **A cloud environment** (`env_…`).
   - Look at `RemoteTrigger list`: an existing routine's `job_config.ccr.environment_id` shows which
     environment it uses.
   - The routines need network access to GitHub and the toolchain the briefs' gates run.
   - If no environment fits, the owner creates one on claude.ai and gives you its ID.

Then, for each repository:

```
routines.sh render --role orchestrator --repo R --env ENV --minute M   # pick a minute per repo, e.g. 7 and 37
  → RemoteTrigger create (body) → id → routines.sh record --role orchestrator --repo R --trigger-id ID
for role in implement repair review:
  routines.sh render --role $role --repo R --env ENV
    → RemoteTrigger create → id → routines.sh record --role $role --repo R --trigger-id ID
  routines.sh hook --role $role --repo R --trigger-id ID → RemoteTrigger create_webhook_trigger
```

Leave all of them disabled. Finish by running a dry pass against a throwaway store set to
traveling. The live repository is read, and nothing is written:

```
git init -q -b main /tmp/drystore && git -C /tmp/drystore commit -q --allow-empty -m init
mkdir -p /tmp/drystore/<owner>__<repo> && echo traveling >/tmp/drystore/<owner>__<repo>/MODE
git -C /tmp/drystore add -A && git -C /tmp/drystore commit -qm mode
scripts/travel-cycle.sh run --repo R --store /tmp/drystore --holder dry-run --dry-run
```

To go traveling, run `travel.sh enter --repo R... --store <store checkout> --app-id N
[--runner-var NAME] --apply`. Then send `RemoteTrigger update {"enabled": true}` to each recorded
routine.

## Refine

1. Edit `templates/routines/<role>.txt` (or the model, sources or schedule rules in `routines.sh`)
   through a waaagh PR, so every repository gets the change.
2. For each recorded routine of that role (`routines.sh list --repo R`):
   - render the update body: `routines.sh render --role ROLE --repo R --env ENV [--minute M]
     --update`;
   - send it with `RemoteTrigger update`;
   - read it back with `RemoteTrigger get`.
3. A trigger change (events, filter) cannot be updated in place. Tear that worker down and create
   it again.
4. To check a change, use `RemoteTrigger run <id>` on a disabled routine. For the orchestrator, do
   this only while the store says `MODE=local`, so the pass skips. Then read the run with
   `list_runs` and `get_run_log`.

## Tear down

1. If the store says `MODE=traveling`, disable the routines first. Then run `travel.sh exit ...
   --apply` to take the campaign back.
2. Disable every recorded routine with `RemoteTrigger update {"enabled": false}`. This takes effect
   at once, even if a deletion then stalls.
3. Delete each routine on claude.ai (the table above). Check each confirmation dialog: it names the
   routine it deletes.
4. Check with `RemoteTrigger list` that no `travel: … (R)` routine remains. Then run
   `routines.sh forget --repo R --trigger-id ID` for each one.
5. Optional: remove the labels, the briefs and the broker workflow from the repository, by PR for
   the files. Keep them if the repository may travel again.

## Check the label filter (#361)

Does `filter: {labels: ["cloud-review"]}` stop a worker firing on every `pull_request` event? If
it does not, each event (opened, synchronize, labeled, ...) costs a worker start that exits at its
label check, and counts toward the routine's hourly cap of GitHub events. The docs say the Labels
filter matches "Labels applied to the PR", the PR's labels at the time of the event, not only the
label just added
([Add a GitHub trigger](https://code.claude.com/docs/en/routines#add-a-github-trigger)). If so, a
push to a PR that still carries the label fires it too. Step 7 measures that.

Run this from a Claude Code session on the owner's account, where `RemoteTrigger list` works. A
Hive worker session gets `Remote triggers unavailable: essential-traffic-only` (2026-11-25).
`SCRIPTS` is `skills/orchestrate/scripts`. Wait about a minute after each GitHub step, so the
events stay separate and each run can be matched to its step.

1. **A test repository** `T` (`owner/name`) that the Claude GitHub App is installed on, with
   webhook delivery on. A throwaway repository is best: the worker will review a PR there. It needs
   the labels (`"$SCRIPTS/routines.sh" labels --repo T --apply`) plus one other label, e.g.
   `gh label create other --repo T`. It needs no broker workflow, briefs or state store.
2. **Create one worker-review routine**, as `travel-routines-create` does, for this role only:
   - `"$SCRIPTS/routines.sh" render --role review --repo T --env ENV`, then send it with
     `RemoteTrigger create`. Note `trigger.id` as `ID`, then run
     `"$SCRIPTS/routines.sh" record --role review --repo T --trigger-id ID`.
   - `"$SCRIPTS/routines.sh" hook --role review --repo T --trigger-id ID`, then send it with
     `RemoteTrigger create_webhook_trigger`. This body, filter included, is what gets tested.
   - `RemoteTrigger update ID {"enabled": true}`. A disabled routine does not fire, so this check is
     the one place a routine is enabled outside a trip. Step 8 disables it.
3. **Open a PR without the label** (`opened`):

   ```
   gh repo clone T /tmp/lf && cd /tmp/lf && git switch -c lf-check
   date >lf.txt && git add lf.txt && git commit -m "label filter check"
   git push -u origin lf-check
   gh pr create --repo T --fill
   ```
4. **Push to it** (`synchronize`): `date >>lf.txt && git commit -am push && git push`.
5. **Add another label** (`labeled`, not ours): `gh pr edit lf-check --repo T --add-label other`.
6. **Add `cloud-review`** (`labeled`, ours):
   `gh pr edit lf-check --repo T --add-label cloud-review`. Wait until `RemoteTrigger list_runs ID`
   shows a run for it.
7. **Push while the PR carries `cloud-review`** (`synchronize`, labelled):
   `gh pr view lf-check --repo T --json labels` must list `cloud-review`. If the review run
   removed it, add it again and wait for that run first. Then
   `date >>lf.txt && git commit -am push2 && git push`.
8. **Read the runs, then tear down.** `RemoteTrigger list_runs ID`, then `get_run_log` on each run:
   its prompt shows the event that fired it. Then `RemoteTrigger update ID {"enabled": false}`,
   delete the routine on claude.ai (`travel-routines-teardown`),
   `"$SCRIPTS/routines.sh" forget --repo T --trigger-id ID`, and close the PR.

`list_runs` lists only fires that created a session, which is exactly the cost in question. Read
which steps got a run:

| Steps 3, 4, 5 | Step 6 (and any re-add) | Step 7 | Reading |
|---|---|---|---|
| none | one each | none | the filter applies to the label just added |
| none | one each | one | the filter applies to the PR's labels: a push to a labelled PR fires the worker |
| one each | one each | one | the filter is ignored: every `pull_request` event fires the worker |
| none | none | none | nothing fired: check webhook delivery and that the routine is enabled |

Post which steps got a run, and each run's event, on #361. Then add a dated line under
[Record](#record), and update the "Wire a worker to GitHub" cell above.

If the filter is ignored, decide one of these:
- narrow the event, e.g. `events: ["pull_request.labeled"]` if the API takes it (the refusal list
  above names only `issues.labeled`), then do steps 2–8 again with that body;
- or accept the cost: each worker fire exits at its label check.

If the filter applies to the PR's labels, a worker also fires on every push made while its label
is on, e.g. repair's own pushes before it removes `cloud-repair`. Those runs exit at the prompt's
label check, but each one counts toward the hourly cap.

## Record

- **2026-11-21.** Created disabled, for kaeawc/auto-mobile (minute 7) and kaeawc/spectra
  (minute 37), in the environment `env_016tduca82jMQhAUAe2yekM9`. Every create body is
  reproduced byte for byte by `routines.sh render` (the uuid aside).
- **2026-11-21, later.** All eight routines were torn down through the claude.ai page as a teardown
  exercise. Each deletion was a `DELETE /v1/code/triggers/<id>` that returned 200, and
  `RemoteTrigger list` then showed no `travel:` routine.
- **2026-11-25.** The label filter check (#361) has not run. From a Hive worker session,
  `RemoteTrigger list` returned `Remote triggers unavailable: essential-traffic-only`, so no
  routine or webhook trigger could be created there. The owner runs
  [Check the label filter](#check-the-label-filter-361). Until its result is recorded here,
  treat the filter as unverified.
