#!/usr/bin/env bats
# Gaps in lane-safety.bats: variable-spelled paths ($HOME, ${HOME}, $PWD, ${PWD}, $TMPDIR,
# ${TMPDIR} and their /sub forms), commands hidden behind prefixes (assignments, wrappers, sudo,
# env, nice, timeout, xargs, eval), the stdin/no-argument contract, and empty or "." targets.
# Run: bats lane-safety-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR
  export HOME="$T/home" WAAAGH_LANE_TEMP="$T/scratch" ORCHESTRATE_STATE_DIR="$T/state"
  unset ANDROID_HOME ANDROID_SDK_ROOT WAAAGH_LANE_ROOT WAAAGH_LANE_ALLOW WAAAGH_PROTECTED_PATHS WAAAGH_LANE_SAFETY ANDROID_SERIAL TMPDIR
  mkdir -p "$HOME/Library" "$T/scratch" "$T/main"
  git -C "$T/main" init -q
  git -C "$T/main" commit -q --allow-empty -m init
  git -C "$T/main" worktree add -q "$T/lane" -b lane
  LANE="$T/lane" MAIN="$T/main"
  register_lane "$LANE"
  FAILS=""
}

payload() { jq -cn --arg c "$1" --arg d "$2" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}'; }

# expect VERDICT CMD [CWD] [REASON]: VERDICT is allow|deny|ask. Mismatches are collected in $FAILS,
# so one table reports every failing row at once (done_ asserts there were none).
expect() {
  local want=$1 cmd=$2 cwd=${3:-$LANE} why=${4:-} out rc=0 got
  out=$("$SCRIPTS/lane-safety.sh" <<<"$(payload "$cmd" "$cwd")") || rc=$?
  if ((rc != 0)); then FAILS="$FAILS
[$cmd] exit $rc"; return 0; fi
  got=allow
  [ -z "$out" ] || got=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")
  if [ "$got" != "$want" ]; then FAILS="$FAILS
[$cmd] in $cwd: want $want, got $got $out"
  elif [ -n "$why" ] && [[ "$out" != *"$why"* ]]; then FAILS="$FAILS
[$cmd]: reason lacks '$why': $out"; fi
}
# expect_each_denied PREFIX...: one hook call with one line per prefix, "PREFIX rm -rf ~/.ssh/cN"
# (outside a lane); every line must be denied under its own marker cN.
expect_each_denied() {
  local text="" k=0 p out
  for p in "$@"; do k=$((k + 1)); text="$text$p rm -rf ~/.ssh/c$k
"; done
  out=$("$SCRIPTS/lane-safety.sh" <<<"$(payload "$text" "$MAIN")") || { FAILS="$FAILS
[prefix table] hook failed"; return 0; }
  k=0
  for p in "$@"; do
    k=$((k + 1))
    [[ "$out" == *"rm -r ~/.ssh/c$k: protected path $HOME/.ssh"* ]] || FAILS="$FAILS
[$p rm -rf ~/.ssh/c$k] not denied: $out"
  done
}
done_() { [ -z "$FAILS" ] || { echo "mismatches:$FAILS"; return 1; }; }
# unregister_lane: drop the lanes.tsv row, so the lane is the owner's own session (ask, not deny).
unregister_lane() { rm -f "$ORCHESTRATE_STATE_DIR/o__r/lanes.tsv"; }

@test "\$HOME, \${HOME}, \$PWD and \${PWD} spellings expand before the deletion and write checks" {
  expect deny  'rm -rf $HOME' "$MAIN" "protected path $HOME"
  expect deny  'rm -rf ${HOME}' "$MAIN" "protected path $HOME"
  expect deny  'rm -rf ${HOME}/Library' "$MAIN" "protected path $HOME/Library"
  expect deny  'rm -rf $HOME/Library' "$MAIN" "protected path $HOME/Library"
  expect allow 'rm -rf ${HOME}/src/x' "$MAIN"
  expect deny  'rm -rf $PWD' "$HOME" "protected path $HOME"
  expect deny  'rm -rf ${PWD}' "$HOME" "protected path $HOME"
  expect deny  'rm -rf $PWD/Library' "$HOME" "protected path $HOME/Library"
  expect deny  'rm -rf ${PWD}/Library' "$HOME" "protected path $HOME/Library"
  # In a lane: $PWD is the lane itself; below it is fine; climbing out is not.
  expect deny  'rm -rf $PWD' "$LANE" "lane worktree itself"
  expect deny  'rm -rf ${PWD}' "$LANE" "lane worktree itself"
  expect allow 'rm -rf $PWD/build' "$LANE"
  expect allow 'rm -rf ${PWD}/build' "$LANE"
  expect deny  'rm -rf ${PWD}/../main/build' "$LANE" "outside the lane worktree"
  # Writes.
  expect deny  'echo x > $HOME/notes' "$LANE" "writes outside the lane worktree"
  expect deny  'echo x > ${HOME}/notes' "$LANE" "writes outside"
  expect allow 'echo x > $PWD/notes' "$LANE"
  expect allow 'echo x > ${PWD}/notes' "$LANE"
  expect deny  'echo x >> ${PWD}/../main/notes' "$LANE" "writes outside"
  done_
}

@test "\$TMPDIR spellings expand only when TMPDIR is set" {
  export TMPDIR="$T/scratch"
  expect allow 'rm -rf $TMPDIR/x' "$LANE"
  expect allow 'rm -rf ${TMPDIR}/x' "$LANE"
  expect deny  'rm -rf $TMPDIR' "$LANE" "outside the lane worktree"
  expect deny  'rm -rf ${TMPDIR}' "$LANE" "outside the lane worktree"
  expect allow 'echo x > $TMPDIR/out' "$LANE"
  expect allow 'echo x > ${TMPDIR}/out' "$LANE"
  # A TMPDIR pointing at a protected root is judged by where it points.
  TMPDIR=$HOME expect deny 'rm -rf $TMPDIR' "$MAIN" "protected path $HOME"
  TMPDIR=$HOME expect deny 'rm -rf ${TMPDIR}/Library' "$MAIN" "protected path $HOME/Library"
  # Unset: the hook cannot expand it, so a lane refuses it and a non-lane lets it through.
  unset TMPDIR
  expect deny  'rm -rf $TMPDIR/x' "$LANE" "path built from a variable"
  expect deny  'rm -rf ${TMPDIR}/x' "$LANE" "path built from a variable"
  expect allow 'rm -rf $TMPDIR/x' "$MAIN"
  done_
}

@test "dot, empty and doubled-slash path parts normalise away; empty targets are skipped" {
  expect deny  "rm -rf $HOME/./Library" "$MAIN" "protected path $HOME/Library"
  expect deny  "rm -rf $T//home//Library/" "$MAIN" "protected path $HOME/Library"
  expect deny  "rm -rf ./Library" "$HOME" "protected path $HOME/Library"
  expect deny  "rm -rf ." "$HOME" "protected path $HOME"
  expect deny  "rm -rf ." "$LANE" "lane worktree itself"
  expect deny  "rm -rf ./" "$LANE" "lane worktree itself"
  expect allow "rm -rf ./build/./out" "$LANE"
  expect allow 'rm -rf ""' "$LANE"
  expect allow "rm -rf ''" "$HOME"
  expect allow 'echo x > ""' "$LANE"
  # find with no start path deletes under ".".
  expect deny  "find -name '*.o' -delete" "$LANE" "lane worktree itself"
  expect deny  "find -delete" "$HOME" "protected path $HOME"
  expect allow "find ./build -delete" "$LANE"
  done_
}

@test "commands behind assignments, wrappers and keywords are still judged" {
  expect_each_denied 'FOO=1' 'A=1 B_2=x' 'command' 'builtin' 'exec' 'nohup' 'time' 'noglob' '!' \
    'caffeinate' 'FOO=1 command' 'nohup time'
  expect deny  'FOO=1 rm -rf ~' "$MAIN" "protected path $HOME"
  expect deny  '{ rm -rf ~; }' "$MAIN" "protected path $HOME"
  expect deny  'if true; then rm -rf ~; fi' "$MAIN" "protected path $HOME"
  expect deny  'if false; then :; else rm -rf ~; fi' "$MAIN" "protected path $HOME"
  expect deny  'if false; then :; elif rm -rf ~; then :; fi' "$MAIN" "protected path $HOME"
  expect deny  'while rm -rf ~; do :; done' "$MAIN" "protected path $HOME"
  expect deny  'until false; do rm -rf ~; done' "$MAIN" "protected path $HOME"
  expect deny  'FOO=1 pkill java' "$MAIN" "pkill"
  expect deny  'FOO=1 tee ../main/x' "$LANE" "writes outside"
  # Not an assignment (bad name): it is the command word, and nothing destructive runs.
  expect allow 'a-b=1 rm -rf ~' "$MAIN"
  done_
}

@test "sudo/doas, env, nice and timeout options are skipped to find the command" {
  expect_each_denied 'sudo' 'sudo -u root' 'sudo -g wheel' 'sudo -C 5' 'sudo -h host' 'sudo -p pw:' 'sudo -E -H' \
    'sudo -n -u root -g wheel' 'doas -u root' \
    'env' 'env FOO=1' 'env -i' 'env -u FOO' 'env -C /' 'env -S x' 'env -i -u FOO BAR=1' \
    'nice' 'nice -n 5' 'nice -5' 'nice -n 5 nohup' \
    'timeout 5' 'timeout -s KILL 5' 'timeout -k 1 5' 'timeout --preserve-status 5' 'timeout -s TERM -k 2 10' \
    'gtimeout 5' 'sudo -u root env -u X timeout -k 1 5 nice -n 2'
  expect deny  'sudo -u root rm -rf ~' "$MAIN" "protected path $HOME"
  expect deny  'sudo -u root killall Simulator' "$MAIN" "never quit Simulator.app"
  expect deny  'env -u X sed -i s/a/b/ ../main/f' "$LANE" "sed -i ../main/f"
  # A wrapper with nothing after it: nothing to judge.
  expect allow 'sudo -u root' "$MAIN"
  expect allow 'timeout 5' "$MAIN"
  done_
}

@test "xargs options with and without values still reveal kill and rm -r" {
  local p
  for p in 'xargs' 'xargs -0' 'xargs -I {}' 'xargs -n 1' 'xargs -P 4' 'xargs -L 1' 'xargs -d ,' \
    'xargs -E END' 'xargs -s 100' 'xargs -a list.txt' 'xargs -r -t -n 1 -P 2' 'gxargs -n 1'; do
    expect deny "cat l | $p rm -rf" "$MAIN" "xargs rm -r"
  done
  for p in 'xargs -0' 'xargs -I {}' 'xargs -d ,' 'xargs -r -t -n 1 -P 2'; do
    expect deny "cat l | $p kill -9" "$MAIN" "xargs kill"
  done
  expect allow 'cat l | xargs -n 1 echo' "$MAIN"
  expect allow 'cat l | xargs -I {} rm {}' "$MAIN"
  done_
}

@test "eval and shell -c bodies are analysed; other shell forms are not" {
  expect deny  'eval rm -rf ~' "$MAIN" "protected path $HOME"
  expect deny  "eval 'rm -rf ~'" "$MAIN" "protected path $HOME"
  expect deny  'eval "cd ~ && rm -rf Library"' "$MAIN" "protected path"
  expect deny  "sh -c 'eval pkill node'" "$MAIN" "pkill"
  expect deny  "bash -xc 'rm -rf ~'" "$MAIN" "protected path $HOME"
  expect allow 'eval echo hi' "$MAIN"
  expect allow 'bash script.sh ~' "$MAIN"
  expect allow 'bash --norc -x run.sh' "$MAIN"
  done_
}

@test "arms that end without a verdict: cd, non-recursive rm, find without -delete, harmless tools" {
  # cd - leaves the cwd unknown (#383): a relative deletion after it is denied, an absolute one judged.
  expect deny  'cd - && rm -rf build' "$LANE" 'unknown after `cd -`'
  expect allow "cd - && rm -rf $LANE/build" "$LANE"
  expect allow 'cd && rm -rf src/x' "$MAIN"
  expect deny  'cd && rm -rf Library' "$MAIN" "protected path $HOME/Library"
  expect allow 'rm -f ~/x' "$MAIN"
  # A non-recursive rm is judged too (#384): a protected root itself is refused.
  expect deny  'rm ~' "$MAIN" "protected path $HOME"
  expect allow 'find ~ -name x -print' "$MAIN"
  expect allow 'find ~ -exec ls {} ;' "$MAIN"
  expect deny  'find ~/Library -exec /bin/rm {} ;' "$MAIN" "protected path"
  expect allow "osascript -e 'tell app \"Finder\" to quit'" "$MAIN"
  expect allow 'osascript -e simulator' "$MAIN"
  expect allow 'xcrun simctl list' "$MAIN"
  expect allow 'xcrun xcodebuild -version' "$MAIN"
  expect allow 'simctl shutdown ABC-123' "$MAIN"
  expect deny  'simctl erase all' "$MAIN" "simctl erase all"
  expect allow 'adb devices' "$MAIN"
  expect allow 'adb -s emulator-5554 emu kill' "$MAIN"
  ANDROID_SERIAL=emulator-5554 expect allow 'adb emu kill' "$MAIN"
  expect allow 'avdmanager list avd' "$MAIN"
  done_
}

@test "touch, truncate and sed -i targets are write-checked in a lane" {
  expect deny  'touch ../main/f' "$LANE" "touch ../main/f"
  expect deny  'touch -c $HOME/f' "$LANE" "writes outside"
  expect allow 'touch -c ./f other' "$LANE"
  expect deny  'truncate -s 0 ../main/log' "$LANE" "truncate"
  expect allow 'truncate -s 0 log' "$LANE"
  expect allow 'touch ../main/f' "$MAIN"
  expect deny  'sed -i -e s/a/b/ -E ../main/f' "$LANE" "sed -i ../main/f"
  expect deny  'sed -i.bak --expression s/a/b/ ../main/f' "$LANE" "sed -i ../main/f"
  expect deny  'gsed -i -f script.sed ../main/f' "$LANE" "gsed -i ../main/f"
  expect deny  'sed -ni s/a/b/ ../main/f' "$LANE" "sed -i ../main/f"
  expect deny  'perl -pi -e s/a/b/ ../main/f' "$LANE" "perl -i ../main/f"
  expect allow 'sed -i s/a/b/ local.txt' "$LANE"
  expect allow 'sed -n p ../main/f' "$LANE"
  expect allow 'perl -ne print ../main/f' "$LANE"
  done_
}

@test "the stdin contract: no arguments, non-Bash tools, empty commands, unreadable payloads" {
  run "$SCRIPTS/lane-safety.sh" extra <<<"$(payload 'rm -rf ~' "$MAIN")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no arguments"* ]]
  [[ "$output" == *"Usage: lane-safety.sh"* ]]
  [[ "$output" != *permissionDecision* ]]
  # With no argument (or an empty one) the payload is read from stdin.
  run "$SCRIPTS/lane-safety.sh" <<<"$(payload 'rm -rf ~' "$MAIN")"
  [ "$status" -eq 0 ]; [[ "$output" == *'"permissionDecision":"deny"'* ]]
  run "$SCRIPTS/lane-safety.sh" "" <<<"$(payload 'rm -rf ~' "$MAIN")"
  [ "$status" -eq 0 ]; [[ "$output" == *'"permissionDecision":"deny"'* ]]
  run "$SCRIPTS/lane-safety.sh" <<<'{"tool_name":"Read","tool_input":{"command":"rm -rf ~"}}'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run "$SCRIPTS/lane-safety.sh" <<<'{"tool_name":"Bash","tool_input":{"command":""}}'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run "$SCRIPTS/lane-safety.sh" <<<'{"tool_name":"Bash","tool_input":{}}'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run "$SCRIPTS/lane-safety.sh" <<<'not json {'
  [ "$status" -eq 1 ]; [[ "$output" == *"unreadable payload"* ]]
  run "$SCRIPTS/lane-safety.sh" </dev/null
  [ "$status" -eq 0 ]; [ -z "$output" ]
  # No cwd in the payload: the hook's own working directory is the base.
  cd "$HOME"
  run "$SCRIPTS/lane-safety.sh" <<<'{"tool_name":"Bash","tool_input":{"command":"rm -rf Library"}}'
  [ "$status" -eq 0 ]; [[ "$output" == *"protected path $HOME/Library"* ]]
  WAAAGH_LANE_SAFETY=off run "$SCRIPTS/lane-safety.sh" <<<"$(payload 'rm -rf ~' "$MAIN")"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "rm without -r and unlink: protected roots, forbidden roots and the lane bounds (#384)" {
  mkdir -p "$HOME/.ssh" "$LANE/src"
  printf 'k\n' >"$HOME/.ssh/id"
  printf 'b\n' >"$HOME/.bashrc"
  touch "$LANE/a.log" "$LANE/b.log"
  ln -s "$HOME" "$LANE/hm"
  # A protected root itself is refused everywhere; a file below one is judged as a write.
  expect deny  'rm -f ~/.ssh' "$MAIN" "rm ~/.ssh: protected path $HOME/.ssh"
  expect deny  'rm /' "$MAIN" "protected path /"
  expect allow 'rm -f ~/.ssh/known_hosts' "$MAIN"
  expect deny  'rm -f ~/.ssh/known_hosts' "$LANE" "outside the lane worktree"
  expect deny  "rm -f $HOME/.bashrc" "$LANE" "rm $HOME/.bashrc: outside the lane worktree"
  expect deny  "unlink $HOME/.bashrc" "$LANE" "unlink $HOME/.bashrc: outside the lane worktree"
  expect deny  "rm -f ../main/x" "$LANE" "outside the lane worktree"
  # Through a lane link: judged by the entry rm removes.
  expect deny  "rm -f $LANE/hm/.ssh/id" "$LANE" "(through a symlink: "
  expect deny  "rm hm/.bashrc" "$LANE" "(through a symlink: "
  expect deny  "unlink $LANE/hm/.bashrc" "$LANE" "(through a symlink: "
  # In the lane, temp dirs, the link itself, a variable: allowed, no prompt.
  expect allow 'rm -f a.log' "$LANE"
  expect allow 'rm a.log b.log' "$LANE"
  expect allow 'rm -f src/x' "$LANE"
  expect allow "rm -f $T/scratch/x" "$LANE"
  expect allow 'rm -f hm' "$LANE"
  expect allow 'unlink hm' "$LANE"
  expect allow 'rm -f "$X"' "$LANE"
  expect allow "rm -f $HOME/.bashrc" "$MAIN"
  # The owner's own worktree session asks instead of denying.
  unregister_lane
  expect ask   "rm -f $HOME/.bashrc" "$LANE" "no registered lane"
  done_
}

@test "a write through a link in the lane is judged by its real target, /dev and temp dirs aside (#384)" {
  mkdir -p "$T/scratch/b" "$LANE/build"
  ln -s "$HOME" "$LANE/hm"
  ln -s / "$LANE/root"
  ln -s "$T/scratch" "$LANE/tmpl"
  ln -s /dev/null "$LANE/devnull"
  ln -s "$T/scratch/b" "$LANE/build/out"
  expect deny  "echo x > $LANE/hm/.bashrc" "$LANE" "writes outside the lane worktree"
  expect deny  'echo x > hm/.bashrc' "$LANE" "(through a symlink: "
  expect deny  'echo x >> root/etc/hosts' "$LANE" "(through a symlink: "
  expect deny  'touch hm/f' "$LANE" "touch hm/f"
  expect deny  'cp x hm/' "$LANE" "cp hm/"
  expect deny  'printf x | tee hm/.zshrc' "$LANE" "tee hm/.zshrc"
  expect allow 'echo x > devnull' "$LANE"
  expect allow 'echo x > /dev/null; echo y > /dev/fd/2; echo z > /dev/stderr' "$LANE"
  expect allow 'echo x > tmpl/f' "$LANE"
  expect allow 'echo x > build/out/f' "$LANE"
  expect allow 'echo x > build/f' "$LANE"
  unregister_lane
  expect ask   'echo x > hm/.bashrc' "$LANE" "(through a symlink: "
  done_
}

@test "a glob in any path part is expanded and every match judged (#384)" {
  mkdir -p "$HOME/.ssh" "$LANE/build/o" "$LANE/many"
  printf 'b\n' >"$HOME/.bashrc"
  touch "$LANE/a.log" "$LANE/b.log" "$LANE/build/o/x"
  ln -s "$HOME" "$LANE/hm"
  expect deny  "rm -rf $LANE/*/.ssh" "$LANE" "(glob match $LANE/hm/.ssh): protected path"
  expect deny  "rm -rf $LANE/h?/.ssh" "$LANE" "protected path"
  expect deny  'rm -rf h?/' "$LANE" "protected path"
  expect deny  "rm -f $LANE/h*/.bashrc" "$LANE" "(through a symlink: "
  expect deny  'echo x > h[m]/.bashrc' "$LANE" "(glob match hm/.bashrc)"
  # Globs inside the lane, and a glob that matches nothing.
  expect allow 'rm -rf build/*' "$LANE"
  expect allow 'rm -f *.log' "$LANE"
  expect allow "rm -rf $LANE/build/*/x" "$LANE"
  expect allow 'rm -rf nomatch*/x' "$LANE"
  expect allow 'echo x > b*/o/x' "$LANE"
  # More matches than the hook judges: name them.
  local i
  for ((i = 1; i <= 101; i++)); do mkdir -p "$LANE/many/d$i"; touch "$LANE/many/d$i/x"; done
  expect deny  'rm -rf many/*/x' "$LANE" "glob matches too many paths"
  expect allow 'rm -rf many/*' "$LANE"
  expect ask   "rm -rf $LANE/many/*/x" "$MAIN" "glob matches too many paths"
  unregister_lane
  expect ask   'rm -rf many/*/x' "$LANE" "glob matches too many paths"
  done_
}
