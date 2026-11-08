# Failure triage: rerun first, reproduce second

A reproduction lane is the most expensive answer to a red check. Measured once: a PR that changed
only a Gradle TOML file failed its TypeScript lint ratchet with "oxlint did not emit parseable
JSON". A worklane reproduced lint on the PR head and on main in fresh worktrees (about 80k tokens
and 8.5 minutes); both passed. The rerun afterwards cost nothing and passed too.

## The rule (repair role, PR doctor, anyone triaging a PR's red check)

1. Classify first with the repository's classifier (for example its `classify-failure.sh`) and
   known-flakes list, reading one job log with `job-log.sh`.
2. Ask `"$SCRIPTS/failure-triage.sh" decide --pr N --head SHA --check NAME --verdict <first word
   of the classifier's verdict> --log <saved job log>`. It prints one action:
   - `rerun` — re-run the failed jobs once: the verdict is a known flake or infra; the log
     matches a recorded signature; or the verdict is unknown and the check's domain does not
     intersect the PR's changed paths (TS lint on a TOML-only diff).
   - `reproduce` — the same check already failed, was re-run on this same head, and failed again.
     Only now spend a reproduction lane (or fix it if the cause is plain from the log).
   - `triage` — ordinary triage: the classifier placed it, the domain intersects the diff, or no
     domain is configured for the check. Read the log; fix it if the diff caused it.
3. Re-run with `"$SCRIPTS/failure-triage.sh" rerun --pr N --head SHA --check NAME --run ID`. It
   checks the head has not moved and refuses a second rerun of that check on that head (exit 3),
   so "rerun until green" cannot happen. Wait for the rerun's result before anything else.
4. **Record the signature** once a cause is known (after a rerun passes, or after the reproduction
   explains it): `"$SCRIPTS/failure-triage.sh" record --check '<check glob>' --pattern '<ERE that
   matches the log line>' --note '<what it is>' --source 'PR N run ID'`. The next occurrence is
   then `rerun known-signature`. If the repository has its own classifier with a known-flakes
   list, also add the signature there in a PR, so CI and other sessions classify it too.

A pass after a rerun does not make a check healthy forever: a check that needs reruns on more than
one PR is a flaky gate, worth an issue. A green that came only from a rerun still counts as a
rerun under Main health in `SKILL.md`.

## Check domains

`<state dir>/check-domains` maps check names to the paths they are about, one line per check:

```
# <check name glob> => <path patterns>
lint* => *.ts *.tsx *.js package.json pnpm-lock.yaml .oxlintrc.json
android* => android/ gradle/ *.gradle.kts
```

Include the check's own config, lockfiles and workflow file in its domain: a change to those can
break it. The first matching line wins; a pattern ending in `/` is a directory prefix, any other is
a glob where `*` also matches `/`. A check with no line is never assumed disjoint.

## Briefing cloud sessions

A cloud session cannot ask; whatever it needs to know about its container must be in the brief.

- **Container knobs up front.** Cloud containers are small (often 4 cores). Put the repository's
  container settings in the gates text or `<state dir>/cloud-brief.md`: a longer local test wall
  timeout, fewer test workers, which suites to skip locally and leave to CI. Without them, a
  session spends its time on local timeouts that are not failures.
- **Never kill by pattern.** No `pkill`, `pkill -f`, `killall` or `kill $(pgrep ...)`: a pattern
  matches the session's own shell or tool runner. One session ran `pkill -f prepush` and killed
  its own shell, losing about 10 minutes. Kill only a PID the session started and recorded
  (`SKILL.md`: never kill what you did not start).
