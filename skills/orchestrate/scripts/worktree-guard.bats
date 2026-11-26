#!/usr/bin/env bats
# worktree-guard.sh, the PreToolUse(Bash) hook (#394): `git worktree add` and `jj workspace add`
# only below a .noindex directory, the lane root or a temp dir. Run: bats worktree-guard.bats

setup() {
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR
  unset ORCHESTRATE_WORKTREE_ROOT WAAAGH_LANE_TEMP
  export WAAAGH_WORKTREE_GUARD=on WAAAGH_WORKTREE_HOME="$T/home/worktrees.noindex" HOME="$T/home" TMPDIR="$T/tmp"
  mkdir -p "$T/home" "$T/tmp"
  # Temp dirs as the hook knows them, without the real /tmp (bats' own tmpdir lives there).
  export WAAAGH_LANE_TEMP="$T/tmp"
  git init -q "$T/widget"
}

# guard COMMAND [CWD]: the hook's answer to a Bash call.
guard() { jq -n --arg c "$1" --arg d "${2:-$T/widget}" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | "$SCRIPTS/worktree-guard.sh"; }
denied() { [ "$status" -eq 0 ] && [[ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" == deny ]]; }
reason() { jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output"; }
allowed() { [ "$status" -eq 0 ] && [ -z "$output" ]; }

@test "a worktree outside any .noindex directory is denied, naming the lane root path to use" {
  run guard "git worktree add ../widget-lane -b lane"
  denied
  [[ "$(reason)" == "worktree-guard: git worktree add $T/widget-lane is outside a .noindex directory, so Spotlight indexes it (#394): create it under the lane root instead, $T/home/worktrees.noindex/widget/widget-lane (wt-root.sh path widget-lane), or in a temp dir; move existing trees with wt-root.sh migrate. WAAAGH_WORKTREE_GUARD=off turns this check off." ]]
  run guard "jj workspace add --name lane ../widget-lane"
  denied
  [[ "$(reason)" == "worktree-guard: jj workspace add $T/widget-lane is outside"* ]]
}

@test "below a .noindex directory, the lane root, \$HOME's root or a temp dir is allowed" {
  run guard "git worktree add $T/home/worktrees.noindex/widget/a -b a"; allowed
  run guard "git worktree add ~/worktrees.noindex/widget/b"; allowed
  run guard 'git worktree add "$HOME/worktrees.noindex/widget/c"'; allowed
  run guard "git worktree add /Volumes/x/lanes.noindex/d"; allowed
  run guard "git worktree add --detach $T/tmp/scratch HEAD"; allowed
  run guard 'git worktree add "$TMPDIR/scratch" HEAD'; allowed
  run guard 'git worktree add "$("$SCRIPTS/wt-root.sh" path e)" -b e'; allowed
  run guard 'jj workspace add "$(wt-root.sh path f)"'; allowed
  ORCHESTRATE_WORKTREE_ROOT="$T/lanes" run guard "git worktree add $T/lanes/g"; allowed   # an override root, .noindex or not
}

@test "a relative path is read from the cwd, a literal cd before it and git -C" {
  mkdir -p "$T/home/worktrees.noindex/widget"
  run guard "git worktree add a" "$T/home/worktrees.noindex/widget"; allowed
  run guard "cd $T/home/worktrees.noindex/widget && git worktree add b"; allowed
  run guard "git -C $T/home/worktrees.noindex/widget worktree add ./c"; allowed
  run guard "git -C $T/widget worktree add ../../home/worktrees.noindex/widget/d" "$T"; allowed
  run guard "cd $T && git worktree add widget-e"; denied
  [[ "$(reason)" == *"git worktree add $T/widget-e is outside"* ]]
}

@test "a path through a symlink counts where it lands: .claude/worktrees linked to worktrees.noindex" {
  mkdir -p "$T/widget/.claude/worktrees.noindex"; ln -s worktrees.noindex "$T/widget/.claude/worktrees"
  run guard "git worktree add .claude/worktrees/lane -b lane"; allowed
  mkdir -p "$T/widget/.claude/plain"
  run guard "git worktree add .claude/plain/lane"; denied
}

@test "options, quotes and several commands are read as the shell would" {
  run guard "git worktree add -f --lock --reason 'held by me' -b x 'my lanes/x' HEAD"; denied
  [[ "$(reason)" == *"git worktree add $T/widget/my lanes/x is outside"* ]]
  run guard "git worktree add -- ~/worktrees.noindex/widget/y"; allowed
  run guard "git worktree add ~/worktrees.noindex/widget/z && git worktree add ../bad; echo done"; denied
  [[ "$(reason)" == *"$T/bad is outside"* && "$(reason)" != *"/z is"* ]]
  run guard $'git status\ngit worktree add ../nl'; denied
  run guard $'git worktree\tadd ../tab'; denied
  run guard $'git worktree \\\n  add ../cont'; denied
  run guard "env GIT_DIR=x git -c core.x=1 --no-pager worktree add ../env"; denied
  run guard "jj -R . workspace add -r @- --sparse-patterns full ../jj"; denied
  [[ "$(reason)" == *"jj workspace add $T/jj is outside"* ]]
}

@test "a path built from another variable or substitution is denied: the hook cannot tell where it lands" {
  run guard 'git worktree add "$WT/lane" -b lane'; denied
  [[ "$(reason)" == *'git worktree add $WT/lane: the hook cannot tell where a path built from a variable lands; spell it out under the lane root ('"$T"'/home/worktrees.noindex/widget/lane, from "$(wt-root.sh path lane)") or a temp dir'* ]]
  run guard 'git worktree add "$(pwd)/../x"'; denied
  # No HOME: ~ is unknown too, never read as /.
  HOME="" run guard "git worktree add ~/worktrees.noindex/../x"; denied
  [[ "$(reason)" == *"cannot tell where"* ]]
}

@test "other commands, other worktree subcommands and quoted mentions pass untouched" {
  for c in "echo hi" "git worktree list" "git worktree remove ../x" "git worktree move a b" "git status" \
    "echo 'git worktree add ../x'" "grep -r 'worktree add' ." "jj workspace list" "ls /workspaces"; do
    run guard "$c"; allowed
  done
}

@test "off when asked, by default off the Mac, and a malformed payload is allowed" {
  WAAAGH_WORKTREE_GUARD=off run guard "git worktree add ../x"; allowed
  if [[ "$OSTYPE" == darwin* ]]; then
    WAAAGH_WORKTREE_GUARD="" run guard "git worktree add ../x"; denied
  else
    WAAAGH_WORKTREE_GUARD="" run guard "git worktree add ../x"; allowed
  fi
  run bash -c 'echo "not json worktree" | "$0"' "$SCRIPTS/worktree-guard.sh"; allowed
  run bash -c ': | "$0"' "$SCRIPTS/worktree-guard.sh"; allowed
  run "$SCRIPTS/worktree-guard.sh" --bogus </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *usage:* ]]
  run "$SCRIPTS/worktree-guard.sh" -h </dev/null
  [ "$status" -eq 0 ] && [[ "$output" == *"Spotlight skips"* ]]
}

@test "timing: a Bash call that names no worktree costs only the shell start (no jq); a match is judged quickly" {
  # A cwd that says "workspaces" (and a command that mentions a worktree) must not cost a jq call.
  mkdir -p "$T/workspaces/app"
  printf '{"tool_name":"Bash","tool_input":{"command":"make test; git worktree list"},"cwd":"%s"}' "$T/workspaces/app" >"$T/plain.json"
  mkdir -p "$T/bin"; printf '#!/bin/sh\necho jq >>"%s/jq-calls"\nexit 1\n' "$T" >"$T/bin/jq"; chmod +x "$T/bin/jq"
  s=$SECONDS
  for _ in $(seq 1 50); do PATH="$T/bin:$PATH" "$SCRIPTS/worktree-guard.sh" <"$T/plain.json" >/dev/null; done
  (( SECONDS - s <= 3 ))   # 50 calls; measured about 6 ms each (a bare bash start is about 4)
  [ ! -e "$T/jq-calls" ]
  s=$SECONDS
  for _ in $(seq 1 10); do guard "git worktree add ../x -b x" >/dev/null; done
  (( SECONDS - s <= 4 ))   # 10 judged calls; measured 40-50 ms each
}

@test "the plugin registers it on Bash calls with a short timeout, next to lane-safety" {
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.type == "command" and .command == "${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/scripts/worktree-guard.sh" and .timeout <= 5)' "$ROOT/hooks/hooks.json" >/dev/null
  jq -e '.hooks.PreToolUse[].hooks[] | select(.command | endswith("/lane-safety.sh"))' "$ROOT/hooks/hooks.json" >/dev/null
}
