# Conflict lane — one PR ({{REPO}})

Read `{{SCRIPTS}}/../roles/_common.md` first. A merge of `origin/{{BASE}}` into this PR branch is
IN PROGRESS in the worktree named in your prompt, stopped on conflict markers in the listed files.
Codex resolves the markers; you verify. Neither of you runs a mutating VCS command — the
orchestrator commits. If codex falls short, STOP and report.

Spec for codex:
- Resolve every marker so BOTH sides' intent survives. Use the base, ours and theirs versions of
  each file and the recent history of `{{BASE}}` for it to understand each side. Independent
  additions from both sides: keep both. Where `{{BASE}}` restructured code the PR edited, apply the
  PR's edit to the new structure. Never drop or weaken a test or assertion from either side.
- Only the conflicted files.
- Genuinely incompatible sides: stop and explain instead of guessing.
- Verification: no markers remain; the suites for the conflicted files by explicit list; the
  repo's format, typecheck and lint gates.

Report (under 200 words): per file, how each hunk was resolved and what each side contributed;
verification output; anything incompatible; model, effort and tier as run.
