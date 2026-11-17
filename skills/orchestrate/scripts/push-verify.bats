#!/usr/bin/env bats
# push-verify.sh (push, then ls-remote compare) and wt-cleanup.sh's ls-remote guard (#262).

setup() {
  load test_helper
  hermetic_git
  SCRIPTS="$BATS_TEST_DIRNAME"
  export PUSH_VERIFY_SLEEP=0
  O="$BATS_TEST_TMPDIR/origin.git" W="$BATS_TEST_TMPDIR/work"
  git init -q --bare "$O"
  git clone -q "$O" "$W" 2>/dev/null
  echo a >"$W/f"; git -C "$W" add f; git -C "$W" commit -qm one
  git -C "$W" push -q origin HEAD:main
  git -C "$W" checkout -q -b feat
  echo b >>"$W/f"; git -C "$W" commit -qam two
  SHA=$(git -C "$W" rev-parse HEAD)
}

hook() { # body: install a pre-push hook that runs the given shell text
  mkdir -p "$W/.git/hooks"
  printf '#!/bin/sh\n%s\n' "$1" >"$W/.git/hooks/pre-push"
  chmod +x "$W/.git/hooks/pre-push"
}
use_hooks() { git config --global core.hooksPath "$W/.git/hooks"; }

@test "push-verify pushes and confirms the remote ref equals the commit" {
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W" --branch feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified: origin/feat is $SHA"* ]]
  [ "$(git -C "$O" rev-parse refs/heads/feat)" = "$SHA" ]
}

@test "push-verify pushes a SHA with no worktree needed to name the branch" {
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W" --branch other --ref "$SHA"
  [ "$status" -eq 0 ]
  [ "$(git -C "$O" rev-parse refs/heads/other)" = "$SHA" ]
}

@test "a failing pre-push hook is exit 4 and nothing lands; --no-verify skips it" {
  hook 'exit 1'; use_hooks
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W" --branch feat --retries 1
  [ "$status" -eq 4 ]
  [[ "$output" == *"NOT verified: push failed after 2 attempts"* ]]
  run git -C "$O" rev-parse --verify -q refs/heads/feat
  [ "$status" -ne 0 ]
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W" --branch feat --no-verify
  [ "$status" -eq 0 ]
}

@test "a push that failed after landing still verifies; a transient failure is retried" {
  C="$BATS_TEST_TMPDIR/count"
  hook "n=\$(cat '$C' 2>/dev/null || echo 0); echo \$((n+1)) >'$C'; [ \$n -ge 1 ] || exit 1"; use_hooks
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W" --branch feat
  [ "$status" -eq 0 ]
  [ "$(cat "$C")" = 2 ]
}

@test "a remote ref that differs is not verified" {
  # The remote gets a different commit; a non-fast-forward push is rejected, never forced.
  git -C "$W" push -q origin "$SHA:refs/heads/feat"
  echo c >>"$W/f"; git -C "$W" commit -qam three
  git -C "$W" reset -q --hard HEAD~2; echo z >>"$W/f"; git -C "$W" commit -qam diverge
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W" --branch feat --retries 0
  [ "$status" -eq 4 ]
  [[ "$output" == *"NOT verified"* ]]
  [ "$(git -C "$O" rev-parse refs/heads/feat)" = "$SHA" ]
}

@test "an unreadable remote is exit 4" {
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W" --branch feat --remote nowhere --retries 0
  [ "$status" -eq 4 ]
  [[ "$output" == *"NOT verified"* ]]
}

@test "usage errors are exit 2" {
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W"
  [ "$status" -eq 2 ]
  run "$SCRIPTS/push-verify.sh" --repo-dir "$W" --branch feat --ref nosuchref
  [ "$status" -eq 2 ]
}

@test "wt-cleanup keeps a worktree whose remote branch does not hold HEAD, even when a tracking ref says it does" {
  M="$BATS_TEST_TMPDIR/main"
  git clone -q "$O" "$M" 2>/dev/null
  old=$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)
  wt="$BATS_TEST_TMPDIR/lane"
  git -C "$M" worktree add -q -b lane "$wt"
  echo l >"$wt/l"; git -C "$wt" add l; git -C "$wt" commit -qm lane
  git -C "$wt" push -q origin lane
  # A second commit whose push dies: HEAD is not on the remote, yet the tracking ref is stale-fresh.
  echo m >"$wt/m"; git -C "$wt" add m; git -C "$wt" commit -qm lane2
  git -C "$wt" update-ref refs/remotes/origin/lane HEAD
  touch -t "$old" "$wt" "$(git -C "$wt" rev-parse --path-format=absolute --git-path index)"
  run "$SCRIPTS/wt-cleanup.sh" --repo-dir "$M" --apply
  [[ "$output" == *"keep"*"is not on it (push-verify.sh)"* ]]
  [ -d "$wt" ]
}

@test "roles/_common.md tells lanes to verify pushes by ls-remote" {
  run grep -c 'push-verify.sh' "$SCRIPTS/../roles/_common.md"
  [ "$output" -ge 1 ]
}
