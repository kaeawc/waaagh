#!/usr/bin/env bats
# wt-root.sh (#394): the canonical .noindex lane root, and moving existing worktrees under it
# (per tree with git worktree move, or a whole directory as DIR.noindex plus a link). Against a
# stubbed spectra. Run: bats wt-root.bats

setup() {
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  load test_helper
  stub_spectra
  : >"$BATS_TEST_TMPDIR/spectra-cwds"
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR M=$T/widget R=$T/home/worktrees.noindex/widget
  unset ORCHESTRATE_WORKTREE_ROOT
  export WAAAGH_WORKTREE_HOME="$T/home/worktrees.noindex"
  git init -q "$M"; git -C "$M" commit -q --allow-empty -m init
}
wr() { (cd "$M" && "$SCRIPTS/wt-root.sh" "$@"); }
row() { printf '%s\n' "$output" | awk -F'\t' -v p="$1" '$2 == p { print $1 "\t" $3 }'; }
busy() { printf '9\t%s\n' "$1" >>"$T/spectra-cwds"; }

@test "path: the repository's root under WAAAGH_WORKTREE_HOME, from any of its worktrees; an override wins" {
  run wr path
  [ "$status" -eq 0 ]
  [ "$output" = "$R" ]
  run wr path lane-7
  [ "$output" = "$R/lane-7" ]
  git -C "$M" worktree add -q -b l "$T/l"
  run "$SCRIPTS/wt-root.sh" --repo-dir "$T/l" path x
  [ "$output" = "$R/x" ]
  unset WAAAGH_WORKTREE_HOME
  HOME="$T/h" run wr path
  [ "$output" = "$T/h/worktrees.noindex/widget" ]
  # No HOME (a hook or cron environment): no root at all, never /worktrees.noindex.
  run env -u HOME bash -c 'cd "$1" && "$2/wt-root.sh" path' _ "$M" "$SCRIPTS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOME is not set"* ]]
  HOME="" run wr path
  [ "$status" -eq 2 ]
  WAAAGH_WORKTREE_HOME="$T/w.noindex" run env -u HOME bash -c 'cd "$1" && "$2/wt-root.sh" path' _ "$M" "$SCRIPTS"
  [ "$output" = "$T/w.noindex/widget" ]
  ORCHESTRATE_WORKTREE_ROOT=/elsewhere run wr path x
  [ "$output" = /elsewhere/x ]
  run wr path a/b
  [ "$status" -eq 2 ]
  WAAAGH_WORKTREE_HOME="$T/w.noindex" run "$SCRIPTS/wt-root.sh" --repo-dir "$T" path
  [ "$status" -eq 2 ]
  [[ "$output" == *"not in a git checkout"* ]]
  run wr
  [ "$status" -eq 2 ]
  [[ "$output" == *usage:* ]]
  run wr path x --apply
  [ "$status" -eq 2 ]
}

@test "migrate: a dry run lists each move and why the rest stay; --apply moves only the idle trees" {
  for n in idle busy locked taken; do git -C "$M" worktree add -q -b "$n" "$T/lanes/$n"; done
  git -C "$M" worktree add -q -b ok "$T/old.noindex/ok"
  git -C "$M" worktree lock "$T/lanes/locked"
  busy "$T/lanes/busy/sub"
  mkdir -p "$R/taken"
  run wr migrate
  [ "$status" -eq 0 ]
  [[ "$output" == *$'root\t'"$R"$'\texists'* ]]
  [ "$(row "$T/lanes/idle")" = $'move\t-> '"$R"'/idle (dry run: --apply moves it)' ]
  [ "$(row "$T/lanes/busy")" = $'keep\ta process is working inside it' ]
  [ "$(row "$T/lanes/locked")" = $'keep\tlocked' ]
  [ "$(row "$T/lanes/taken")" = $'keep\t'"$R"'/taken exists' ]
  [ "$(row "$T/old.noindex/ok")" = $'keep\talready under a .noindex directory' ]
  [ "$(row "$M")" = $'keep\tmain worktree' ]
  [ -d "$T/lanes/idle" ]
  run wr migrate --apply
  [ "$status" -eq 0 ]
  [ "$(row "$T/lanes/idle")" = $'moved\t-> '"$R"'/idle' ]
  [ ! -e "$T/lanes/idle" ]
  [ "$(git -C "$R/idle" branch --show-current)" = idle ]
  [[ $'\n'"$(git -C "$M" worktree list --porcelain)"$'\n' == *$'\n'"worktree $R/idle"$'\n'* ]]
  for n in busy locked taken; do [ -d "$T/lanes/$n" ]; done
}

@test "migrate moves nothing when spectra cannot say who works in a tree" {
  git -C "$M" worktree add -q -b a "$T/lanes/a"
  SPECTRA_STUB_FAIL=1 run wr migrate --apply
  [ "$(row "$T/lanes/a")" = $'keep\tcannot check processes: spectra owner --under failed' ]
  [ -d "$T/lanes/a" ]
}

@test "migrate --dir: DIR becomes DIR.noindex with a link at the old path, and its trees are repaired" {
  git -C "$M" worktree add -q -b a "$M/.claude/worktrees/a"
  git -C "$M" worktree add -q -b b "$M/.claude/worktrees/b"
  run wr migrate --dir .claude/worktrees
  [ "$(row "$M/.claude/worktrees")" = $'link\tmv to '"$M"'/.claude/worktrees.noindex, then link worktrees -> worktrees.noindex and repair 2 worktree(s) (dry run: --apply does it)' ]
  [ ! -L "$M/.claude/worktrees" ]
  run wr migrate --dir .claude/worktrees --apply
  [ "$status" -eq 0 ]
  [ "$(row "$M/.claude/worktrees")" = $'linked\t-> worktrees.noindex, 2 worktree(s) repaired' ]
  [ "$(readlink "$M/.claude/worktrees")" = worktrees.noindex ]
  [[ $'\n'"$(git -C "$M" worktree list --porcelain)"$'\n' == *$'\n'"worktree $M/.claude/worktrees.noindex/a"$'\n'* ]]
  [ "$(git -C "$M/.claude/worktrees/b" branch --show-current)" = b ]   # the old path still works
  git -C "$M" worktree add -q -b c "$M/.claude/worktrees/c"             # and new trees land in .noindex
  [ -d "$M/.claude/worktrees.noindex/c" ]
  run wr migrate --dir .claude/worktrees --apply
  [ "$(row "$M/.claude/worktrees")" = $'keep\talready a link (to worktrees.noindex)' ]
}

@test "migrate --dir refuses a busy directory, an existing DIR.noindex and a .noindex DIR; creates a missing one" {
  git -C "$M" worktree add -q -b a "$T/lanes/a"
  busy "$T/lanes/a"
  run wr migrate --dir "$T/lanes" --apply
  [ "$(row "$T/lanes")" = $'keep\ta process is working inside it' ]
  [ -d "$T/lanes" ]
  [ ! -L "$T/lanes" ]
  : >"$T/spectra-cwds"; mkdir "$T/lanes.noindex"
  run wr migrate --dir "$T/lanes" --apply
  [ "$(row "$T/lanes")" = $'keep\t'"$T"'/lanes.noindex exists: move its trees by hand' ]
  run wr migrate --dir "$T/x.noindex" --apply
  [ "$(row "$T/x.noindex")" = $'keep\talready under a .noindex directory' ]
  run wr migrate --dir "$M/.claude/worktrees" --apply
  [ "$(row "$M/.claude/worktrees")" = $'linked\t-> worktrees.noindex, 0 worktree(s) repaired' ]
  [ -d "$M/.claude/worktrees.noindex" ] && [ -L "$M/.claude/worktrees" ]
}

@test "orch_worktree_root: the .noindex root once it exists, else the legacy .claude/worktrees" {
  mkdir -p "$M/.claude/worktrees"
  run bash -c 'cd "$1" && source "$2/_lib.sh" && orch_worktree_root' _ "$M" "$SCRIPTS"
  [ "$output" = "$M/.claude/worktrees" ]
  mkdir -p "$R"
  run bash -c 'cd "$1" && source "$2/_lib.sh" && orch_worktree_root' _ "$M" "$SCRIPTS"
  [ "$output" = "$R" ]
  ORCHESTRATE_WORKTREE_ROOT="$T/none" run bash -c 'cd "$1" && source "$2/_lib.sh" && orch_worktree_root' _ "$M" "$SCRIPTS"
  [ "$status" -eq 1 ]
}
