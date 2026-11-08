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

# orch_author: the `gh api user` login, cached per state root, host and hour (#113).
author_stub() {
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/gh-calls"
[ "\$*" = "api user" ] || exit 9
[ -f "$BATS_TEST_TMPDIR/gh-fail" ] && { echo 'HTTP 502' >&2; exit 1; }
printf '{"login":"%s"}\n' "\$(cat "$BATS_TEST_TMPDIR/login")"
STUB
  echo alice >"$BATS_TEST_TMPDIR/login"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" GH_CONFIG_DIR="$BATS_TEST_TMPDIR/ghcfg"
  unset ORCHESTRATE_AUTHOR ORCHESTRATE_AUTHOR_TTL GH_HOST
}
author() { (source "$SCRIPTS/_lib.sh" && orch_author); }

@test "orch_author asks gh once within the TTL and again once it expires" {
  author_stub
  ORCHESTRATE_NOW=1000 run author
  [ "$status" = 0 ]
  [ "$output" = alice ]
  echo bob >"$BATS_TEST_TMPDIR/login"
  ORCHESTRATE_NOW=4599 run author
  [ "$output" = alice ]
  [ "$(gh_calls)" = 1 ]
  [ -f "$ORCHESTRATE_STATE_DIR/.author" ]
  ORCHESTRATE_NOW=4600 run author
  [ "$output" = bob ]
  [ "$(gh_calls)" = 2 ]
  # A shorter TTL, and 0 = no cache.
  ORCHESTRATE_NOW=4610 ORCHESTRATE_AUTHOR_TTL=5 run author
  [ "$(gh_calls)" = 3 ]
  ORCHESTRATE_NOW=4610 ORCHESTRATE_AUTHOR_TTL=0 run author
  [ "$(gh_calls)" = 4 ]
}

@test "orch_author never caches a failed lookup" {
  author_stub
  touch "$BATS_TEST_TMPDIR/gh-fail"
  ORCHESTRATE_NOW=1000 run author
  [ "$status" != 0 ]
  [ "$output" = "HTTP 502" ]
  [ ! -e "$ORCHESTRATE_STATE_DIR/.author" ]
  rm "$BATS_TEST_TMPDIR/gh-fail"
  ORCHESTRATE_NOW=1001 run author
  [ "$output" = alice ]
  [ "$(gh_calls)" = 2 ]
}

@test "orch_author misses the cache on another host, account or token; ORCHESTRATE_AUTHOR wins" {
  author_stub
  ORCHESTRATE_NOW=1000 run author
  GH_HOST=ghe.example.com ORCHESTRATE_NOW=1001 run author
  [ "$(gh_calls)" = 2 ]
  # gh auth switch: the active user in hosts.yml changes (read offline, no gh call).
  mkdir -p "$GH_CONFIG_DIR"
  printf 'github.com:\n    users:\n        alice:\n        bob:\n    git_protocol: https\n    user: bob\n' >"$GH_CONFIG_DIR/hosts.yml"
  ORCHESTRATE_NOW=1002 run author
  ORCHESTRATE_NOW=1003 run author
  [ "$(gh_calls)" = 3 ]
  GH_TOKEN=another-token ORCHESTRATE_NOW=1004 run author
  [ "$(gh_calls)" = 4 ]
  ORCHESTRATE_AUTHOR=carol run author
  [ "$output" = carol ]
  [ "$(gh_calls)" = 4 ]
}
