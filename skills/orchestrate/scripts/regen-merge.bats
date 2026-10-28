#!/usr/bin/env bats
# regen-merge.sh with real git: a local bare origin, a generated file built from sources.
# Run: bats regen-merge.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  O="$BATS_TEST_TMPDIR/origin.git" M="$BATS_TEST_TMPDIR/main" W="$BATS_TEST_TMPDIR/lane"
  git init -q --bare -b main "$O"
  git clone -q "$O" "$M" 2>/dev/null
  mkdir -p "$M/src" "$M/gen"
  # The generator: gen/all.txt is every source line, sorted.
  printf '#!/bin/sh\ncat src/*.txt | sort >gen/all.txt\n' >"$M/regen.sh"; chmod +x "$M/regen.sh"
  echo a1 >"$M/src/a.txt"; echo b1 >"$M/src/b.txt"
  (cd "$M" && ./regen.sh)
  git -C "$M" add -A; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main
  git -C "$O" symbolic-ref HEAD refs/heads/main
  git clone -q "$O" "$W" 2>/dev/null
  git -C "$W" switch -q -c lane
  SPEC="$BATS_TEST_TMPDIR/generated-files.tsv"
  printf '# generated surfaces\ngen/**\t./regen.sh\n' >"$SPEC"
}

edit() { # repo file line: append a line to a source, regenerate, commit
  echo "$3" >>"$1/src/$2"; (cd "$1" && ./regen.sh); git -C "$1" add -A; git -C "$1" commit -qm "$3"
}
rm_() { "$SCRIPTS/regen-merge.sh" --worktree "$W" --base main "$@"; }

@test "a conflict only in generated files is resolved by taking the base and regenerating" {
  edit "$W" a.txt lane-change
  edit "$M" b.txt main-change; git -C "$M" push -q origin HEAD:main
  run rm_ --spec "$SPEC"
  [ "$status" -eq 0 ]
  [ "$output" = "merged, regenerated: gen/**" ]
  [ "$(cat "$W/gen/all.txt" | tr '\n' ' ')" = "a1 b1 lane-change main-change " ]
  [ -z "$(git -C "$W" status --porcelain)" ]
  git -C "$W" rev-parse -q --verify HEAD^2   # a merge commit, history not rewritten
}

@test "a conflict in a source file aborts the merge and leaves the worktree clean" {
  edit "$W" a.txt lane-change
  edit "$M" a.txt main-change; git -C "$M" push -q origin HEAD:main
  head=$(git -C "$W" rev-parse HEAD)
  run rm_ --spec "$SPEC"
  [ "$status" -eq 3 ]
  [ "$output" = "conflict: src/a.txt" ]
  [ "$(git -C "$W" rev-parse HEAD)" = "$head" ]
  [ -z "$(git -C "$W" status --porcelain)" ]
}

@test "without a spec any conflict is a conflict" {
  edit "$W" a.txt lane-change
  edit "$M" b.txt main-change; git -C "$M" push -q origin HEAD:main
  run rm_
  [ "$status" -eq 3 ]
  [[ "$output" == "conflict: gen/all.txt"* ]]
}

@test "an unstable or out-of-bounds regeneration aborts" {
  edit "$W" a.txt lane-change
  edit "$M" b.txt main-change; git -C "$M" push -q origin HEAD:main
  head=$(git -C "$W" rev-parse HEAD)
  printf 'gen/**\t./regen.sh; date +%%s%%N >>gen/all.txt\n' >"$SPEC"
  run rm_ --spec "$SPEC"
  [ "$status" -eq 5 ]
  [[ "$output" == "unstable: regenerating twice gives different output"* ]]
  [ "$(git -C "$W" rev-parse HEAD)" = "$head" ]
  [ -z "$(git -C "$W" status --porcelain)" ]
  printf 'gen/**\t./regen.sh; echo x >>src/a.txt\n' >"$SPEC"
  run rm_ --spec "$SPEC"
  [ "$status" -eq 5 ]
  [[ "$output" == "unstable: regeneration changed src/a.txt"* ]]
  [ -z "$(git -C "$W" status --porcelain)" ]
}

@test "a clean merge and an up-to-date branch need nothing generated" {
  run rm_ --spec "$SPEC"
  [ "$output" = up-to-date ]
  echo c1 >"$M/src/c.txt"; git -C "$M" add -A; git -C "$M" commit -qm c; git -C "$M" push -q origin HEAD:main
  edit "$W" a.txt lane-change
  echo d >"$M/other.txt"; git -C "$M" add -A; git -C "$M" commit -qm d; git -C "$M" push -q origin HEAD:main
  run rm_ --spec "$SPEC"
  [ "$status" -eq 0 ]
  [ "$output" = "merged clean" ]
}
