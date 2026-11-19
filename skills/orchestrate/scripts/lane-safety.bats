#!/usr/bin/env bats
# Lane safety contract hook (#73): feed lane-safety.sh PreToolUse payloads and assert allow, deny
# or ask. Run: bats lane-safety.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  T=$BATS_TEST_TMPDIR
  export HOME="$T/home" WAAAGH_LANE_TEMP="$T/scratch" ORCHESTRATE_STATE_DIR="$T/state"
  unset ANDROID_HOME ANDROID_SDK_ROOT WAAAGH_LANE_ROOT WAAAGH_LANE_ALLOW WAAAGH_PROTECTED_PATHS WAAAGH_LANE_SAFETY ANDROID_SERIAL
  mkdir -p "$HOME/Library/Android/sdk" "$T/scratch" "$T/main"
  git -C "$T/main" init -q
  git -C "$T/main" commit -q --allow-empty -m init
  git -C "$T/main" worktree add -q "$T/lane" -b lane
  LANE="$T/lane" MAIN="$T/main"
  register_lane "$LANE"
}

# decide CMD [CWD]: run the hook on a Bash payload; $output is the decision JSON (empty = allow).
decide() {
  local payload
  payload=$(jq -cn --arg c "$1" --arg d "${2:-$LANE}" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')
  run "$SCRIPTS/lane-safety.sh" <<<"$payload"
  [ "$status" -eq 0 ]
}
allowed() { [ -z "$output" ] || { echo "expected allow, got: $output"; return 1; }; }
verdict() { jq -r '.hookSpecificOutput.permissionDecision' <<<"$output"; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output"; }
denied() {
  [ "$(verdict)" = deny ] || { echo "expected deny, got: ${output:-allow}"; return 1; }
  [ -z "${1:-}" ] || [[ "$(reason)" == *"$1"* ]] || { echo "reason lacks '$1': $(reason)"; return 1; }
}
asked() {
  [ "$(verdict)" = ask ] || { echo "expected ask, got: ${output:-allow}"; return 1; }
  [ -z "${1:-}" ] || [[ "$(reason)" == *"$1"* ]] || { echo "reason lacks '$1': $(reason)"; return 1; }
}

@test "the SDK deletion from the incident is denied, backgrounded and silenced or not" {
  decide 'rm -rf $HOME/Library/Android/sdk >/dev/null 2>&1 & true'
  denied "protected path $HOME/Library"
  decide "rm -rf ~/Library/Android/sdk" "$MAIN"
  denied "protected path"
  decide "rm -r -f -- $HOME/Library" /
  denied "protected path"
}

@test "protected roots, their ancestors and the Android SDK are denied outside a lane too" {
  decide "rm -rf ~" "$MAIN"; denied "protected path $HOME"
  decide "rm -rf /" "$MAIN"; denied "protected path /"
  decide "rm -rf ~/.gradle/caches" "$MAIN"; denied ".gradle"
  decide "rm -fr ~/*" "$MAIN"; denied "protected path $HOME"
  decide "cd ~ && rm -rf Library" "$MAIN"; denied "protected path"
  ANDROID_HOME="$T/sdk" decide "rm -rf $T/sdk/platforms" "$MAIN"; denied "protected path $T/sdk"
  WAAAGH_PROTECTED_PATHS="$T/shared" decide "rm -rf $T/shared/x" "$MAIN"; denied "$T/shared"
  decide "find ~/Library -name '*.lock' -delete" "$MAIN"; denied "protected path"
}

@test "ordinary deletions are allowed outside a lane" {
  decide "rm -rf build" "$MAIN"; allowed
  decide 'rm -rf "$X"' "$MAIN"; allowed
  decide "rm -f ~/notes.txt" "$MAIN"; allowed
  decide "rm -rf /tmp/build-*" "$MAIN"; allowed
  decide "rm -rf ~/src-*" "$MAIN"; allowed
  decide "rm -rf ~/L*" "$MAIN"; denied "protected path $HOME/Library"
  decide "rm -rf /tmp/*" "$MAIN"; denied "protected path /tmp"
}

@test "in a lane, deletions stay inside the worktree or scratch dirs" {
  decide "rm -rf build out/*"; allowed
  decide "rm -rf $T/scratch/run1"; allowed
  decide "rm -rf $MAIN/src"; denied "outside the lane worktree $LANE"
  decide "cd .. && rm -rf main"; denied "outside the lane worktree"
  decide "rm -rf ."; denied "lane worktree itself; use git worktree remove"
  decide "find $MAIN -name x -delete"; denied "outside the lane worktree"
  WAAAGH_LANE_ALLOW="$T/extra" decide "rm -rf $T/extra/cache"; allowed
}

@test "in a lane, a deletion path built from a variable is denied" {
  decide 'rm -rf "$BUILD_DIR"/'; denied "path built from a variable; expand and echo"
  decide 'rm -rf $(cat dirs.txt)'; denied "path built from a variable"
  decide 'cat dirs.txt | xargs rm -rf'; denied "xargs rm -r"
  WAAAGH_LANE_ROOT="$T/lane" decide 'rm -rf "$X"' "$MAIN"; denied "path built from a variable"
}

@test "pattern kills are denied; killing a recorded PID is allowed" {
  decide "pkill -f xcodebuild"; denied "pkill kills by name or pattern"
  decide "killall node" "$MAIN"; denied "killall"
  decide "pgrep xcodebuild | xargs kill"; denied "xargs kill"
  decide 'kill $(pgrep -f gradle)'; denied "kill fed by a process search"
  decide 'ps aux | grep emu | awk "{print \$2}" | xargs kill -9'; denied "kill"
  decide 'kill $(lsof -t -i :8080)'; denied "process search"
  decide 'sudo pkill java'; denied "pkill"
  decide 'bash -c "killall Simulator"'; denied "never quit Simulator.app"
  decide 'kill -1'; denied "kill -1"
  decide 'kill "$(cat "$T/scratch/emu.pid")"'; allowed
  decide 'kill 12345 && wait 12345'; allowed
}

@test "Simulator.app is never quit or opened; simctl on all devices is denied" {
  decide "osascript -e 'quit app \"Simulator\"'"; denied "never quit Simulator.app"
  decide "osascript -e 'tell application \"Simulator\" to quit'"; denied "never quit Simulator.app"
  decide "open -a Simulator"; denied "never open Simulator.app"
  decide "xcrun simctl shutdown all"; denied "simctl shutdown all"
  decide "xcrun simctl erase all"; denied "simctl erase all"
  decide "xcrun simctl delete 0F1E2D3C-AAAA-BBBB-CCCC-123456789ABC"; allowed
  decide "xcrun simctl boot 0F1E2D3C-AAAA-BBBB-CCCC-123456789ABC"; allowed
}

@test "adb: kill-server and an emulator kill without a serial are denied" {
  decide "adb kill-server"; denied "adb kill-server"
  decide "adb emu kill"; denied "without -s"
  decide "adb -s emulator-5556 emu kill"; allowed
}

@test "in a lane, shell writes outside the worktree are denied" {
  decide "echo x > $MAIN/README.md"; denied "redirect $MAIN/README.md: writes outside the lane worktree"
  decide "printf x >> ../main/f"; denied "writes outside"
  decide "echo x | tee -a $MAIN/f"; denied "tee $MAIN/f"
  decide "sed -i 's/a/b/' $MAIN/f.sh"; denied "sed -i"
  decide "sed -i '' -e 's/a/b/' $MAIN/f.sh"; denied "sed -i"
  decide "perl -pi -e 's/a/b/' $MAIN/f"; denied "perl -i"
  decide "cp notes.md $MAIN/notes.md"; denied "cp $MAIN/notes.md"
  decide "dd if=/dev/zero of=$MAIN/blob bs=1 count=1"; denied "dd"
  decide "cd $MAIN && cat > f.txt <<'EOF'
body
EOF"; denied "writes outside"
  decide "echo x > f.txt; sed -i 's/a/b/' f.txt; cp a b"; allowed
  decide "echo x > $T/scratch/log 2>/dev/null"; allowed
  decide "echo x > $T/state/note"; allowed
  decide "make 2>&1 | tee build.log"; allowed
  decide "echo x > $MAIN/f" "$MAIN"; allowed
}

# decide_as AGENT CMD [CWD]: decide, with the payload's agent_id set to AGENT (a subagent's call).
decide_as() {
  local payload
  payload=$(jq -cn --arg a "$1" --arg c "$2" --arg d "${3:-$LANE}" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, agent_id: $a}')
  run "$SCRIPTS/lane-safety.sh" <<<"$payload"
  [ "$status" -eq 0 ]
}

@test "an unregistered worktree is the owner's session: lane rules ask; subagents and known lanes deny" {
  git -C "$MAIN" worktree add -q "$T/owner" -b owner
  OWN="$T/owner"
  decide "rm -rf $HOME/.claude/skills/old" "$OWN"; asked "no registered lane: approve only if you are the owner"
  decide "echo x > $HOME/.claude/notes.md" "$OWN"; asked "writes outside the lane worktree"
  decide 'rm -rf "$X"' "$OWN"; asked "path built from a variable"
  decide "rm -rf build; echo x > f.txt" "$OWN"; allowed
  # Protected roots and pattern kills stay denied for the owner too.
  decide "rm -rf $HOME/Library/Android/sdk" "$OWN"; denied "protected path"
  decide "pkill -f xcodebuild" "$OWN"; denied
  # A subagent's call, WAAAGH_LANE_ROOT and an active lanes.tsv row each make it a known lane.
  decide_as agent-1 "rm -rf $HOME/.claude/skills/old" "$OWN"; denied "outside the lane worktree"
  WAAAGH_LANE_ROOT="$OWN" decide "echo x > $HOME/.claude/notes.md" "$OWN"; denied "writes outside"
  decide "echo x > $MAIN/f"; denied "writes outside"
  # A lane whose row is no longer active is not a known lane.
  printf '%s\twork/2-y\t2\tsrc/\ta2\tmerged\n' "$OWN" >>"$ORCHESTRATE_STATE_DIR/o__r/lanes.tsv"
  decide "echo x > $HOME/.claude/notes.md" "$OWN"; asked "no registered lane"
  register_lane "$OWN"
  decide "echo x > $HOME/.claude/notes.md" "$OWN"; denied "writes outside"
}

@test "lanes.tsv rows: lane-claim's own rows, live statuses, CRLF, relative, ~, nested and top-level files" {
  git -C "$MAIN" worktree add -q "$T/owner" -b owner
  OWN="$T/owner" W="echo x > $HOME/.claude/notes.md" L="$ORCHESTRATE_STATE_DIR/o__r/lanes.tsv"
  rm -f "$L"
  # Relative rows resolve against the main checkout, where lane-claim.sh add runs.
  printf '.claude/x\tb\t1\tf\ta\tactive\n' >"$L"; decide "$W" "$OWN"; asked "no registered lane"
  printf '%s\tb\t1\tf\ta\tactive\n' "../owner" >"$L"; decide "$W" "$OWN"; denied "writes outside"
  # Any status lane-claim.sh still counts live is a known lane; only the ended ones are not.
  for st in pr-open running active; do
    printf '%s\tb\t1\tf\ta\t%s\n' "$OWN" "$st" >"$L"; decide "$W" "$OWN"; denied "writes outside"
  done
  for st in done merged closed abandoned; do
    printf '%s\tb\t1\tf\ta\t%s\n' "$OWN" "$st" >"$L"; decide "$W" "$OWN"; asked "no registered lane"
  done
  # Hand-edited rows: CRLF, trailing blanks, a trailing slash, a comment line.
  printf '# lanes\n%s\tb\t1\tf\ta\tactive\r\n' "$OWN" >"$L"; decide "$W" "$OWN"; denied "writes outside"
  printf '%s/\tb\t1\tf\ta\tactive  \n' "$OWN" >"$L"; decide "$W" "$OWN"; denied "writes outside"
  printf '# %s\tb\t1\tf\ta\tactive\n' "$OWN" >"$L"; decide "$W" "$OWN"; asked "no registered lane"
  # A ~ row, and a row for the worktree's parent or a directory inside it, err toward deny.
  mkdir -p "$HOME/wt"; git -C "$MAIN" worktree add -q "$HOME/wt/h" -b h
  printf '~/wt/h\tb\t1\tf\ta\tactive\n' >"$L"; decide "$W" "$HOME/wt/h"; denied "writes outside"
  printf '%s/sub\tb\t1\tf\ta\tactive\n' "$OWN" >"$L"; decide "$W" "$OWN"; denied "writes outside"
  # The state root's own lanes.tsv counts too.
  rm -f "$L"; printf '%s\tb\t1\tf\ta\tactive\n' "$OWN" >"$ORCHESTRATE_STATE_DIR/lanes.tsv"
  decide "$W" "$OWN"; denied "writes outside"
}

@test "the owner's worktree session: deleting its own worktree and globs ask; forbidden roots stay denied" {
  git -C "$MAIN" worktree add -q "$T/owner" -b owner
  OWN="$T/owner"
  decide "rm -rf $OWN" "$OWN"; asked "that is the lane worktree itself"
  decide "rm -rf $HOME/.claude/old*" "$OWN"; asked "outside the lane worktree"
  printf '%s\n' "$MAIN" >"$ORCHESTRATE_STATE_DIR/lane-forbidden"
  decide "echo x > $MAIN/README.md" "$OWN"; denied "orchestrator's checkout"
  decide "rm -rf $MAIN/src" "$OWN"; denied "orchestrator's checkout"
}

@test "destructive commands that are backgrounded or silenced are flagged for review" {
  decide "rm -rf build >/dev/null 2>&1"; asked "silenced destructive command"
  decide "rm -rf build &"; asked "backgrounded destructive command"
  decide 'kill $P 2>/dev/null'; asked "silenced"
  decide "rm -rf build"; allowed
  decide "ls >/dev/null 2>&1 &"; allowed
}

@test "a silenced kill from a pidfile the hook has read is not asked; a missing or malformed one is" {
  mkdir -p "$LANE/scratch/sub"
  echo 4242 >"$LANE/scratch/logpid.txt"; printf '11\n22\n' >"$LANE/scratch/two.pid"
  echo "pid 4242" >"$LANE/scratch/bad.pid"; : >"$LANE/scratch/empty.pid"
  decide 'kill $(cat scratch/logpid.txt) 2>/dev/null'; allowed
  decide 'kill -9 "$(<scratch/two.pid)" 2>/dev/null; ls'; allowed
  decide 'kill -s TERM `cat scratch/logpid.txt` $(cat scratch/two.pid) 2>/dev/null'; allowed
  decide 'kill $(cat scratch/logpid.txt 2>/dev/null) 2>/dev/null'; allowed
  decide "cd $LANE/scratch; kill \$(cat logpid.txt) 2>/dev/null; P=x; find . -name '*.log' | head"; allowed
  # The incident shape (2026-11-19): cd to the lane, kill the recorded log PID, then only reads.
  decide "cd $LANE; kill \$(cat scratch/logpid.txt) 2>/dev/null; ls scratch 2>/dev/null | head -30" "$MAIN"; allowed
  # A mistyped or missing pidfile is caught before the command runs, with the path it resolved to.
  decide 'kill $(cat scratch/logpdi.txt) 2>/dev/null'; asked "pidfile scratch/logpdi.txt not found ($LANE/scratch/logpdi.txt)"
  decide 'cd scratch/sub; kill $(cat logpid.txt) 2>/dev/null'; asked "not found ($LANE/scratch/sub/logpid.txt)"
  decide 'kill $(cat scratch/logpid.txt) $(cat scratch/nope.pid) 2>/dev/null'; asked "pidfile scratch/nope.pid not found"
  decide 'kill $(cat scratch/bad.pid) 2>/dev/null'; asked "does not hold only PIDs above 1"
  decide 'kill $(cat scratch/empty.pid) 2>/dev/null'; asked "does not hold only PIDs above 1"
  decide 'kill $(cat "$PIDFILE") 2>/dev/null'; asked "let its output show"
  # Anything the hook cannot verify keeps the plain ask.
  decide 'kill $(cat scratch/logpid.txt) >/dev/null 2>&1'; asked "silenced destructive command"
  decide 'kill $(cat scratch/logpid.txt) &>/dev/null'; asked "silenced destructive command"
  decide 'kill 4242 $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'kill $PID 2>/dev/null'; asked "let its output show"
  decide 'kill $(cat scratch/logpid.txt; echo 1) 2>/dev/null'; asked "let its output show"
  decide 'kill $(head -1 scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'kill $(cat scratch/logpid.txt scratch/two.pid) 2>/dev/null'; asked "let its output show"
  decide 'kill -s $(echo TERM) $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'kill $(cat scratch/logpid.txt) 2>/dev/null &'; asked "backgrounded destructive command"
  # The file the hook read must be the file the shell reads: nothing before the kill may write
  # it or move the cwd, and no wrapper may run the kill somewhere the hook did not follow.
  decide 'echo -1 > scratch/logpid.txt; kill $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'ln -sf ../x scratch/logpid.txt; kill $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'true; kill $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'cd "$OTHER"; kill $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'cd scratch >/dev/null; kill $(cat logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'pushd scratch; kill $(cat logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'cd $(echo scratch); kill $(cat logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'sudo kill $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'timeout 5 kill $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide 'X=1 kill $(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  decide "bash -c 'kill \$(cat scratch/logpid.txt) 2>/dev/null'"; asked "let its output show"
  decide "eval 'kill \$(cat scratch/logpid.txt) 2>/dev/null'"; asked "let its output show"
  decide 'echo $(kill $(cat scratch/logpid.txt) 2>/dev/null)'; asked "let its output show"
  decide 'kill $(cat scratch/logpid.txt) 2>/dev/null >&2'; asked "let its output show"
  decide 'kill $(cat scratch/logpid.txt) 2>|/dev/null'; asked "let its output show"
  decide 'kill $(cat scratch/logpid.txt) 2>/dev/null | true'; asked "let its output show"
  decide 'kill -- -$(cat scratch/logpid.txt) 2>/dev/null'; asked "let its output show"
  # PIDs 0 (the caller's process group), 1 (init) and -1 never pass as a pidfile's content.
  for v in 0 1 -1 "4242 0" 00; do
    echo "$v" >"$LANE/scratch/v.pid"
    decide 'kill $(cat scratch/v.pid) 2>/dev/null'; asked "does not hold only PIDs above 1"
  done
  # Still quiet: several quiet kills in a row, || true, -n, a pidfile with no trailing newline.
  printf 4242 >"$LANE/scratch/nonl.pid"
  decide 'kill $(cat scratch/logpid.txt) 2>/dev/null; kill -n 9 $(cat scratch/nonl.pid) 2>/dev/null || true'; allowed
  decide "cd $LANE && cd scratch
kill \$(cat two.pid) 2>/dev/null"; allowed
  decide 'rm -rf $(cat scratch/logpid.txt) 2>/dev/null'; denied
  decide 'kill $(pgrep -f xcodebuild) 2>/dev/null'; denied "kill fed by a process search"
  decide 'cat scratch/logpid.txt | xargs kill 2>/dev/null'; denied "xargs kill"
}

@test "quoted text, comments and heredoc bodies are data, not commands" {
  decide 'git commit -m "never pkill; never rm -rf ~"'; allowed
  decide "echo 'killall Simulator' # rm -rf ~"; allowed
  decide "cat <<'EOF' > notes.md
pkill -f xcodebuild
rm -rf ~/Library
EOF"; allowed
  decide 'grep -n "pkill" docs.md'; allowed
}

@test "a quoted newline stays inside its word: the rest of the command is still judged" {
  decide "rm -rf ~ 'a
b'"; denied "protected path $HOME"
  decide "rm -rf \"a
b\" ~"; denied "protected path $HOME"
  decide "kill 'a
b' -1"; denied "kill -1"
  decide "echo 'a
b' > $MAIN/f"; denied "writes outside"
  decide "echo 'rm -rf ~
pkill x'"; allowed
}

@test "other tools pass through; the hook can be switched off" {
  run "$SCRIPTS/lane-safety.sh" <<<'{"tool_name":"Edit","tool_input":{"file_path":"/etc/x"},"cwd":"/"}'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  WAAAGH_LANE_SAFETY=off decide "pkill -f x"; allowed
}

@test "the plugin wires the hook and the doctrine names every rule" {
  jq -e '.hooks.PreToolUse[] | select(.matcher | split("|") | any(. == "Bash")) | .hooks[] | select(.command == "${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/scripts/lane-safety.sh")' "$ROOT/hooks/hooks.json" >/dev/null
  [ -x "$SCRIPTS/lane-safety.sh" ]
  doc="$ROOT/skills/orchestrate/lane-safety.md"
  for s in "git worktree remove" "avdmanager delete avd -n" "xcrun simctl delete <udid>" \
    "Expand and echo the path first" "No \`pkill\`, \`killall\`" "Never open or quit Simulator.app" \
    "EnterWorktree" "Sonnet over Haiku" "lane-safety.sh"; do
    grep -qF -- "$s" "$doc" || { echo "missing in lane-safety.md: $s"; return 1; }
  done
  grep -qF "lane-safety.md" "$ROOT/skills/orchestrate/SKILL.md"
  grep -qF "lane-safety.sh" "$ROOT/README.md"
}
