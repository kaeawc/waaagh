#!/usr/bin/env bats
# The orchestrator's own checkout is forbidden to lanes (#218). A lane subagent inherits the
# orchestrator's cwd; lane-safety.sh refuses its writes, deletions, mutating git and Edit/Write calls
# under every root named in $WAAAGH_LANE_FORBID or <state root>/lane-forbidden, while the
# orchestrator's own calls and the lane's own nested worktree stay free. Every lane brief names that
# path through {{FORBIDDEN}}. Run: bats lane-forbidden.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  T=$BATS_TEST_TMPDIR
  export HOME="$T/home" WAAAGH_LANE_TEMP="$T/scratch" ORCHESTRATE_STATE_DIR="$T/state"
  unset CDPATH ANDROID_HOME ANDROID_SDK_ROOT WAAAGH_LANE_ROOT WAAAGH_LANE_ALLOW WAAAGH_PROTECTED_PATHS \
    WAAAGH_LANE_SAFETY WAAAGH_LANE_FORBID ANDROID_SERIAL TMPDIR
  mkdir -p "$HOME" "$T/scratch" "$T/state" "$T/main"
  git -C "$T/main" init -q
  git -C "$T/main" commit -q --allow-empty -m init
  git -C "$T/main" worktree add -q "$T/orch" -b orch
  git -C "$T/main" worktree add -q "$T/lane" -b lane
  git -C "$T/main" worktree add -q "$T/main/.claude/worktrees/l1" -b l1
  git -C "$T/main" worktree add -q "$T/main/.claude/worktrees/l2" -b l2
  MAIN="$T/main" ORCH="$T/orch" LANE="$T/lane" NEST="$T/main/.claude/worktrees/l1" SIB="$T/main/.claude/worktrees/l2"
  FAILS=""
}

forbid() { printf '%s\n' "$@" >"$T/state/lane-forbidden"; }

# expect VERDICT TOOL TEXT CWD AGENT [REASON]: TOOL is Bash (TEXT a command) or an edit tool (TEXT
# its file path); AGENT is the payload's agent_id ("" for the orchestrator's own call). Mismatches
# collect in $FAILS so one table reports every failing row (done_ asserts there were none).
expect() {
  local want=$1 tool=$2 text=$3 cwd=$4 agent=$5 why=${6:-} p out rc=0 got
  p=$(jq -cn --arg t "$tool" --arg x "$text" --arg d "$cwd" --arg a "$agent" '{tool_name: $t, cwd: $d}
    + (if $t == "Bash" then {tool_input: {command: $x}} elif $t == "NotebookEdit" then {tool_input: {notebook_path: $x}}
       else {tool_input: {file_path: $x}} end) + (if $a == "" then {} else {agent_id: $a} end)')
  out=$("$SCRIPTS/lane-safety.sh" <<<"$p") || rc=$?
  if ((rc != 0)); then FAILS="$FAILS
[$tool $text] exit $rc"; return 0; fi
  got=allow
  [ -z "$out" ] || got=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")
  if [ "$got" != "$want" ]; then FAILS="$FAILS
[$tool $text] in $cwd agent=$agent: want $want, got $got $out"
  elif [ -n "$why" ] && [[ "$out" != *"$why"* ]]; then FAILS="$FAILS
[$tool $text]: reason lacks '$why': $out"; fi
}
done_() { [ -z "$FAILS" ] || { echo "$FAILS"; return 1; }; }

@test "a lane subagent started in the orchestrator's main checkout cannot change it" {
  forbid "$MAIN"
  for c in "echo x > f" "echo x >> $MAIN/src/a.kt" "tee notes.txt" "sed -i s/a/b/ build.gradle" \
    "cp /etc/hosts ." "rm -rf src" "find . -name '*.o' -delete" "git commit -m wip" \
    "git checkout -b mine" "git switch other" "git pull" "git stash" "git reset --hard" \
    "git add -A" "git -c user.name=x merge origin/main" "cd $MAIN && git rebase origin/main" \
    "git -C $MAIN restore ." "git --work-tree=$MAIN clean -fd" \
    "git checkout pr-5" "git checkout --detach" "git branch -D pr-5" "git branch --delete pr-5" \
    "git branch -m old new" "git branch -f main origin/main" "git branch -rd origin/x"; do
    expect deny Bash "$c" "$MAIN" agent-1 "orchestrator's checkout $MAIN"
  done
  # The reviewer's read-only ways to see another ref, and its own detached worktree (#317).
  for c in "git status" "git log -1" "git diff" "git fetch origin" "git worktree add $T/new -b new" \
    "git show origin/pr-5:src/a.kt" "git diff origin/main...origin/pr-5" "git branch --list 'pr-*'" \
    "git branch -vv" "git branch --contains HEAD" "git worktree add --detach $T/scratch/review abc123" \
    "git branch -a" "cat f" "echo x > $T/scratch/out" "git -C $LANE commit -m wip" \
    "cd $LANE && echo x > f" "echo ok"; do
    expect allow Bash "$c" "$MAIN" agent-1
  done
  done_
}

@test "the orchestrator's own calls stay free, in its main checkout and in its linked worktree" {
  forbid "$MAIN" "$ORCH"
  for c in "echo x > f" "git commit -m wip" "git pull" "rm -rf build"; do
    expect allow Bash "$c" "$MAIN" ""
    expect allow Bash "$c" "$ORCH" ""
  done
  expect allow Edit "$ORCH/a.kt" "$ORCH" ""
  # the same calls from a subagent in that linked worktree are refused
  expect deny Bash "echo x > f" "$ORCH" agent-2 "orchestrator's checkout $ORCH"
  expect deny Bash "git checkout main" "$ORCH" agent-2
  expect deny Edit "$ORCH/a.kt" "$ORCH" agent-2
  done_
}

@test "a lane in its own worktree may not reach into the orchestrator's checkout" {
  forbid "$ORCH"
  expect deny Bash "git -C $ORCH reset --hard" "$LANE" "" "orchestrator's checkout $ORCH"
  expect deny Bash "echo x > $ORCH/f" "$LANE" "" "orchestrator's checkout $ORCH"
  expect deny Bash "rm -rf $ORCH/build" "$LANE" ""
  expect deny Bash "git worktree remove --force $ORCH" "$LANE" ""
  expect deny Edit "$ORCH/src/a.kt" "$LANE" ""
  expect allow Bash "git commit -m wip" "$LANE" ""
  expect allow Bash "echo x > f" "$LANE" ""
  expect allow Bash "git -C $ORCH status" "$LANE" ""
  expect allow Edit "$LANE/src/a.kt" "$LANE" ""
  done_
}

@test "a lane worktree nested in the forbidden checkout keeps its own tree, not its siblings'" {
  forbid "$MAIN"
  expect allow Bash "echo x > f" "$NEST" agent-3
  expect allow Bash "git commit -m wip" "$NEST" agent-3
  expect allow Bash "rm -rf build" "$NEST" agent-3
  expect allow Write "$NEST/a.kt" "$NEST" agent-3
  expect allow Write "src/a.kt" "$NEST" agent-3
  expect deny Write "$MAIN/a.kt" "$NEST" agent-3
  expect deny Write "../l2/a.kt" "$NEST" agent-3
  expect deny Bash "echo x > $SIB/f" "$NEST" agent-3
  expect deny Bash "git -C $MAIN checkout main" "$NEST" agent-3
  expect deny Bash "rm -rf $T/main" "$NEST" agent-3
  expect deny Bash "rm -rf $T/*" "$NEST" agent-3
  done_
}

@test "a symlink inside the nested lane cannot reach the forbidden checkout (#380)" {
  forbid "$MAIN"
  printf 'x\n' >"$MAIN/README"
  ln -s "$MAIN" "$NEST/flnk"
  ln -s "$MAIN/README" "$NEST/fl"
  ln -s "$MAIN/new.txt" "$NEST/dangling"
  for c in "rm -rf $NEST/flnk/README" "echo x > $NEST/flnk/f" "echo x > flnk/f" "rm -rf flnk/src" \
    "echo x > $NEST/flnk/new/dir/f" "echo x > $NEST/fl" "echo x >> fl" "echo x > dangling" \
    "rm -rf $NEST/flnk" "rm -rf $NEST/fl"; do
    expect deny Bash "$c" "$NEST" agent-3 "orchestrator's checkout $MAIN"
  done
  expect deny Write "$NEST/flnk/a.kt" "$NEST" agent-3 "orchestrator's checkout $MAIN"
  expect deny Write "fl" "$NEST" agent-3 "orchestrator's checkout $MAIN"
  done_
}

@test "a nested lane's own writes and deletions stay allowed through every spelling (#380)" {
  forbid "$MAIN"
  mkdir -p "$NEST/build" "$NEST/src"
  P=$(cd "$NEST" && pwd -P)
  spellings=("$NEST" "$P")
  # macOS: the temp dir is /var/folders/... and its physical path /private/var/folders/...
  case "$P" in /private/var/*) spellings+=("${P#/private}") ;; esac
  case "$NEST" in /var/*) spellings+=("/private$NEST") ;; esac
  for s in "${spellings[@]}"; do
    for cwd in "$NEST" "$s"; do
      for c in "echo x > $s/f" "echo x > $s/new/dir/f" "rm -rf $s/build" "rm -rf $s/src/a.kt" \
        "echo x > f" "rm -rf build"; do
        expect allow Bash "$c" "$cwd" agent-3
      done
      expect allow Write "$s/src/a.kt" "$cwd" agent-3
    done
  done
  # A symlink to the lane itself, inside the lane or in the temp dir, deletes as before.
  ln -s "$NEST" "$NEST/self"
  ln -s "$NEST" "$T/scratch/tolane"
  expect allow Bash "rm -rf $NEST/self" "$NEST" agent-3
  expect allow Bash "rm $T/scratch/tolane" "$NEST" agent-3
  expect allow Bash "echo x > $NEST/self/f" "$NEST" agent-3
  done_
}

@test "a .. after a symlink in the nested lane climbs from the link's target, as the OS does (#380)" {
  forbid "$MAIN"
  mkdir -p "$MAIN/sub/inner" "$MAIN/src"
  printf 'x\n' >"$MAIN/README"
  ln -s "$MAIN/sub" "$NEST/sl"
  for c in "echo x > $NEST/sl/../README" "rm -rf $NEST/sl/../src" "echo x > sl/../README" \
    "cd sl && echo x > ../README" "echo x > $NEST/sl/inner/../../README"; do
    expect deny Bash "$c" "$NEST" agent-3 "orchestrator's checkout"
  done
  expect deny Write "$NEST/sl/../README" "$NEST" agent-3 "orchestrator's checkout"
  # A .. through no symlink, or one that climbs back to the same place, stays lexical.
  mkdir -p "$NEST/src/a"
  expect allow Bash "echo x > $NEST/src/a/../f" "$NEST" agent-3
  expect allow Bash "echo x > $NEST/sl/../.claude/worktrees/l1/f" "$NEST" agent-3
  done_
}

@test "a cd target's .. is logical, as the shell applies it; cd -P is physical (#380)" {
  forbid "$MAIN"
  mkdir -p "$MAIN/sub" "$MAIN/src" "$T/scratch/a/b/c/d"
  printf 'x\n' >"$MAIN/README"
  ln -s "$T/scratch/a/b/c/d" "$NEST/esc"
  ln -s "$MAIN/sub" "$NEST/sl"
  # esc/.. is the lane, not $T/scratch/a/b/c: four .. from esc land in the checkout.
  for c in "cd esc/../../../.. && rm -rf src" "cd esc && cd ../../../.. && rm -rf src" \
    "cd esc && cd ../../../.. && echo x > README" "cd esc/../../../.. && echo x > README" \
    "pushd esc/../../../.. && rm -rf src" "cd -P sl/.. && echo x > README" "cd -P sl/.. && rm -rf src" \
    "cd sl && echo x > ../README"; do
    expect deny Bash "$c" "$NEST" agent-3 "orchestrator's checkout"
  done
  # sl/.. is the lane: these act inside it. A file operand still walks as the OS does.
  for c in "cd sl/.. && rm -rf src" "cd sl && cd .. && echo x > f" "cd sl/.. && echo x > f" \
    "cd -P esc && cd .. && rm -rf x" "cd esc && echo x > f" "cd esc && rm -rf ../x"; do
    expect allow Bash "$c" "$NEST" agent-3
  done
  done_
}

@test "after popd, pushd ±N/-n/swap, cd - or cd -L -P the cwd is unknown: relative writes and deletes are denied (#383)" {
  forbid "$MAIN"
  mkdir -p "$MAIN/sub" "$MAIN/src" "$T/scratch/a/b/c/d" "$NEST/d1/d2/d3" "$NEST/src/build"
  printf 'x\n' >"$MAIN/README"
  ln -s "$T/scratch/a/b/c/d" "$NEST/esc"
  ln -s "$MAIN/sub" "$NEST/sl"
  # Each leaves the shell back in the lane, where ../../../ is the checkout.
  # popd returns to the directory pushd left (#385), the lane, so these are judged from there.
  for c in "pushd d1/d2/d3 && popd && rm -rf ../../../src" "pushd d1/d2/d3; popd; echo x > ../../../README"; do
    expect deny Bash "$c" "$NEST" agent-3 "orchestrator's checkout"
  done
  for c in "pushd d1/d2/d3 && pushd && rm -rf ../../../src" "pushd d1/d2/d3 && pushd +1 && rm -rf ../../../src" \
    "pushd d1/d2/d3 && pushd -n d1 && rm -rf ../../../src" "cd d1 && cd - && rm -rf ../../../src" \
    "popd && cd d1 && rm -rf x" "popd && find . -delete" "popd && git -C . commit -m x"; do
    expect deny Bash "$c" "$NEST" agent-3 "the working directory is unknown after"
  done
  # A ~N, ~+N or ~- target, or one the hook cannot expand ($OLDPWD, $(dirs …)), is the stack again.
  for c in "pushd d1/d2/d3 && cd ~1 && rm -rf ../../../src" "pushd d1/d2/d3 && cd ~+1 && rm -rf ../../../src" \
    "pushd d1/d2/d3 && pushd ~1 && rm -rf ../../../src" "cd d1/d2/d3 && cd ~- && rm -rf ../../../src" \
    'cd d1/d2/d3 && cd $OLDPWD && rm -rf ../../../src' 'pushd d1/d2/d3 && cd "$(dirs -l +1)" && rm -rf ../../../src'; do
    expect deny Bash "$c" "$NEST" agent-3 "the working directory is unknown after"
  done
  # A plain ~ or ~/x target is known: judged as that path (outside the lane), not as lost.
  for c in "cd ~ && rm -rf x" "cd ~/x && rm -rf y"; do
    expect deny Bash "$c" "$NEST" agent-3 "outside the lane worktree"
  done
  # bash takes the last of -L/-P, zsh takes -P: the hook cannot know which the shell runs.
  for c in "cd -P -L sl/.. && rm -rf src" "cd -PL esc/../../../.. && rm -rf src" "cd -L -P sl/.. && rm -rf src"; do
    expect deny Bash "$c" "$NEST" agent-3 "the working directory is unknown after"
  done
  # A deletion before popd, an absolute path after it, or a cd to an absolute path stays allowed.
  for c in "pushd src && rm -rf build && popd" "pushd d1 && popd && rm -rf $NEST/src/build" \
    "pushd d1 && popd && cd $NEST && rm -rf src/build" "popd && echo x > $NEST/f" \
    "cd d1 && rm -rf d2/x && echo x > f" "pushd d1/d2/d3 && rm -rf x"; do
    expect allow Bash "$c" "$NEST" agent-3
  done
  done_
}

@test "the hook follows a cd only where the shell is sure to run it in this shell (#385)" {
  forbid "$MAIN"
  mkdir -p "$MAIN/src" "$NEST/d1/d2/d3" "$NEST/l1" "$NEST/src/build"
  # Each payload of #385 and its variants: the shell stays in (or returns to) the lane, where
  # ../../../ is the checkout, while a hook that trusted the cd would judge from d1/d2/d3.
  # A subshell's cd is undone at its `)`, so the deletion is judged from the lane (#385).
  for c in "( cd d1/d2/d3 ); rm -rf ../../../src" "(cd d1/d2/d3) && rm -rf ../../../src" \
    "( cd d1 && cd d2/d3 ) ; echo x > ../../../README" "echo \$(rm -rf ../../../src); cd d1/d2/d3"; do
    expect deny Bash "$c" "$NEST" agent-3 "orchestrator's checkout"
  done
  for c in "cd l1 .. && rm -rf ../src" "cd nonexist/a/b || rm -rf ../../../src" \
    "cd nonexist/a/b; rm -rf ../../../src" "cd nonexist/a/b && true; rm -rf ../../../src" \
    "cd nonexist/a/b && true || rm -rf ../../../src" "cd nonexist/a/b && (true) || rm -rf ../../../src" \
    "rm -rf d1/x; cd d1/d2/d3; rm -rf ../../../src" "./build.sh; cd d1/d2/d3; rm -rf ../../../src" \
    "if false; then cd d1/d2/d3; fi; rm -rf ../../../src" "for x in 1; do cd d1/d2/d3; done; echo x > ../../../README" \
    "case x in y) cd d1/d2/d3;; esac; rm -rf ../../../src" "f() { cd d1/d2/d3; }; f; rm -rf ../../../src" \
    "cd d1/d2/d3 | cat; rm -rf ../../../src" "echo | cd d1/d2/d3; rm -rf ../../../src" \
    "cd d1/d2/d3 & rm -rf ../../../src" "cd d1/d2/d3 && true & rm -rf ../../../src" \
    "eval cd d1/d2/d3; rm -rf ../../../src" "eval 'cd ../../..'; rm -rf src" \
    "touch nf; mkdir -p nf/a/b; cd nf/a/b; rm -rf ../../../src" "mkdir n1/n2; cd n1/n2; rm -rf ../../../src" \
    "pushd d1 && cd d2 && popd && rm -rf ../../../src" "cd d1/d2/d3 && pushd -n d1 && popd && rm -rf x"; do
    expect deny Bash "$c" "$NEST" agent-3 "the working directory is unknown after"
  done
  # CDPATH (from the environment or the command) can send a relative cd elsewhere: bash looks there
  # before the current directory. A ./ or ../ or absolute target is not searched.
  for c in "CDPATH=$MAIN cd src && rm -rf build" "export CDPATH=$MAIN; cd src && rm -rf build" \
    "cdpath=($MAIN); cd src && rm -rf build"; do
    expect deny Bash "$c" "$NEST" agent-3 "CDPATH"
  done
  export CDPATH=$MAIN
  expect deny Bash "cd src && rm -rf build" "$NEST" agent-3 "CDPATH"
  expect allow Bash "cd ./src && rm -rf build" "$NEST" agent-3
  expect allow Bash "cd $NEST/src && rm -rf build" "$NEST" agent-3
  unset CDPATH
  # The friction #383 added and #385's review asked to lift: a subshell's pushd/popd or cd -, and
  # the directory stack within one command.
  for c in "(pushd d1 && popd) && rm -rf src/build" "(cd d1 && cd -) && rm -rf src/build" \
    "pushd d1 && ./build.sh; popd; echo ok > out.txt" "pushd d1 && popd && rm -rf src/build" \
    "pushd d1 && pushd d2 && popd && popd && rm -rf src/build" "pushd nonexist && ./b.sh; popd; rm -rf src/build" \
    "cd nonexist || exit 1; rm -rf x" "cd d1/d2/d3 || return; echo x > f" "cd d1/d2/d3; rm -rf x" \
    "cd d1/d2/d3 && ./build.sh || rm -rf x" "if [ -d d1 ]; then cd d1 && rm -rf x; fi" \
    "cd d1 && cd d2 && cd d3 && rm -rf x" "( cd d1/d2/d3 && rm -rf x ); rm -rf src/build" \
    "cd src && echo \$(rm -rf build) && rm -rf x" "mkdir -p out/a; cd out/a; echo x > f" \
    "mkdir -p $NEST/scratch; cd $NEST/scratch; echo x > f" "mkdir new; cd new; rm -rf x" "mkdir -pm 755 o2/b; cd o2; rm -rf x"; do
    expect allow Bash "$c" "$NEST" agent-3
  done
  done_
}

@test "a .. inside a symlink's target in the nested lane resolves as the OS does (#380)" {
  forbid "$MAIN"
  mkdir -p "$MAIN/sub"
  printf 'x\n' >"$MAIN/README"
  ln -s "$MAIN/sub" "$NEST/sl"
  ln -s sl/../README "$NEST/rel"
  expect deny Bash "echo x > $NEST/rel" "$NEST" agent-3 "orchestrator's checkout"
  expect deny Bash "echo x >> rel" "$NEST" agent-3 "orchestrator's checkout"
  expect deny Write "$NEST/rel" "$NEST" agent-3 "orchestrator's checkout"
  done_
}

@test "a symlink in the nested lane to outside every forbidden root follows the lane rules (#380)" {
  forbid "$MAIN"
  mkdir -p "$T/scratch/b" "$NEST/scratch/b" "$T/elsewhere"
  ln -s "$T/scratch" "$NEST/tmpl"
  ln -s scratch/b "$NEST/build"
  ln -s "$T/elsewhere" "$NEST/out"
  for c in "echo x > $NEST/tmpl/f" "rm -rf $NEST/tmpl/x" "rm -rf $NEST/tmpl" "echo x > tmpl/f" \
    "echo x > $NEST/build/f" "rm -rf $NEST/build/x" "rm -rf build"; do
    expect allow Bash "$c" "$NEST" agent-3
  done
  expect allow Write "$NEST/tmpl/f" "$NEST" agent-3
  expect allow Write "$NEST/build/f" "$NEST" agent-3
  # Outside the lane and the temp dirs: refused as outside the lane, never as the checkout.
  expect deny Bash "rm -rf $NEST/out/x" "$NEST" agent-3 "outside the lane worktree"
  for c in "rm -rf $NEST/tmpl/x" "echo x > $NEST/build/f" "rm -rf $NEST/out/x"; do
    run "$SCRIPTS/lane-safety.sh" <<<"$(jq -cn --arg x "$c" --arg d "$NEST" '{tool_name: "Bash", cwd: $d, agent_id: "agent-3", tool_input: {command: $x}}')"
    [[ "$output" != *"orchestrator's checkout"* ]] || FAILS="$FAILS
[$c]: names the checkout: $output"
  done
  done_
}

@test "edit tools: Edit, Write, MultiEdit and NotebookEdit; relative paths resolve against cwd" {
  forbid "$MAIN"
  for t in Edit Write MultiEdit NotebookEdit; do
    expect deny "$t" "src/a.kt" "$MAIN" agent-4 "$t src/a.kt"
    expect allow "$t" "$T/scratch/a.kt" "$MAIN" agent-4
  done
  expect allow Edit "src/a.kt" "$MAIN" ""
  expect allow Read "$MAIN/a.kt" "$MAIN" agent-4
  done_
}

@test "sources: the env list, the state file with comments, blank lines and ~; none means no change" {
  expect allow Bash "echo x > f" "$MAIN" agent-5
  expect allow Edit "$MAIN/a.kt" "$MAIN" agent-5
  printf '# orchestrator checkout\n\n~/repo\nrelative/ignored\n/\n' >"$T/state/lane-forbidden"
  mkdir -p "$HOME/repo"
  expect deny Bash "echo x > $HOME/repo/f" "$T/scratch" agent-5 "orchestrator's checkout $HOME/repo"
  expect allow Bash "echo x > $T/scratch/f" "$T/scratch" agent-5
  expect allow Bash "echo x > $MAIN/f" "$T/scratch" agent-5
  rm "$T/state/lane-forbidden"
  export WAAAGH_LANE_FORBID="$T/nowhere:$MAIN"
  expect deny Bash "git commit -m x" "$MAIN" agent-5
  expect allow Bash "git commit -m x" "$MAIN" ""
  done_
}

@test "the physical path of a forbidden root is forbidden too" {
  ln -s "$MAIN" "$T/link"
  forbid "$T/link"
  expect deny Bash "echo x > $MAIN/f" "$T/scratch" agent-6
  expect deny Bash "echo x > $T/link/f" "$T/scratch" agent-6
  done_
}

@test "every lane brief names the forbidden checkout; the hook watches edit tools" {
  roles="$ROOT/skills/orchestrate/roles"
  grep -qF '`{{FORBIDDEN}}`' "$roles/README.md"
  grep -qF 'lane-forbidden' "$roles/README.md"
  grep -qF '{{FORBIDDEN}}' "$roles/_common.md"
  grep -qF '{{FORBIDDEN}}' "$roles/implementation-lane.md"
  # The reviewer brief: read refs without a checkout; execute only in a worktree of its own (#317).
  grep -qF 'show <ref>:<path>' "$roles/review.md"
  grep -qF 'worktree add --detach' "$roles/review.md"
  grep -qF 'rev-parse --abbrev-ref' "$ROOT/skills/orchestrate/SKILL.md"
  grep -qF 'lane-forbidden' "$ROOT/skills/orchestrate/lane-safety.md"
  grep -qF 'status --short' "$ROOT/skills/orchestrate/lane-safety.md"
  run jq -r '.hooks.PreToolUse[] | select(.hooks[].command | endswith("/lane-safety.sh")) | .matcher' "$ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  for t in Bash Edit Write MultiEdit NotebookEdit; do [[ "|$output|" == *"|$t|"* ]] || { echo "matcher lacks $t: $output"; return 1; }; done
}

@test "ln: a link into the checkout or out of bounds is refused when made, not only when used (#384)" {
  forbid "$MAIN"
  mkdir -p "$MAIN/src" "$MAIN/sub" "$NEST/lib" "$T/elsewhere"
  printf 'x\n' >"$MAIN/README"
  ln -s "$MAIN/sub" "$NEST/sl"
  for c in "ln -s $MAIN nl && echo x > nl/f" "ln -s $MAIN nl; rm -rf nl/src" "ln -sf $MAIN/README rl" \
    "ln -s ../../../README rel" "ln -s sl/../README rel" "ln $MAIN/README hard" "ln -s $MAIN" \
    "ln -s $MAIN/README $MAIN/src lib" "ln -sfn -- $MAIN nl" "ln -s -t lib $MAIN/src"; do
    expect deny Bash "$c" "$NEST" agent-3 "orchestrator's checkout"
  done
  expect deny Bash "ln -s $T/elsewhere out" "$NEST" agent-3 "links outside the lane worktree"
  expect deny Bash "ln -s $HOME hm" "$NEST" agent-3 "links outside the lane worktree"
  # In-lane and temp targets, and /dev, stay allowed (node_modules/.bin style).
  for c in "ln -s ../lib/x node_modules/.bin/x" "ln -sf lib lib2" "ln -s $T/scratch/out out" \
    "ln -s /dev/null devnull" "ln -s $NEST/lib/x $T/scratch/x" "ln lib/a lib/b"; do
    expect allow Bash "$c" "$NEST" agent-3
  done
  # The orchestrator's own calls are unbound.
  expect allow Bash "ln -s $MAIN/README rl" "$MAIN" ""
  done_
}

@test "a glob before .. in the nested lane reaches the checkout through a link (#384)" {
  forbid "$MAIN"
  mkdir -p "$MAIN/src" "$MAIN/sub"
  printf 'x\n' >"$MAIN/README"
  ln -s "$MAIN/sub" "$NEST/sl"
  expect deny Bash "echo x > $NEST/s*/../README" "$NEST" agent-3 "orchestrator's checkout"
  expect deny Bash "rm -rf $NEST/s?/../src" "$NEST" agent-3 "orchestrator's checkout"
  expect deny Bash "rm -f s*/../README" "$NEST" agent-3 "orchestrator's checkout"
  expect deny Bash "rm -f $MAIN/README" "$NEST" agent-3 "orchestrator's checkout"
  expect deny Bash "unlink ../../../README" "$NEST" agent-3 "orchestrator's checkout"
  done_
}

@test "a brace expansion into the checkout is judged word by word (#387)" {
  forbid "$MAIN"
  printf 'x\n' >"$MAIN/README"
  for c in "touch {../../..,zz}/README" "tee {../../..,zz}/README" "rm -f {zz,../../..}/README" \
    "echo x > {zz,$MAIN}/f" "ln -s {../../..,zz}/README l"; do
    expect deny Bash "$c" "$NEST" agent-3 "orchestrator's checkout"
  done
  expect allow Bash "touch {a,b}/README" "$NEST" agent-3
  done_
}
