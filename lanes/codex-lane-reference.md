# Codex lane reference

Read this only when the normal path in your agent definition does not cover what happened. The
normal path is: preflight → `codex-lane-start.sh` → `codex-lane-wait.sh` → verify → report.

## What `codex-lane-start.sh` does for you

- Creates a fresh run directory under `~/.claude/codex-lanes/<worktree>/run.XXXXXXXX`. Never use a
  shared `$TMPDIR` path or a path from another call, lane or session.
- Writes `spec.md` as `LANE-WORKTREE: <realpath>`, the lane preamble, then your spec body.
- Starts `codex-lane-run.sh` in its own session, so the run survives the tool call, with
  `--soft 1800 --stall 1200 --hard 7200` and `--effort` only when the spec named one.
- The runner always passes `--sandbox workspace-write`, `--skip-git-repo-check`, `--json` and
  `--output-last-message`. Never call `codex` directly and never pass
  `--sandbox danger-full-access`.

## Why the `LANE-WORKTREE:` first line

Concurrent lanes that share temp paths can feed codex another lane's (or another session's) spec
file; codex then exits 0 after working a different task, sometimes in the wrong tree. The runner
refuses (exit 64) unless line 1 is exactly `LANE-WORKTREE: <realpath of --cd>`, and it snapshots the
spec to `$LOG.spec` before launch. Exit 64 means the spec/worktree pairing is wrong: fix the
spec, never strip the check.

## Why the preamble

`codex exec` loads the user's `~/.codex/AGENTS.md` on every invocation, and a rule written for one
project governs every lane on the machine. If such a rule pins a model or effort or mandates an
orchestration flow, codex declines rather than silently substituting, and the run comes back
**exit 0 with an empty diff and a polite refusal in the final message**. The preamble states the
opt-out those rules typically provide, scoped to this lane only. It is belt and braces: the empty
diff is what actually catches a refusal.

## Exit codes and files

| Exit | Meaning | Report |
|---|---|---|
| 0 | codex finished | verify; an empty diff is still `refused` |
| 64 | spec does not name this worktree | `refused`, reason "spec/worktree mismatch" |
| 124 | hard cap | `timeout` |
| 125 | no progress for the stall window | `timeout`, reason "stalled" |
| other | codex's own exit code | read the final message and `$LOG.stderr` |

Next to `$LOG`: `.spec` (snapshot), `.args`, `.stderr`, `.progress.state` and `.progress.rev`
(what the waiter watches), `.progress.latest` (with liveness counters), `.progress` (soft
checkpoints), `.final`, `.exit`. `~/.claude/codex-lanes/<worktree>/latest.*` symlinks are for
humans and move whenever any run starts in that worktree: never wait on them.

## Fast service tier

Prefix the start helper with `CODEX_LANE_SERVICE_TIER=fast` when the spec or your brief asks for
fast mode, and confirm it from `$LOG.args`.

## Interrupts

- **Usage limit / quota** → `STATUS: unavailable`, `REASON: implementer-unavailable (usage limit)`.
- **401 / "sign in again" / auth** → `STATUS: unavailable`, `REASON: implementer-unavailable (auth)`.
- Neither is retried, and neither is a reason to implement the task yourself; quote the exact
  error line.
- **Capacity** (overloaded, rate-limited): one retry after 60 seconds; if it fails the same way,
  `STATUS: unavailable`, `REASON: implementer-capacity` and the exact error.
- **Smoke test** (when the orchestrator asks): one tiny `codex exec --model <your model>` ("reply
  OK", no repository access) and report only whether it returned.

## Quoting codex

Quote the decisive sentence or two (at most about 600 characters) and give the file path of the
full text (`$FINAL`, `$LOG.final`). Never paste a whole final message or transcript: the path is
the evidence, the quote is the summary.
