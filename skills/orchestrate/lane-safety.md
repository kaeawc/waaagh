# Lane safety contract

Every lane brief carries these rules, and the plugin enforces most of them with a PreToolUse hook.
Learned on the auto-mobile campaign (2026-11-05/06): a Haiku lane agent deleted the Android SDK during
cleanup (`rm -rf $HOME/Library/Android/sdk >/dev/null 2>&1 & true`), one lane's pattern kill took
two other lanes' `xcodebuild` runners, quitting Simulator.app shut down every booted simulator
(protected CI devices included), and lanes wrote files around the edit hook with `sed`, `python`
and shell redirection. Complements safe worktree cleanup (`scripts/wt-cleanup.sh`) and device
ownership (`scripts/device-lock.sh`, SKILL.md "Isolation and ownership").

## The rules (paste into lane briefs)

1. **Delete only what you created.** Your own worktree (`git worktree remove`), your own AVD
   (`avdmanager delete avd -n <name>`) and your own simulator (`xcrun simctl delete <udid>`).
2. **Never `rm -rf` outside your worktree or scratch dir.** Never a path under `~/Library`, the
   Android SDK, `~/.gradle` or a shared directory, and never a path built from a variable that
   could be empty. Expand and echo the path first, then delete that literal path.
3. **Kill only PIDs you recorded when starting the process.** No `pkill`, `killall`, `xargs kill`
   or `kill $(pgrep …)`; no `adb kill-server`, and `adb emu kill` only with `-s <your serial>`.
4. **Never open or quit Simulator.app.** Use `xcrun simctl` on your own device only, never on
   `all`.
5. **Enter the worktree (`EnterWorktree`) before editing.** Never write files with shell
   redirection, `tee`, `sed -i`, `cp` or an interpreter to get past the edit hook. If the hook
   blocks an edit, you are in the wrong directory: fix that, do not route around it.
6. **Run destructive commands in the foreground with their output visible.** No `& true`, no
   `>/dev/null 2>&1` on `rm`, `kill`, `simctl delete`, `avdmanager delete` or `git worktree
   remove`: a backgrounded, silenced deletion cannot be caught in time. One form may be quiet:
   `kill $(cat <pidfile>) 2>/dev/null` (stderr only) for a PID you recorded in a file, where the
   silence hides only "no such process". Run it first in its command (after a `cd` at most).
   A kill of literal recorded PIDs (`kill 4242 2>/dev/null`), a liveness probe (`kill -0 PID`)
   and `adb -s <literal serial> emu kill` may be quiet too.
7. **Never change the orchestrator's checkout (`{{FORBIDDEN}}`).** A lane subagent starts in the
   orchestrator's working directory. You may read there; never edit, check out, pull, commit,
   stash or build there. Your first write is in your own worktree.

A denied command is an answer, not an obstacle (`roles/_common.md` rule 4): record it and move on.

## The hook

`hooks/hooks.json` runs `scripts/lane-safety.sh` before every Bash tool call. It tokenizes the
command (quotes, comments and heredoc bodies are data; `bash -c`, `eval`, `$(…)`, `sudo`, `env`,
`xargs` and `cd` are followed) and answers:

| Command | Outside a lane | In a lane |
|---|---|---|
| `rm -r` / `find -delete` on `/`, `$HOME`, `~/Library`, `~/.gradle`, `~/.android`, the SDK (`$ANDROID_HOME`), system dirs, `$WAAAGH_PROTECTED_PATHS`, or an ancestor of one | deny | deny |
| `rm -r` outside the worktree and temp dirs, on the worktree itself, or on a path built from a variable | allow | deny |
| `pkill`, `killall`, `xargs kill`, `kill` fed by `pgrep`/`pidof`/`lsof`/`ps`, `kill -1` | deny | deny |
| quitting, killing or opening Simulator.app; `simctl shutdown/erase/delete all` | deny | deny |
| `adb kill-server`; `adb emu kill` without `-s` | deny | deny |
| `>`, `>>`, `tee`, `cp`, `mv`, `sed -i`, `perl -i`, `dd of=` writing outside the worktree, temp dirs and the state dir | allow | deny |
| a destructive command that is backgrounded (`&`) or silenced (`>/dev/null`) | ask | ask |
| `kill $(cat PIDFILE) 2>/dev/null` (also `$(<PIDFILE)`, backticks; every PID from such a substitution) where the hook has read PIDFILE and it holds only PIDs above 1 | allow | allow |
| `kill -0 PID`, `kill -s 0`, `kill -n 0`, `kill -l` (probes: nothing is signalled), silenced or not, whatever feeds them | allow | allow |
| `kill [-SIG] PID...` where every PID is a literal number above 1, silenced or not; a `ps -p`/`-q PID` check beside it is no process search | allow | allow |
| `adb -s <literal serial> emu kill`, silenced | allow | allow |
| `rm -r "$VAR"` where `VAR=…` (or `export VAR=…`) is a literal the hook can expand, assigned unconditionally at the top level (only `;`/newlines before it: no pipe, subshell, loop, `if`, `&&` chain or unresolved `cd`) and `VAR` appears nowhere else (`read`, `for`, a second assignment, `${VAR:=…}`; nothing `source`d): judged by its value | as that path | as that path |
| a write to `~/.claude/projects/<project>/memory/` (Claude auto-memory) | allow | allow |
| the same with a missing, empty or malformed PIDFILE (a mistyped path): the reason names the path it resolved to | ask | ask |
| the same where the hook cannot be sure it read the file the shell will read: anything but resolved `cd DIR`s (or other quiet kills) before it in the command, a wrapper (`sudo`, `env`, `timeout`, `bash -c`, `eval`), a pipe, or any other redirection | ask | ask |
| shell writes, `rm -r`, mutating `git` (`checkout`, `switch`, `reset`, `pull`, `merge`, `rebase`, `commit`, `stash`, `restore`, `apply`, `am`, `cherry-pick`, `revert`, `clean`, `add`, `rm`, `mv`, `worktree remove/move`) or an `Edit`/`Write`/`MultiEdit`/`NotebookEdit` call under a forbidden root, outside the caller's own nested worktree | allow (subagents: deny) | deny |

A session is "in a lane" when its working directory is inside a linked git worktree, or when
`WAAAGH_LANE_ROOT` names the lane root. The "In a lane" denials bind a **known lane**: a subagent's
call (the payload carries `agent_id`), a session with `WAAAGH_LANE_ROOT` set, or a worktree with an
`active` row in a `lanes.tsv` under the state root (`lane-claim.sh add`). Any other linked worktree
is the owner's own session (the Claude desktop app runs every session in one), so the same rules
**ask** there instead: the owner approves or declines in the permission prompt. Register every lane
with `lane-claim.sh add` before it starts, or its out-of-worktree writes reach the owner as prompts
rather than denials. Two owner-session exceptions cut the prompts an orchestrator draws while it
drives its lanes: `cp <checkout>/android/local.properties <linked worktree>/android/` (the
gitignored Android SDK file every new worktree needs) is allowed, and with
`WAAAGH_OWNER_SIBLING_WORKTREES=allow` (default `ask`; set it in the owner's environment, never in
a lane) writes and `rm -r` below any other linked worktree of the same repository are allowed too.
Neither ever reaches the main checkout, a worktree's root, a known lane or a subagent's call.
Temp dirs are `/tmp`, `/private/tmp`, `/var/folders` and
`$TMPDIR` (`WAAAGH_LANE_TEMP` overrides); `WAAAGH_LANE_ALLOW` adds roots (colon-separated).
**Forbidden roots** (#218). Learned on auto-mobile (2026-11-11): a lane subagent inherited the
orchestrator's cwd, its own git worktree, and edited four source files and moved HEAD there before
creating its own worktree. The orchestrator writes its own checkout's absolute path as one line of
`<state root>/lane-forbidden` (`$ORCHESTRATE_STATE_DIR`, default `~/.claude/orchestrate`; `#`
comments; `WAAAGH_LANE_FORBID` adds a colon-separated list) at campaign start, fills `{{FORBIDDEN}}`
with it in every lane brief, and removes the line at wrap-up. The hook then binds every subagent
call (the hook payload carries `agent_id`) and every lane session whose own worktree is not
forbidden; the orchestrator's own calls are never bound. Read-only `git`, `git fetch` and
`git worktree add` stay allowed there, and a lane worktree nested below the forbidden checkout
(`.claude/worktrees/<lane>`) stays writable to its own lane. The hook cannot see builds: rule 7
still binds there.

**The orchestrator's tick check.** Each tick, run `git -C <own checkout> status --short`. Stray
edits there came from a lane: move them out with a patch (`git -C <own checkout> diff -- <files>
> <state dir>/stray-<lane>.patch`, `git -C <lane worktree> apply` it, then `git -C <own checkout>
restore -- <files>` for exactly those files), and correct that lane's brief.

`WAAAGH_LANE_SAFETY=off` disables the hook for a session that needs it off; the owner sets it, never
a lane.

Limits: the hook cannot see writes made by an interpreter's own file API (`python -c "open(…)"`),
paths read from files or stdin other than through `xargs rm`, or deletions inside a script the
command runs. Rules 1–7 still bind there; the hook is the backstop, not the contract.

## Model choice for device lanes

Device setup and cleanup involve improvised destructive commands. An agent that creates or deletes
emulators, AVDs or simulators runs on a stronger model: **Sonnet over Haiku** (or Opus; see the
model table in `subagent-hygiene.md`). Haiku stays fine for roles that only read or run fixed
scripts.
