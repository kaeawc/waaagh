# Shared by every .bats suite here (`load test_helper` in setup). Makes git hermetic for the test
# process and the scripts it runs: a test-local global config (fixed identity, no commit or tag
# signing, no hooks, main as the initial branch) and no system config, so a user's signing setup
# (1Password, gpg, ssh signers) or hooks can never run during fixtures. The user's real
# configuration files are not read or changed.
hermetic_git() {
  local cfg="$BATS_TEST_TMPDIR/.gitconfig-hermetic"
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
CFG
  export GIT_CONFIG_GLOBAL="$cfg" GIT_CONFIG_NOSYSTEM=1
  unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
}
hermetic_git
# gh-read.sh in tests: log waits instead of sleeping, no jitter.
export GH_READ_FAKE_SLEEP=1 GH_READ_JITTER=0
