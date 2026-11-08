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

@test "destructive commands that are backgrounded or silenced are flagged for review" {
  decide "rm -rf build >/dev/null 2>&1"; asked "silenced destructive command"
  decide "rm -rf build &"; asked "backgrounded destructive command"
  decide "kill 4242 2>/dev/null"; asked "silenced"
  decide "rm -rf build"; allowed
  decide "ls >/dev/null 2>&1 &"; allowed
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

@test "other tools pass through; the hook can be switched off" {
  run "$SCRIPTS/lane-safety.sh" <<<'{"tool_name":"Edit","tool_input":{"file_path":"/etc/x"},"cwd":"/"}'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  WAAAGH_LANE_SAFETY=off decide "pkill -f x"; allowed
}

@test "the plugin wires the hook and the doctrine names every rule" {
  jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == "${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/scripts/lane-safety.sh")' "$ROOT/hooks/hooks.json" >/dev/null
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
