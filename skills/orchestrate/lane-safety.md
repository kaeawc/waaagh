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
   No `./gradlew --stop`: it stops every lane's Gradle daemons, running builds included.
4. **Never open or quit Simulator.app.** Use `xcrun simctl` on your own device only, never on
   `all`.
5. **Enter the worktree (`EnterWorktree`) before editing.** Never write files with shell
   redirection, `tee`, `sed -i`, `cp` or an interpreter to get past the edit hook. If the hook
   blocks an edit, you are in the wrong directory: fix that, do not route around it.
6. **Run destructive commands in the foreground with their output visible.** No `& true`, no
   `>/dev/null 2>&1` on `rm`, `kill`, `simctl delete`, `avdmanager delete` or `git worktree
   remove`: a backgrounded, silenced deletion cannot be caught in time. To keep output short, pipe
   it (`2>&1 | tail -1`); never discard it. These forms may be quiet, because silence hides only
   "already stopped": `kill $(cat <pidfile>) 2>/dev/null` (stderr only) for a PID you recorded in
   a file, with nothing before it in the command but `cd` and read-only commands (`grep`, `tail`,
   `ls`, ...); a kill of literal recorded PIDs (`kill 4242 2>/dev/null`); `adb -s <your serial>
   emu kill`; and `xcrun simctl shutdown <your udid>`. A liveness probe (`kill -0 PID`) is no kill.
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
| `rm` without `-r`, `unlink` on a protected root itself (`rm ~`, `rm -f ~/.ssh`) | deny | deny |
| `rm` without `-r`, `unlink` of a file outside the worktree and temp dirs (a file below a protected root counts as a write: `rm -f ~/.ssh/known_hosts`) | allow | deny |
| `ln` (any form) whose link, or whose target, lies outside the worktree, temp dirs and the state dir; a relative symlink target resolves from the link's directory (`ln -s <checkout> nl` is refused when made, so `ln -s <checkout> nl && echo x > nl/f` cannot pass) | allow | deny |
| a write through a symlink whose real target lies outside (`echo x > <lane>/hm/.bashrc` with `hm -> $HOME`); a target under `/dev`, a temp dir or an allowed root stays allowed | allow | deny |
| a glob in any path part (`rm -rf <lane>/*/.ssh`, `echo x > <lane>/s*/../README`): every match is judged; more than 100 matches in one command | as each match; ask | as each match; deny |
| a brace expansion (`rm -rf {~,zz}`, `touch {../../..,zz}/README`): every word is judged; more than 100 words, braces around a variable the hook cannot spell out, a quoted or escaped brace or comma beside one (`rm -rf {hm/.ssh,'{'}`), or a word over 4096 characters or 64 braces | as each word; ask | as each word; deny |
| a glob with more than 2 globbed path parts (`echo x > /System/*/*/*/*/x`), or unquoted zsh glob syntax in a write, delete, `ln` or `cd` operand (`h(m\|x)`, `(hm)`, `^`, `**/`, a `#` after a glob character, a `~` past the start; a quoted `'out/a (1).txt'`, a lone `#` as in `out/b#1` and `out/**`, which both shells read as `out/*`, are plain words): refused unexpanded, as is what is left once the hook has spent 3 seconds expanding | ask | deny |
| `pkill`, `killall`, `xargs kill`, `kill` fed by `pgrep`/`pidof`/`lsof`/`ps`, `kill -1` | deny | deny |
| quitting, killing or opening Simulator.app; `simctl shutdown/erase/delete all` | deny | deny |
| `adb kill-server`; `adb emu kill` without `-s` | deny | deny |
| `gradle --stop`, `./gradlew --stop` (every compatible daemon on the host) | allow | deny |
| `>`, `>>`, `tee`, `cp`, `mv`, `sed -i`, `perl -i`, `dd of=` writing outside the worktree, temp dirs and the state dir | allow | deny |
| a destructive command that is backgrounded (`&`) or silenced (`>/dev/null`) | ask | ask |
| a silenced stop of one named device: `adb -s SERIAL emu kill`, `simctl shutdown UDID` (not `all`, not `booted`); it loses nothing, and silence hides only "already stopped" or "no such device" | allow | allow |
| `kill -0 PID` (also `-s 0`, `-n 0`) and `kill -l`: a liveness probe or a signal list, it signals nothing, silenced or not, whatever feeds it | allow | allow |
| `kill $(cat PIDFILE) 2>/dev/null` (also `$(<PIDFILE)`, backticks; every PID from such a substitution) where the hook has read PIDFILE and it holds only PIDs above 1 | allow | allow |
| `kill [-SIG] PID...` where every PID is a literal number above 1, silenced or not; a `ps -p`/`-q PID` check beside it is no process search | allow | allow |
| `rm -r "$VAR"` where `VAR=…` (or `export VAR=…`) is a literal the hook can expand, assigned unconditionally at the top level (only `;`/newlines before it: no pipe, subshell, loop, `if`, `&&` chain or unresolved `cd`) and `VAR` appears nowhere else (`read`, `for`, a second assignment, `${VAR:=…}`; nothing `source`d): judged by its value | as that path | as that path |
| a write to `~/.claude/projects/<project>/memory/` (Claude auto-memory) | allow | allow |
| the same with a missing, empty or malformed PIDFILE (a mistyped path): the reason names the path it resolved to | ask | ask |
| the same where the hook cannot be sure it read the file the shell will read: anything before it in the command but resolved `cd DIR`s, other quiet kills and read-only commands (`grep`, `egrep`, `fgrep`, `head`, `tail`, `cut`, `cat`, `echo`, `printf`, `ls`, `wc`, `tr`, `sleep`, `date`, `pwd`, with no file redirection, wrapper or substitution); a `cd` the shell may skip or undo (after `\|\|`, in a pipeline, after `&&` unless a `cd` precedes it, or anywhere near a parenthesis); a wrapper (`sudo`, `env`, `timeout`, `bash -c`, `eval`); a pipe out of the kill; or any other redirection | ask | ask |
| shell writes, `rm -r`, mutating `git` (`checkout`, `switch`, `reset`, `pull`, `merge`, `rebase`, `commit`, `stash`, `restore`, `apply`, `am`, `cherry-pick`, `revert`, `clean`, `add`, `rm`, `mv`, `branch -d/-m/-c/-f`, `worktree remove/move`) or an `Edit`/`Write`/`MultiEdit`/`NotebookEdit` call under a forbidden root, outside the caller's own nested worktree | allow (subagents: deny) | deny |

A session is "in a lane" when its working directory is inside a linked git worktree, or when
`WAAAGH_LANE_ROOT` names the lane root. The "In a lane" denials bind a **known lane**: a subagent's
call (the payload carries `agent_id`), a session with `WAAAGH_LANE_ROOT` set, or a worktree with an
`active` row in a `lanes.tsv` under the state root (`lane-claim.sh add`). Any other linked worktree
is the owner's own session (the Claude desktop app runs every session in one), so the same rules
**ask** there instead: the owner approves or declines in the permission prompt. Register every lane
with `lane-claim.sh add` before it starts, or its out-of-worktree writes reach the owner as prompts
rather than denials. Temp dirs are `/tmp`, `/private/tmp`, `/var/folders` and
`$TMPDIR` (`WAAAGH_LANE_TEMP` overrides); `WAAAGH_LANE_ALLOW` adds roots (colon-separated).
The hook follows `cd` the way the shell does: `..` in a `cd` argument is applied by text against
the logical working directory, and only `cd -P` resolves symlinks. Paths given to writes and
deletes are judged by where they really lead, symlinks and `..` included, so a link inside the lane
cannot reach the orchestrator's checkout (#380); writes are judged by their real target through
a symlink as well, and an `ln` by its target, so a link made and used in one command cannot leave
the lane either (#384). A glob is expanded the way the shell expands it, against the working
directory, and every match is judged; a glob that matches nothing is judged as written. The
literal word is judged first, and a word already refused is never expanded: a hook that runs past
its 10-second timeout does not block, so a glob that could walk the disk is refused before it runs
(#387). Behind those bounds, a deadline holds for the whole hook (#388): the checks run in a worker
process, and if they have not decided after 6 seconds the hook stops the worker and fails closed,
with "the check took too long; split the command or name the paths" (deny in a known lane or for a
subagent's call, ask otherwise). And `hooks/hooks.json` sets `"onFailure": "block"` on the hook
(Claude Code v2.1.295 or later), so a hook that fails or times out blocks the call instead of
letting it through. Brace expansion is done by the hook itself, by bash's rule, without running anything. A
glob or brace in a `cd` target counts when it makes exactly one directory; otherwise the working
directory is unknown for the rest of the command. `ln -tDIR` and `ln -sfTtDIR` read DIR as `-t DIR`. After a `pushd` other than `pushd DIR`,
`cd -`, `cd ±N`, or a `cd` given both `-L` and `-P`, the working directory is unknown for the
rest of the command: relative write and delete operands are denied, so use absolute paths, or
`cd` to an absolute path first.
The hook follows a `cd` only where the shell is sure to make it (#385). A subshell's `cd` ends at
its `)`, and a command substitution is judged from the directory of the command holding it.
`pushd DIR` pushes and `popd` returns to the directory it left (`pushd d1 && ./build.sh; popd;
echo ok > out.txt` is fine); a `popd` with nothing pushed, or after a plain `cd` (zsh's
`AUTO_PUSHD` pushes one), loses the directory. A `cd` that may fail (its target does not exist
yet and no earlier `mkdir` in the line makes it, or an earlier command in the line may have
changed the tree: anything but `cd`, `mkdir` and read-only commands) or may not run (inside `if`/`while`/`for`/`case`, or once the command defines
a function) holds only for the commands chained after it with `&&`: after a `||` (except
`cd DIR || exit`) or at the end of its list, the directory is unknown. So is it after a `cd` in a
pipeline (zsh runs the last part in the current shell, bash none), in a backgrounded list or in an
`eval`, after zsh's two-operand `cd OLD NEW`, and after a relative `cd` while `CDPATH` is set (in
the hook's environment or anywhere in the command; bash searches it before the current directory;
`./DIR` is not searched). Chain with `&&`, or use absolute paths. A `CDPATH` or `cdpath` set only
in the user's shell startup files is not visible to the hook.
A resolved `cd` into another linked worktree of the same repository makes that worktree writable
for the rest of the command: a lane subagent starts in the orchestrator's working directory (a
linked worktree itself in the desktop app) and reaches its own worktree by `cd`, so each command
that writes there starts with `cd <worktree>`. The main checkout and forbidden roots never open
this way, and `rm -r` of the worktree itself stays denied. Two owner-session exceptions cut the
prompts an orchestrator draws while it drives its lanes without a `cd`: `cp
<checkout>/android/local.properties <linked worktree>/android/` (the gitignored Android SDK file
every new worktree needs) is allowed, and with `WAAAGH_OWNER_SIBLING_WORKTREES=allow` (default
`ask`; set it in the owner's environment, never in a lane) writes and `rm -r` by absolute path below
any other linked worktree of the same repository are allowed too. Neither ever reaches the main
checkout, a worktree's root, a known lane or a subagent's call.
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
