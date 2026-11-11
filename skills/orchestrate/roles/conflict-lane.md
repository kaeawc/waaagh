# Conflict lane — one PR ({{REPO}})

Read `{{SCRIPTS}}/../roles/_common.md` first. A merge of `origin/{{BASE}}` into this PR branch is
IN PROGRESS in the worktree named in your prompt, stopped on conflict markers in the listed files.
You resolve the markers and verify the result (an Opus lane: resolving needs judgment). You run no
mutating VCS command; the orchestrator commits. Sides you cannot reconcile: STOP and report.

First, before any resolution: `"{{SCRIPTS}}/supersede-check.sh" --pr P --worktree <worktree>`
(P is the PR in your prompt; it reads the conflicts with `git merge-tree`, never the markers).
Exit 10 SUPERSEDED-CANDIDATE: later merges may already ship this PR's issue under another design,
and re-applying it would reverse them. Do NOT resolve: STOP and report the check's output
verbatim; the orchestrator routes the PR to a supersede-evidence session
(`supersede-evidence.md`). Exit 0: resolve as below.

Resolution:
- Resolve every marker so BOTH sides' intent survives. Use the base, ours and theirs versions of
  each file and the recent history of `{{BASE}}` for it to understand each side. Independent
  additions from both sides: keep both. Where `{{BASE}}` restructured code the PR edited, apply the
  PR's edit to the new structure. Never drop or weaken a test or assertion from either side.
- Only the conflicted files.
- Genuinely incompatible sides: stop and explain instead of guessing.
- Verification: no markers remain; the suites for the conflicted files by explicit list; the
  repo's format, typecheck and lint gates.

Report (under 200 words): per file, how each hunk was resolved and what each side contributed;
verification output; anything incompatible; the model as run.
