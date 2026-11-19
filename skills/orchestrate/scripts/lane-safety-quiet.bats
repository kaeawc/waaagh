#!/usr/bin/env bats
# lane-safety.sh asks only where a prompt carries information: signal-0 probes, literal-PID kills,
# BSD `sed -i ''`, Claude auto-memory writes, literal assignments behind `rm -r "$VAR"`, the
# Android local.properties setup copy and (opt-in) the owner's writes into sibling lane worktrees.
# Every case keeps its deny/ask counterpart beside it. Run: bats lane-safety-quiet.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR
  export HOME="$T/home" WAAAGH_LANE_TEMP="$T/scratch" ORCHESTRATE_STATE_DIR="$T/state"
  unset ANDROID_HOME ANDROID_SDK_ROOT WAAAGH_LANE_ROOT WAAAGH_LANE_ALLOW WAAAGH_PROTECTED_PATHS \
    WAAAGH_LANE_SAFETY ANDROID_SERIAL WAAAGH_OWNER_SIBLING_WORKTREES
  mkdir -p "$HOME/Library" "$T/scratch" "$T/main"
  git -C "$T/main" init -q
  git -C "$T/main" commit -q --allow-empty -m init
  git -C "$T/main" worktree add -q "$T/main/.claude/worktrees/lane" -b lane
  git -C "$T/main" worktree add -q "$T/main/.claude/worktrees/owner" -b owner
  MAIN="$T/main" LANE="$T/main/.claude/worktrees/lane" OWN="$T/main/.claude/worktrees/owner"
  mkdir -p "$LANE/scratch" "$LANE/android" "$OWN/scratch"
  register_lane "$LANE"
}

# decide CMD [CWD] [AGENT]: run the hook on a Bash payload; $output is the decision (empty = allow).
decide() {
  local payload
  payload=$(jq -cn --arg c "$1" --arg d "${2:-$LANE}" --arg a "${3:-}" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d} + (if $a == "" then {} else {agent_id: $a} end)')
  run "$SCRIPTS/lane-safety.sh" <<<"$payload"
  [ "$status" -eq 0 ]
}
allowed() { [ -z "$output" ] || { echo "expected allow, got: $output"; return 1; }; }
verdict() { jq -r '.hookSpecificOutput.permissionDecision' <<<"$output"; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output"; }
is() {
  [ "$(verdict)" = "$1" ] || { echo "expected $1, got: ${output:-allow}"; return 1; }
  [ -z "${2:-}" ] || [[ "$(reason)" == *"$2"* ]] || { echo "reason lacks '$2': $(reason)"; return 1; }
}

@test "signal-0 probes and kill -l are never asked or counted as kills" {
  decide 'while kill -0 79080 2>/dev/null; do sleep 30; done'; allowed
  decide 'until ! kill -0 30077 2>/dev/null; do sleep 10; done; echo done'; allowed
  decide 'kill -0 $(cat scratch/pid) 2>/dev/null && echo alive'; allowed
  decide 'kill -s 0 4242 >/dev/null 2>&1; kill -n 0 4242 2>/dev/null'; allowed
  decide 'kill -l >/dev/null'; allowed
  decide "timeout 500 bash -c 'while kill -0 8867 2>/dev/null; do sleep 10; done'; ps -axo pid,command | grep -c codex"; allowed
  decide 'kill -0 $(pgrep -f gradle) 2>/dev/null'; allowed
  # A real signal still is a kill: fed by a search, piped through xargs, or with a variable PID.
  decide 'kill -s TERM $(pgrep -f gradle)'; is deny "kill fed by a process search"
  decide 'pgrep x | xargs kill -0'; is deny "xargs kill"
  decide 'kill -s 9 $P 2>/dev/null'; is ask "silenced destructive command"
}

@test "a kill of literal PIDs above 1 is not asked when silenced, nor fed by a later ps check" {
  decide 'kill 4242 2>/dev/null'; allowed
  decide 'kill -9 4242 4243 >/dev/null 2>&1'; allowed
  decide 'kill -s TERM 4242 &>/dev/null || true'; allowed
  decide 'kill 94276 94275; sleep 1; ps -p 94276 | tail -1'; allowed
  decide 'kill 28847; sleep 3; ps -axo pid,ppid,command | grep -F sleeper'; allowed
  decide 'P=$(cat scratch/pid); ps -p $P -o command= | grep caffeinate >/dev/null && kill $P'; allowed
  # PIDs 0 and 1, process groups, job specs and variables keep the ask; backgrounding keeps it.
  decide 'kill 1 2>/dev/null'; is ask "silenced"
  decide 'kill 0 2>/dev/null'; is ask "silenced"
  decide 'kill -- -4242 2>/dev/null'; is ask "silenced"
  decide 'kill %1 2>/dev/null'; is ask "silenced"
  decide 'kill $P 2>/dev/null'; is ask "silenced"
  decide 'kill 4242 &'; is ask "backgrounded"
  decide 'kill -1 4242'; is deny "kill -1"
  # A variable kill beside a real process search stays denied.
  decide 'kill $P; ps aux | grep emu'; is deny "kill fed by a process search"
  decide 'ps -ef | grep emu; kill $P'; is deny "kill fed by a process search"
  decide 'ps -p 1 -A; kill $P'; is deny "kill fed by a process search"
  decide 'ps -p1 -o pid=; kill $P'; allowed
  decide 'ps --pid 1 -ww; kill $P'; allowed
}

@test "BSD sed -i '' takes the empty word as the suffix, not the script" {
  decide "sed -i '' '/18582/d' scratch/hold.txt"; allowed
  decide "sed -i '' 's/a/b/' $MAIN/f.sh"; is deny "sed -i $MAIN/f.sh"
  decide "sed -i '' '/x/d' $MAIN/f.sh" "$OWN"; is ask "sed -i $MAIN/f.sh"
}

@test "Claude auto-memory files are writable from every session" {
  local M="$HOME/.claude/projects/-Users-x-repo/memory"
  decide "cat >> $M/feedback_x.md <<'EOF'
note
EOF"; allowed
  decide "echo x > ~/.claude/projects/-p/memory/MEMORY.md" "$OWN"; allowed
  decide "echo x | tee $M/a.md" "$LANE" agent-1; allowed
  decide "echo x > $HOME/.claude/projects/-p/notes.md"; is deny "writes outside"
  decide "echo x > $HOME/.claude/projects/memory/x.md"; is deny "writes outside"
  decide "echo x > $HOME/.claude/projects/-p/sub/memory/x.md"; is deny "writes outside"
  decide "echo x > $HOME/.claude/projects/-p/memoryx"; is deny "writes outside"
  decide "rm -rf $M" "$LANE"; is deny "outside the lane worktree"
}

@test "rm -r of a variable holding a literal top-level assignment is judged by its real path" {
  decide 'B=$PWD/scratch/pd; rm -rf "$B"'; allowed
  decide 'W=$PWD
rm -rf $W/scratch/batch'; allowed
  decide 'B=$PWD/scratch; rm -rf ${B}/x'; allowed
  decide "O=$ORCHESTRATE_STATE_DIR/o__r/l1; rm -rf \$O/out"; allowed
  decide 'export B=$PWD/scratch/x; rm -rf $B'; allowed
  decide 'W=$PWD; S=$W/scratch; rm -rf $S/out'; allowed
  decide 'B=$PWD/scratch/pd; rm -rf "$B"' "$OWN"; allowed
  # The real path decides, so a protected or out-of-lane one is now named and denied.
  decide 'X=/etc/a Y=$PWD/scratch; rm -rf $X $Y'; is deny "rm -r \$X: protected path /etc"
  decide 'B=$HOME/Library; rm -rf $B'; is deny "protected path $HOME/Library"
  decide "B=$MAIN/src; rm -rf \$B"; is deny "rm -r \$B: outside the lane worktree"
  # Anything that may leave the variable other than the hook thinks keeps the unexpanded deny.
  local c
  for c in 'cd scratch && B=$PWD/x; rm -rf $B' \
    '[ -d x ] && B=$PWD/x; rm -rf $B' \
    'true | true; B=$PWD/x; rm -rf $B' \
    'B=$PWD/x | true; rm -rf $B' \
    'B=$PWD/x; read B; rm -rf $B' \
    'B=$PWD/x; B=$PWD/y; rm -rf $B' \
    'B=$PWD/x; for B in /etc; do rm -rf $B; done' \
    'B=$PWD/x; : ${B:=/etc}; rm -rf $B' \
    'B=$(mktemp -d); rm -rf $B' \
    "B=\$PWD/x; bash -c 'rm -rf \$B'" \
    'B=$PWD/x; source env.sh; rm -rf $B' \
    'B=$PWD/x; . ./env.sh; rm -rf $B' \
    '(B=$PWD/x); rm -rf $B' \
    'B=$PWD/x rm -rf $B' \
    'B=$PWD/x >log; rm -rf $B' \
    'if true; then B=$PWD/x; fi; rm -rf $B' \
    'cd "$D"; B=$PWD/x; rm -rf $B' \
    'cd nowhere; B=$PWD/x; rm -rf $B' \
    'B=; rm -rf $B/x' \
    'rm -rf $B; B=$PWD/x'; do
    decide "$c"; is deny "path built from a variable" || { echo "for: $c"; return 1; }
  done
}

@test "the Android local.properties setup copy into a linked worktree is allowed in the owner's session" {
  decide "cp $MAIN/android/local.properties $LANE/android/" "$OWN"; allowed
  decide "cd $LANE && cp ~/src/app/android/local.properties android/local.properties" "$OWN"; allowed
  decide "cp -p android/local.properties -t $LANE/android" "$OWN"; allowed
  # Any other file, target or copier, or a known lane, keeps the ask/deny.
  decide "cp $MAIN/android/local.properties $MAIN/android/" "$OWN"; is ask "writes outside"
  decide "cp $MAIN/secrets $LANE/android/" "$OWN"; is ask "writes outside"
  decide "cp $MAIN/android/local.properties $MAIN/x $LANE/android/" "$OWN"; is ask "writes outside"
  decide "cp $MAIN/android/local.properties $LANE/android/other.txt" "$OWN"; is ask "writes outside"
  decide "mv $MAIN/android/local.properties $LANE/android/" "$OWN"; is ask "writes outside"
  decide "cp $MAIN/android/local.properties $OWN/android/" "$LANE"; is deny "writes outside"
  decide "cp $MAIN/android/local.properties $LANE/android/" "$OWN" agent-1; is deny "writes outside"
}

@test "WAAAGH_OWNER_SIBLING_WORKTREES=allow lets the owner's session write into sibling lane worktrees" {
  # A cd into the sibling already makes it writable (enter_worktree); the knob covers absolute paths.
  decide "cd $LANE; echo x > scratch/build.log" "$OWN"; allowed
  decide "echo x > $LANE/scratch/build.log" "$OWN"; is ask "no registered lane"
  export WAAAGH_OWNER_SIBLING_WORKTREES=allow
  decide "cd $LANE; bun run build > scratch/build.log 2>&1; echo x | tee scratch-udid.txt" "$OWN"; allowed
  decide "sed -i '' s/a/b/ $LANE/scratch/f; rm -rf $LANE/scratch/batch" "$OWN"; allowed
  # Never the main checkout, the sibling's root, a non-worktree, a known lane or a subagent.
  decide "echo x > $MAIN/f" "$OWN"; is ask "writes outside"
  decide "rm -rf $LANE" "$OWN"; is ask "outside the lane worktree"
  decide "echo x > $T/other/f" "$OWN"; is ask "writes outside"
  decide "echo x > $OWN/f" "$LANE"; is deny "writes outside"
  decide "echo x > $LANE/f" "$OWN" agent-1; is deny "writes outside"
  WAAAGH_OWNER_SIBLING_WORKTREES=ask decide "echo x > $LANE/f" "$OWN"; is ask "writes outside"
}
