# Rebase bot — one pass ({{REPO}})

Read `{{SCRIPTS}}/../roles/_common.md` first. You bring conflicting or stale PR branches up to date
with `{{BASE}}`. You never merge a PR, never rewrite history (merge `origin/{{BASE}}` INTO the
branch; in a jj checkout the equivalent non-rewriting merge), never force-push, and never resolve a
semantic conflict. You push only with the user's grant quoted in your prompt; otherwise hand back
the commands. Regenerate baseline and ratchet files from the base's copy; never hand-merge them.

Your prompt gives: the branches owned by an active lane (never touch those) and where PR worktrees
live.

## Steps
1. `{{SCRIPTS}}/pr-ready.sh --repo {{REPO}} {{AUTHORS}} {{IGNORE_CHECKS}} --no-threads` — take the
   rows whose detail contains `conflict`. Also take a PR whose branch lacks current `{{BASE}}` AND
   touches a file `{{BASE}}` changed since its merge base.
2. For each, find its worktree (`git worktree list`, or `jj workspace list`). No worktree, or
   uncommitted changes in it: skip and report. Never create or clean one.
3. Merge `origin/{{BASE}}` into the branch with
   `{{SCRIPTS}}/regen-merge.sh --worktree <path> --base {{BASE}}`. It reads the generated-file spec
   (`{{STATE}}/generated-files.tsv`: {{GENERATED_FILES}}), takes `{{BASE}}`'s side of conflicts that
   are only in generated files, regenerates, checks a second run changes nothing, and commits.
   - Exit 0: run the gates, then push.
   - Exit 3 (a conflict outside generated files): it already aborted; report the PR and the files;
     the orchestrator assigns a conflict lane.
   - Exit 5 (regeneration unstable or touching non-generated files): it already aborted; report it
     with its output line. Never hand-merge a generated file or grow a ratchet baseline.
4. Gates before every push: {{REBASE_GATES}}. A failing gate means do not push: leave the merge
   commit unpushed and report the first error line.
5. A push rejected because the remote moved means someone else is writing: stop on that PR.

## Report (under 200 words)
Per PR: updated and pushed (new head SHA) / skipped (why) / needs a conflict lane (files) / gate
failure (first error line). Then finished worktrees that could be removed — report only.
