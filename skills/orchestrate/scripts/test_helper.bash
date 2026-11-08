# Shared by every .bats suite here (`load test_helper` in setup). Makes git hermetic for the test
# process and the scripts it runs: a test-local global config (fixed identity, no commit or tag
# signing, no hooks, main as the initial branch, no background gc or maintenance after commits and
# fetches: tests make thousands) and no system config, so a user's signing setup
# (1Password, gpg, ssh signers) or hooks can never run during fixtures. The user's real
# configuration files are not read or changed. Loaded in setup_file too, the config lives in the
# file's tmpdir until setup loads it again per test.
# Tests must also pass under dev/coverage.sh: bashcov exports SHELLOPTS with nounset and pipefail,
# so every bash a test starts (stubs included) runs with them. A stub that reads an unset variable
# (`$1` with no argument, an env var a test did not set) must use "${VAR:-}", and a test must not
# pipe into an early-exit reader such as `grep -q` or `head` (#140, linted by early-exit-pipes.bats).
hermetic_git() {
  local cfg="${BATS_TEST_TMPDIR:-$BATS_FILE_TMPDIR}/.gitconfig-hermetic"
  cat >"$cfg" <<'CFG'
[user]
	name = t
	email = t@example.com
[commit]
	gpgsign = false
[tag]
	gpgsign = false
[core]
	hooksPath = /dev/null
[init]
	defaultBranch = main
[advice]
	detachedHead = false
[maintenance]
	auto = false
[gc]
	auto = 0
CFG
  export GIT_CONFIG_GLOBAL="$cfg" GIT_CONFIG_NOSYSTEM=1
  unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
}
hermetic_git
# gh-read.sh in tests: log waits instead of sleeping, no jitter.
export GH_READ_FAKE_SLEEP=1 GH_READ_JITTER=0
# No suite paces its stubbed gh through gh-budget.sh unless it puts the shim on PATH itself.
unset ORCHESTRATE_GH_BUDGET GH_BUDGET_ACTIVE
# No suite reaches githubstatus.com (gh-status.sh): an unreadable fixture unless a test writes it,
# and pr-merge.sh outage waits are logged ("pr-merge: wait <s>"), not slept.
export GITHUB_STATUS_URL="file://$BATS_TEST_TMPDIR/githubstatus.json" ORCHESTRATE_MERGE_FAKE_SLEEP=1
# A bare origin (branch main) and a clone of it, seed, with one pushed commit (f.txt "base"): built
# once in setup_file by seed_origin_template, copied into each test's $BATS_TEST_TMPDIR by
# seed_origin_copy, instead of git init, commit and push in every test (#112).
seed_origin_template() {
  local t="$BATS_FILE_TMPDIR/seed-template"
  git init -q --bare -b main "$t/origin.git"
  git clone -q "$t/origin.git" "$t/seed" 2>/dev/null
  echo base >"$t/seed/f.txt"
  git -C "$t/seed" add f.txt
  git -C "$t/seed" commit -qm init
  git -C "$t/seed" push -q origin HEAD:main
}
seed_origin_copy() {
  cp -R "$BATS_FILE_TMPDIR/seed-template/origin.git" "$BATS_FILE_TMPDIR/seed-template/seed" "$BATS_TEST_TMPDIR/"
  git -C "$BATS_TEST_TMPDIR/seed" remote set-url origin "$BATS_TEST_TMPDIR/origin.git"
}
# `run ! cmd` is how a mid-test negative assertion fails (#134); bats >= 1.5 has it.
bats_require_minimum_version 1.5.0
