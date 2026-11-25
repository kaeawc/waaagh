# Setup and helpers shared by selftest-pr.bats and selftest-pr-merge.bats
# (split for a shorter parallel run, #112).
# Loaded at file level by both; not a suite itself.

# The scratch repo ($REPO, one commit of a.txt) is built once per file and copied into each test:
# one cp instead of five git processes per test (#112).
setup_file() {
  load test_helper
  local t="$BATS_FILE_TMPDIR/repo-template"
  mkdir -p "$t"
  git -C "$t" init -q
  git -C "$t" config user.email t@example.com
  git -C "$t" config user.name t
  echo one >"$t/a.txt"
  git -C "$t" add a.txt
  git -C "$t" commit -qm init
}

setup() {
  load test_helper
  load selftest_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO="$BATS_TEST_TMPDIR/repo"
  cp -R "$BATS_FILE_TMPDIR/repo-template" "$REPO"
}
