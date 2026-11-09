# Supersede evidence — one old PR ({{REPO}})

Read `{{SCRIPTS}}/../roles/_common.md` first. Your prompt names an old PR (#P), its issue (#N)
and the `supersede-check.sh` output that made it a SUPERSEDED-CANDIDATE: later merges into
`{{BASE}}` may already ship #P's behaviour under another design. Re-applying #P on top would
reverse choices `{{BASE}}` already made, so you do NOT resolve #P's conflicts. You gather evidence
and recommend. You close nothing, and you never push to #P's branch.

1. Re-run `"{{SCRIPTS}}/supersede-check.sh" --pr P --worktree <your worktree>` after
   `git -C <worktree> fetch origin`. Exit 0 (no longer a candidate, or #P merged or closed): stop
   and report that.
2. Start fresh from `origin/{{BASE}}` on a new branch (`evidence/P-superseded`) in the lane
   worktree your prompt names. Not from #P's branch, and no merge of it.
3. List where the two designs disagree: from the check's table (file, #P's lines, main's lines,
   the merged PR) and from reading #P's diff beside the merged PRs' diffs. One line per behaviour:
   what #P does, what `{{BASE}}` does now, and which merged PR made it so.
4. Port #P's test expectations onto `{{BASE}}`'s design: the cases #P's tests assert, rewritten
   against the current code, no production change. Then add one failing-first test per
   disagreement from step 3 that pins #P's intended behaviour. Run them; record which pass on
   `{{BASE}}` untouched and which fail.
5. Decide:
   - **All pass**: `{{BASE}}` already covers #P. Recommend closing #P and #N as superseded by the
     named merged PRs, with the test list as evidence. Keep the tests only if they add coverage
     `{{BASE}}` lacks (then they go in a small tests-only PR). Close nothing yourself.
   - **Some fail**: port ONLY the missing guard into `{{BASE}}`'s design, so those tests pass,
     with no other change. Commit on your branch for a NEW PR whose body says it supersedes #P
     ("Supersedes #P; remaining guard from it: ...") and links #N; the orchestrator opens it.
     #P itself is still only recommended for closing.
6. Gates for anything you commit: {{REBASE_GATES}}.

Report (under 250 words): the disagreement table; each ported or new test with pass/fail on
`{{BASE}}`; the recommendation (close #P and #N as superseded by #X, #Y; or new PR on branch B
porting guard G); gate output; anything you could not port and why.
