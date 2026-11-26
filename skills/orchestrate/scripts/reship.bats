#!/usr/bin/env bats
# reship.sh (#414): a ship verdict carried over base merges that bring in nothing else, whoever
# made them. Real git (an origin, a PR branch, local merges); review-ledger.sh is the real one.
# Run: bats reship.bats

bats_require_minimum_version 1.5.0

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
  # gh: the default branch is main; PR 1 targets $T/pbase (default main).
  mkdir -p "$T/bin"
  cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"; all=${all% --include}
case "$all" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  "api repos/o/r/pulls/1") jq -n --arg b "$(cat "$BATS_TEST_TMPDIR/pbase" 2>/dev/null || echo main)" '{base: {ref: $b}, head: {sha: "0000000"}}' ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH"
}
ship() { "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 1 --verdict ship --head "$1" >/dev/null; }
rs() { run "$SCRIPTS/reship.sh" --repo o/r --pr 1 "$@"; }

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

@test "review #429: a merge of another branch, a PR off the default branch, an unfetchable base, a review-ship hold" {
  ship "$R"
  # A clean merge of a branch that is not the base, holding an unreviewed commit.
  git checkout -qb scratch origin/main; printf 'u\n' >u; git add u; git commit -qm unreviewed; git push -q origin scratch
  git checkout -q feature; git merge -q --no-edit scratch; H=$(git rev-parse HEAD)
  rs --head "$H"
  [ "$status" -eq 3 ]
  [[ "$output" == "refused #1: "*"does not merge main" ]]
  echo scratch >"$BATS_TEST_TMPDIR/pbase"
  rs --head "$H"
  [ "$status" -eq 3 ]
  [ "$output" = "refused #1: the PR targets scratch, not the default branch main" ]
  rm "$BATS_TEST_TMPDIR/pbase"
  git reset -q --hard "$R"; git merge -q --no-edit origin/main; H=$(git rev-parse HEAD)
  "$SCRIPTS/hold.sh" add --repo o/r --pr 1 --until review-ship --reason "owner wants a fresh look" >/dev/null
  rs --head "$H"
  [ "$status" -eq 3 ]
  [[ "$output" == "refused #1: a review-ship hold asks for a fresh review"* ]]
  "$SCRIPTS/hold.sh" release --repo o/r --pr 1 >/dev/null
  git remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"
  run --separate-stderr "$SCRIPTS/reship.sh" --repo o/r --pr 1 --head "$H"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"could not be fetched"* ]]
}

@test "review #429: a verdict recorded while checking wins; R not an ancestor is refused" {
  ship "$R"
  git merge -q --no-edit origin/main; H=$(git rev-parse HEAD)
  # review-ledger.sh whose second `latest` answer differs (a fix-first landed meanwhile).
  ST="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$ST"
  cat >"$ST/review-ledger.sh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = latest ]; then
  n=\$(( \$(cat "$BATS_TEST_TMPDIR/latest-n" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$BATS_TEST_TMPDIR/latest-n"
  if [ "\$n" -eq 1 ]; then printf 't\t1\tship\t$R\t-\n'; else printf 't\t1\tfix-first\t$R\t-\n'; fi
else echo "record \$*" >>"$BATS_TEST_TMPDIR/records"; fi
STUB
  chmod +x "$ST/review-ledger.sh"
  ORCHESTRATE_SCRIPTS_DIR="$ST" rs --head "$H"
  [ "$status" -eq 3 ]
  [ "$output" = "refused #1: the review ledger changed while checking (now: fix-first)" ]
  [ ! -e "$BATS_TEST_TMPDIR/records" ]
  # A reviewed head the new head does not descend from.
  git checkout -q --orphan other; git rm -rqf .; printf 'x\n' >x; git add x; git commit -qm other
  rs --head "$(git rev-parse HEAD)"
  [ "$status" -eq 3 ]
  [[ "$output" == "refused #1: "*"is not an ancestor of"* ]]
}
