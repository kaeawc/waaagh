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
   remove`: a backgrounded, silenced deletion cannot be caught in time.

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

A session is "in a lane" when its working directory is inside a linked git worktree, or when
`WAAAGH_LANE_ROOT` names the lane root. Temp dirs are `/tmp`, `/private/tmp`, `/var/folders` and
`$TMPDIR` (`WAAAGH_LANE_TEMP` overrides); `WAAAGH_LANE_ALLOW` adds roots (colon-separated).
`WAAAGH_LANE_SAFETY=off` disables the hook for a session that needs it off; the owner sets it, never
a lane.

Limits: the hook cannot see writes made by an interpreter's own file API (`python -c "open(…)"`),
paths read from files or stdin other than through `xargs rm`, or deletions inside a script the
command runs. Rules 1–6 still bind there; the hook is the backstop, not the contract.

## Model choice for device lanes

Device setup and cleanup involve improvised destructive commands. An agent that creates or deletes
emulators, AVDs or simulators runs on a stronger model: **Sonnet over Haiku** (or Opus; see the
model table in `subagent-hygiene.md`). Haiku stays fine for roles that only read or run fixed
scripts.
