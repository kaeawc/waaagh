#!/usr/bin/env bats
# merge-sensitive.sh refusal paths merge-sensitive.bats does not reach: an unreadable compare, and
# each way the merge-result check cannot be set up (exit 9) or conflicts (exit 3). Stubbed gh, real
# git. Run: bats scripts/merge-sensitive-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_MERGE_SENSITIVE
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin" "$ORCHESTRATE_STATE_DIR/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  echo libs.toml >"$ORCHESTRATE_STATE_DIR/o__r/merge-sensitive"
  echo 1 >"$FX/behind"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api --paginate repos/o/r/pulls/5/files"*) echo libs.toml ;;
  "api repos/o/r/pulls/5 "*) echo main ;;
  "api repos/o/r/compare/main..."*) cat "$FX/behind" ;;
  "api repos/o/r/compare/"*"...main "*) echo libs.toml ;; # the base's drift
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

ms() { run "$SCRIPTS/merge-sensitive.sh" check --repo o/r --pr 5 "$@"; }

# origin.git with main and a pr branch that both edit libs.toml's one line; checkout is a clone.
conflicting_repo() {
  local T=$BATS_TEST_TMPDIR
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
  echo 'a = 1' >"$T/seed/libs.toml"
  git -C "$T/seed" add libs.toml && git -C "$T/seed" commit -qm init && git -C "$T/seed" push -q origin HEAD:main
  git -C "$T/seed" switch -q -c pr
  echo 'a = 2' >"$T/seed/libs.toml"; git -C "$T/seed" commit -qam pr; git -C "$T/seed" push -q origin pr
  PRHEAD=$(git -C "$T/seed" rev-parse HEAD)
  git -C "$T/seed" switch -q main
  echo 'a = 3' >"$T/seed/libs.toml"; git -C "$T/seed" commit -qam main; git -C "$T/seed" push -q origin main
  git clone -q "$T/origin.git" "$T/checkout" 2>/dev/null
}

@test "a compare that does not give a number is unverified (exit 9)" {
  echo "not-a-number" >"$FX/behind"
  ms --head abcdef1234
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: could not compare abcdef123 with main" ]
}

@test "--worktree that is not a git checkout is unverified (exit 9)" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  ms --head abcdef1234 --worktree "$BATS_TEST_TMPDIR/plain" --check-cmd true
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: $BATS_TEST_TMPDIR/plain is not a git checkout" ]
}

@test "a head that cannot be fetched is unverified (exit 9)" {
  conflicting_repo
  ms --head 0123456789abcdef0123456789abcdef01234567 --worktree "$BATS_TEST_TMPDIR/checkout" --check-cmd true
  [ "$status" -eq 9 ]
  [[ "$output" == "unverified: could not fetch main and 012345678 into $BATS_TEST_TMPDIR/checkout (see "* ]]
}

@test "a fetched head that is not --head is unverified (exit 9)" {
  conflicting_repo
  ms --head refs/heads/pr --worktree "$BATS_TEST_TMPDIR/checkout" --check-cmd true
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: fetched head is not refs/head" ]
}

@test "a base with no remote-tracking ref in the checkout is unverified (exit 9)" {
  conflicting_repo
  git -C "$BATS_TEST_TMPDIR/checkout" config --unset-all remote.origin.fetch
  git -C "$BATS_TEST_TMPDIR/checkout" update-ref -d refs/remotes/origin/main
  ms --head "$PRHEAD" --worktree "$BATS_TEST_TMPDIR/checkout" --check-cmd true
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: origin/main is not known in $BATS_TEST_TMPDIR/checkout" ]
}

@test "a temporary worktree that cannot be created is unverified (exit 9), the check never runs" {
  conflicting_repo
  real=$(command -v git)
  printf '#!/usr/bin/env bash\ncase "$*" in *"worktree add"*) exit 1 ;; esac\nexec %s "$@"\n' "$real" >"$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  ms --head "$PRHEAD" --worktree "$BATS_TEST_TMPDIR/checkout" --check-cmd "touch $FX/ran"
  [ "$status" -eq 9 ]
  [[ "$output" == "unverified: could not create a temporary worktree (see "* ]]
  [ ! -e "$FX/ran" ]
}

@test "a merge result that conflicts is stale (exit 3), the check never runs and the checkout is untouched" {
  conflicting_repo
  ms --head "$PRHEAD" --worktree "$BATS_TEST_TMPDIR/checkout" --check-cmd "touch $FX/ran"
  [ "$status" -eq 3 ]
  [[ "$output" == "stale: PR 5 touches merge-sensitive libs.toml and is 1 commit(s) behind main, which touch libs.toml, and the merge result conflicts (see "* ]]
  [ ! -e "$FX/ran" ]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/checkout" worktree list | awk 'NR > 1')" ]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/checkout" status --porcelain)" ]
}
