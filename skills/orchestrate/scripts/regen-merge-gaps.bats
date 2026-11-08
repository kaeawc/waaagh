#!/usr/bin/env bats
# regen-merge.sh paths regen-merge.bats does not reach: the base taken from origin's HEAD when
# --base is not given, --no-commit, and a generated file the base deleted (it stays deleted).
# Real git, a local bare origin. Run: bats scripts/regen-merge-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  O="$BATS_TEST_TMPDIR/origin.git" M="$BATS_TEST_TMPDIR/main" W="$BATS_TEST_TMPDIR/lane"
  git init -q --bare -b main "$O"
  git clone -q "$O" "$M" 2>/dev/null
  mkdir -p "$M/src" "$M/gen"
  printf '#!/bin/sh\ncat src/*.txt | sort >gen/all.txt\n' >"$M/regen.sh"; chmod +x "$M/regen.sh"
  echo a1 >"$M/src/a.txt"; echo old >"$M/gen/old.txt"
  (cd "$M" && ./regen.sh)
  git -C "$M" add -A; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main
  git -C "$O" symbolic-ref HEAD refs/heads/main
  git clone -q "$O" "$W" 2>/dev/null
  git -C "$W" switch -q -c lane
  SPEC="$BATS_TEST_TMPDIR/generated-files.tsv"
  printf 'gen/**\t./regen.sh\n' >"$SPEC"
}

@test "without --base the base is origin's HEAD branch; --no-commit leaves the merge staged" {
  echo c1 >"$M/src/c.txt"; git -C "$M" add -A; git -C "$M" commit -qm c; git -C "$M" push -q origin HEAD:main
  echo w1 >"$W/src/w.txt"; git -C "$W" add -A; git -C "$W" commit -qm w
  head=$(git -C "$W" rev-parse HEAD)
  run "$SCRIPTS/regen-merge.sh" --worktree "$W" --no-commit
  [ "$status" -eq 0 ]
  [ "$output" = "merged clean" ]
  [ "$(git -C "$W" rev-parse HEAD)" = "$head" ]
  [ "$(git -C "$W" rev-parse MERGE_HEAD)" = "$(git -C "$O" rev-parse refs/heads/main)" ]
}

@test "a generated file the base deleted and the lane changed is resolved by deleting it" {
  echo changed >>"$W/gen/old.txt"; git -C "$W" commit -qam "lane edits old"
  git -C "$M" rm -q gen/old.txt; git -C "$M" commit -qm "main drops old"; git -C "$M" push -q origin HEAD:main
  run "$SCRIPTS/regen-merge.sh" --worktree "$W" --spec "$SPEC"
  [ "$status" -eq 0 ]
  [ "$output" = "merged, regenerated: gen/**" ]
  [ ! -e "$W/gen/old.txt" ]
  [ -z "$(git -C "$W" status --porcelain)" ]
  git -C "$W" rev-parse -q --verify HEAD^2
}
