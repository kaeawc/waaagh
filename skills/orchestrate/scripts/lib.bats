#!/usr/bin/env bats
# _lib.sh helpers: which repository a script works on when --repo is not given.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/gh-calls"
case "\$*" in
  "repo view --json nameWithOwner") echo '{"nameWithOwner":"from/gh"}' ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  CO="$BATS_TEST_TMPDIR/checkout"
  git init -q "$CO"
}

repo_in() { (cd "$CO" && source "$SCRIPTS/_lib.sh" && orch_repo "$@"); }
gh_calls() { if [ -f "$BATS_TEST_TMPDIR/gh-calls" ]; then wc -l <"$BATS_TEST_TMPDIR/gh-calls" | tr -d ' '; else echo 0; fi; }

@test "orch_repo returns an explicit OWNER/REPO as given" {
  run repo_in some/repo
  [ "$output" = some/repo ]
  [ "$(gh_calls)" = 0 ]
}

@test "orch_repo reads a single github.com remote from git, with no gh call, in every URL form" {
  for url in https://github.com/o/r.git https://github.com/o/r git@github.com:o/r.git ssh://git@github.com/o/r.git; do
    git -C "$CO" remote remove origin 2>/dev/null || true
    git -C "$CO" remote add origin "$url"
    run repo_in
    [ "$output" = o/r ] || { echo "$url -> $output"; false; }
  done
  [ "$(gh_calls)" = 0 ]
}

@test "orch_repo leaves an ambiguous or foreign checkout to gh" {
  # Two remotes: gh decides which one is the base repository.
  git -C "$CO" remote add origin https://github.com/me/fork.git
  git -C "$CO" remote add upstream https://github.com/o/r.git
  run repo_in
  [ "$output" = from/gh ]
  # One remote, but a `gh repo set-default` choice recorded on it.
  git -C "$CO" remote remove upstream
  git -C "$CO" config remote.origin.gh-resolved base
  run repo_in
  [ "$output" = from/gh ]
  # Another host, a proxy URL, no remote at all.
  for url in https://gitlab.com/o/r.git http://proxy@127.0.0.1:1234/git/o/r; do
    git -C "$CO" remote remove origin
    git -C "$CO" remote add origin "$url"
    run repo_in
    [ "$output" = from/gh ] || { echo "$url -> $output"; false; }
  done
  git -C "$CO" remote remove origin
  run repo_in
  [ "$output" = from/gh ]
  [ "$(gh_calls)" = 5 ]
}
