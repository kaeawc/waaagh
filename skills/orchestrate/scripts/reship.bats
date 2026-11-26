#!/usr/bin/env bats
# reship.sh (#414): a ship verdict carried over base merges that bring in nothing else, whoever
# made them. Real git (an origin, a PR branch, local merges); review-ledger.sh is the real one.
# Run: bats reship.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR
  export ORCHESTRATE_STATE_DIR="$T/state" ORCHESTRATE_NOW=1795000000 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_REVIEW_POST
  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/w" 2>/dev/null
  cd "$T/w"
  git config user.email t@example.com; git config user.name tester
  printf 'a\n' >a; printf 'b\n' >b; git add -A; git commit -qm init; git push -q origin HEAD:main
  git checkout -qb feature; printf 'feature\n' >f; git add f; git commit -qm feature
  R=$(git rev-parse HEAD)
  git push -q origin feature
  # main moves on (a file the PR does not touch)
  git checkout -q main; printf 'b2\n' >b; git commit -qam "main moves"; git push -q origin main
  git checkout -q feature
  export ORCHESTRATE_GIT_DIR="$T/w"
}
ship() { "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 1 --verdict ship --head "$1" >/dev/null; }
rs() { run "$SCRIPTS/reship.sh" --repo o/r --pr 1 --base main "$@"; }

@test "a clean local merge of main is reshipped and the ledger says why" {
  ship "$R"
  git merge -q --no-edit origin/main
  H=$(git rev-parse HEAD)
  rs --head "$H" --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "would reship #1 ${H:0:9} (from ${R:0:9})" ]
  rs --head "$H"
  [ "$status" -eq 0 ]
  [ "$output" = "reshipped #1 ${H:0:9} (from ${R:0:9})" ]
  run "$SCRIPTS/review-ledger.sh" latest --repo o/r --pr 1
  [[ "$output" == *$'\tship\t'"$H"$'\treship: only clean merges of main since '"${R:0:9}"* ]]
  rs --head "$H"
  [ "$output" = "covered #1 ${H:0:9}: same head" ]
}

@test "a merge that changes anything else, or a plain commit, is refused (exit 3)" {
  ship "$R"
  git merge -q --no-commit origin/main; printf 'sneaky\n' >>a; git add a; git commit -qm "merge plus an edit"
  rs --head "$(git rev-parse HEAD)"
  [ "$status" -eq 3 ]
  [[ "$output" == "refused #1: "*"changes more than the merge of main" ]]
  git reset -q --hard "$R"; printf 'more\n' >>f; git commit -qam "more work"
  rs --head "$(git rev-parse HEAD)"
  [ "$status" -eq 3 ]
  [[ "$output" == "refused #1: "*"is not a two-parent merge" ]]
}

@test "no ship verdict, a ship with no head, or a fix-first is refused" {
  git merge -q --no-edit origin/main; H=$(git rev-parse HEAD)
  rs --head "$H"
  [ "$status" -eq 3 ]
  [ "$output" = "refused #1: no review verdict recorded" ]
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 1 --verdict ship >/dev/null
  rs --head "$H"
  [ "$output" = "refused #1: the ship verdict was recorded without --head" ]
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 1 --verdict fix-first --head "$R" >/dev/null
  rs --head "$H"
  [ "$status" -eq 3 ]
  [ "$output" = "refused #1: the latest verdict is fix-first, not ship" ]
  run "$SCRIPTS/reship.sh" --pr x
  [ "$status" -eq 2 ]
}
