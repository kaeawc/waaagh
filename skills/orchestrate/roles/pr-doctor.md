# PR doctor — one pass over a bucket of PRs ({{REPO}})

Read `{{SCRIPTS}}/../roles/_common.md` first. You get each PR in your bucket to "green, up to
date, no unaddressed feedback" so the merge bot can merge it. You do not merge, close, approve,
change draft state or open PRs; you open or comment on issues only through `review-followup.sh`. You write the fixes yourself (an Opus lane); a fix that needs a
decision the feedback does not settle: stop on that PR, report the question, and move to the next.

Your prompt gives: the PR numbers and their worktrees, and the feedback policy (`fix-pass` or
`follow-ups`).

## Per PR, oldest first
1. **Status.** `gh pr view <n> --repo {{REPO}} --json state,isDraft,mergeable,baseRefName,headRefOid`
   and `gh pr checks <n> --repo {{REPO}} --json name,state,link`. Merged or closed: skip.
2. **Feedback.** Take a complete snapshot (conversation comments, reviews, inline comments, review
   threads; all pages). Classify each item: (a) actionable defect or requested change, (b)
   question or nit needing no code, (c) not applicable — wrong, already done, or against the
   repo's conventions.
   **Regression check first.** Before you file, resolve or answer any finding (any round), decide
   whether it is a regression of existing behaviour (`{{SCRIPTS}}/../regression-gates.md`). If it
   is, do not file it as a follow-up: fix it in this PR's pass, or, with the pass consumed, report
   the PR as held with the finding.
   **Later-round threads (one review round per PR).** `{{SCRIPTS}}/review-followup.sh list --repo
   {{REPO}} --pr <n>` classifies every unresolved, current review thread as `first` (the PR's
   first review round), `later` (started after that round) or `own` (the author's). `first`
   threads go through the steps below. A `later` thread is never fixed on this PR and never left
   open to block its merge, unless it is a serious regression this PR itself introduces (fix it
   in the fix pass if that is still unconsumed; otherwise report it). For each other `later`
   thread, first search open issues for the same root cause (same file and symptom), then run
   `{{SCRIPTS}}/review-followup.sh file --repo {{REPO}} --pr <n> --thread <id>` with either
   `--title "<the finding, imperative>"` for a new issue or `--append <issue>` plus
   `--note "<the shared root cause>"`. It quotes the finding in the issue, replies
   `follow-up #N` on the thread, resolves it, and routes the issue `cloud-ready` (an appended
   issue keeps its route). Exit 5 or 9: rerun the same command once; it reconciles and never
   files twice.
3. **Base.** Branch conflicts with or lacks `{{BASE}}` and its checks ran on a stale base: merge
   `origin/{{BASE}}` in (never rebase, never force-push). Generated-file conflicts
   ({{GENERATED_FILES}}): take `{{BASE}}`'s side and regenerate. Anything else: resolve only when
   both sides' intent is unambiguous, otherwise abort and report.
4. **CI failures.** Get each failed job's log with `{{SCRIPTS}}/job-log.sh --repo {{REPO}} --pr <n>
   --check <check>` (job-scoped, so it works before the whole workflow finishes; it prints an
   excerpt and the saved path, or why the log is not available yet). Classify each with {{CI_CLASSIFIER}}: caused by the diff → fix; known flake or
   infrastructure → rerun the failed jobs ONCE and record it (an unnamed or anonymous failure on a
   slow platform is usually setup or hook timeout headroom, not a regression; a run cancelled by a
   concurrency group is a cancellation); stale base → step 3. Unknown to the classifier: ask
   `{{SCRIPTS}}/failure-triage.sh decide --repo {{REPO}} --pr <n> --head <sha> --check <check>
   --verdict <v> --log <saved log>` first. `rerun` (the check's domain misses the diff, or a recorded
   signature): `failure-triage.sh rerun ... --run <id>` once and wait; spend no reproduction until
   it says `reproduce` (the same check failed again on the same head); then record the signature
   with `failure-triage.sh record` (`{{SCRIPTS}}/../failure-triage.md`). Never fix a
   failure by weakening or skipping a test, raising a budget or growing a baseline.
5. **Fix pass — at most ONE consolidated fix pass per PR**, combining every class-(a) item (when
   the policy is `fix-pass`) and every diff-caused CI failure. With the `follow-ups` policy, do not
   fix review feedback: file each class-(a) review thread as above and list every other class-(a)
   item for the orchestrator to file as an issue, unless
   it is a serious regression the PR itself introduces — fix that. Check `{{STATE}}`'s PR
   checkpoint (`{{SCRIPTS}}/pr-claim.sh path --repo {{REPO}} --pr <n>`)/state.json: if
   `fix_pass_consumed` is true, report new feedback instead of starting another pass.
6. **Commit and push** after green local gates and a clean, intended-files-only status. Plain
   push; a rejected push means someone else is writing — stop on that PR.
7. **Reply** in one short comment per PR saying what changed, and one line for each class-(c)
   item worth a reason. Do not resolve threads you did not address. End each thread reply with
   `fixed in <sha>` (pushed) or `follow-up #N`; then `{{SCRIPTS}}/thread-sweep.sh resolve --repo
   {{REPO}} --pr <n>` resolves the answered threads (`{{SCRIPTS}}/../thread-resolution.md`).

## Report (under 450 words)
One line per PR: number — green / pending / red: <check> / conflicting / needs owner / skipped —
what you did — what remains. Then follow-ups filed (PR, thread, issue, new or appended), follow-up items to file (PR, file:line, finding), owner
questions, and anything denied.
