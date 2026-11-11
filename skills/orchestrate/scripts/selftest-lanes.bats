#!/usr/bin/env bats
# Self-test for the orchestrate helper scripts (lanes). Shared helpers: selftest_helper.bash.

setup() {
  load test_helper
  load selftest_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  echo one >"$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" commit -qm init
}

@test "fixtures ignore an inherited signing setup and hooks" {
  # A hostile user config: signing through a signer that always fails, and a failing hook.
  hostile="$BATS_TEST_TMPDIR/hostile.gitconfig"
  mkdir -p "$BATS_TEST_TMPDIR/hooks"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/hooks/pre-commit"; chmod +x "$BATS_TEST_TMPDIR/hooks/pre-commit"
  printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n[core]\n\thooksPath = %s\n' "$BATS_TEST_TMPDIR/hooks" >"$hostile"
  GIT_CONFIG_GLOBAL="$hostile"
  if (cd "$REPO" && echo x >>a.txt && git commit -qam signed 2>/dev/null); then false; fi
  git -C "$REPO" checkout -q a.txt
  hermetic_git
  [ "$GIT_CONFIG_GLOBAL" != "$hostile" ]
  echo y >>"$REPO/a.txt"
  git -C "$REPO" commit -qam unsigned
  [ "$(git -C "$REPO" config --get commit.gpgsign)" = false ]
}

@test "clean git tree reports tree=clean" {
  run fp
  [ "$status" -eq 0 ]
  [[ "$output" == vcs=git* ]]
  [[ "$output" == *"tree=clean"* ]]
}

@test "tracked edit changes the fingerprint; reverting restores it" {
  clean=$(fp)
  echo two >"$REPO/a.txt"
  dirty=$(fp)
  [ "$clean" != "$dirty" ]
  [[ "$dirty" != *"tree=clean"* ]]
  echo one >"$REPO/a.txt"
  [ "$(fp)" = "$clean" ]
}

@test "untracked file content participates in the fingerprint" {
  echo x >"$REPO/new.txt"
  first=$(fp)
  echo y >"$REPO/new.txt"
  second=$(fp)
  [ "$first" != "$second" ]
}

@test "--key differs by command and is stable for the same state" {
  k1=$(fp --key "bun test")
  k2=$(fp --key "bun run lint")
  [ "$k1" != "$k2" ]
  [ "$(fp --key "bun test")" = "$k1" ]
}

@test "--key is versioned and keeps working-tree and untracked sensitivity" {
  k=$(fp --key "npm test")
  [[ "$k" == v2\|* ]]
  [ "$(printf '%s' "$k" | tr '|' '\n' | wc -l | tr -d ' ')" -eq 4 ]
  echo edit >>"$REPO/a.txt"
  [ "$(fp --key "npm test")" != "$k" ]
  git -C "$REPO" checkout -q a.txt
  echo src >"$REPO/new.ts"
  [ "$(fp --key "npm test")" != "$k" ]
}

@test "--key changes with a declared variable and ignores undeclared ones" {
  dev=$(NODE_ENV=development fp --key 'test "$NODE_ENV" = development' --env NODE_ENV)
  prod=$(NODE_ENV=production fp --key 'test "$NODE_ENV" = development' --env NODE_ENV)
  [ "$dev" != "$prod" ]
  unset_k=$(env -u NODE_ENV "$SCRIPTS/fingerprint.sh" --dir "$REPO" --key x --env NODE_ENV)
  empty_k=$(NODE_ENV= fp --key x --env NODE_ENV)
  [ "$unset_k" != "$empty_k" ]
  a=$(UNRELATED=1 NODE_ENV=production fp --key x --env NODE_ENV)
  b=$(UNRELATED=2 NODE_ENV=production fp --key x --env NODE_ENV)
  [ "$a" = "$b" ]
  # Declaration order does not matter.
  [ "$(A=1 B=2 fp --key x --env A --env B)" = "$(A=1 B=2 fp --key x --env B --env A)" ]
}

@test "--key changes with a declared toolchain version and dependency-install marker" {
  mkdir -p "$BATS_TEST_TMPDIR/tc"
  printf '#!/bin/sh\necho v20.1.0\n' >"$BATS_TEST_TMPDIR/tc/node"; chmod +x "$BATS_TEST_TMPDIR/tc/node"
  k20=$(PATH="$BATS_TEST_TMPDIR/tc:$PATH" fp --key "npm test" --tool "node --version")
  printf '#!/bin/sh\necho v22.3.0\n' >"$BATS_TEST_TMPDIR/tc/node"
  k22=$(PATH="$BATS_TEST_TMPDIR/tc:$PATH" fp --key "npm test" --tool "node --version")
  [ "$k20" != "$k22" ]
  echo "node_modules/" >"$REPO/.gitignore"; git -C "$REPO" add .gitignore; git -C "$REPO" commit -qm ignore
  mkdir -p "$REPO/node_modules"; echo one >"$REPO/node_modules/.package-lock.json"
  i1=$(fp --key "npm test" --input node_modules/.package-lock.json)
  [ "$(fp)" = "$(fp)" ]
  echo two >"$REPO/node_modules/.package-lock.json"
  i2=$(fp --key "npm test" --input node_modules/.package-lock.json)
  [ "$i1" != "$i2" ]
  # The ignored file does not change the tree fingerprint itself.
  [ "$(echo "$i1" | cut -d'|' -f2)" = "$(echo "$i2" | cut -d'|' -f2)" ]
}

@test "--env-manifest matches the same flags and --show-env never prints values" {
  printf '# validation inputs\nenv NODE_ENV\ntool echo v1\n\ninput missing.lock  # absent\n' >"$BATS_TEST_TMPDIR/env.manifest"
  m=$(NODE_ENV=production fp --key x --env-manifest "$BATS_TEST_TMPDIR/env.manifest")
  f=$(NODE_ENV=production fp --key x --env NODE_ENV --tool "echo v1" --input missing.lock)
  [ "$m" = "$f" ]
  run env SECRET_TOKEN=hunter2-very-secret "$SCRIPTS/fingerprint.sh" --dir "$REPO" --env SECRET_TOKEN --show-env --key x
  [ "$status" -eq 0 ]
  [[ "$output" != *hunter2* ]]
  [[ "$output" == *"env SECRET_TOKEN set"* ]]
  printf 'bogus line\n' >"$BATS_TEST_TMPDIR/bad.manifest"
  run fp --key x --env-manifest "$BATS_TEST_TMPDIR/bad.manifest"
  [ "$status" -eq 2 ]
  run fp --key x --env 'BAD-NAME'
  [ "$status" -ne 0 ]
}

@test "excerpt keeps failure lines, strips ANSI, and prints the log path" {
  log="$BATS_TEST_TMPDIR/ci.log"
  {
    for i in $(seq 1 50); do echo "ok line $i"; done
    printf '2026-09-27T10:00:00.123Z \033[31mError: boom\033[0m\n'
    for i in $(seq 51 100); do echo "ok line $i"; done
  } >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Error: boom"* ]]
  [[ "$output" != *$'\033'* ]]
  [[ "$output" != *"ok line 10"* ]]
  [[ "$output" == *"full log: $log (101 lines)"* ]]
}

@test "excerpt caps output and reports truncation" {
  log="$BATS_TEST_TMPDIR/many.log"
  for i in $(seq 1 200); do echo "test $i failed"; done >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 0 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"truncated: showing 10 of 200"* ]]
}

@test "excerpt ignores words that merely contain 'error'" {
  log="$BATS_TEST_TMPDIR/quiet.log"
  printf 'terrorist novel\nfailover configured\n' >"$log"
  run "$SCRIPTS/excerpt.sh" "$log"
  [[ "$output" == *"(no failure lines matched)"* ]]
  [[ "$output" == *"full log: $log (2 lines)"* ]]
}

@test "excerpt of an empty log still prints the evidence path" {
  log="$BATS_TEST_TMPDIR/empty.log"
  : >"$log"
  run "$SCRIPTS/excerpt.sh" "$log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no failure lines matched)"* ]]
  [[ "$output" == *"full log: $log (0 lines)"* ]]
}

@test "excerpt survives a large matching log (no SIGPIPE) and keeps the first and last failures" {
  log="$BATS_TEST_TMPDIR/large.log"
  pad=$(printf 'x%.0s' $(seq 1 100))
  awk -v pad="$pad" 'BEGIN { for (i = 1; i <= 20000; i++) printf "error failure %d: %s\n", i, pad }' >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 0 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"1:error failure 1:"* ]]
  [[ "$output" == *"20000:error failure 20000:"* ]]
  [[ "$output" == *"truncated: showing 10 of 20000 excerpt lines"* ]]
  [[ "$output" == *"full log: $log (20000 lines)"* ]]
  [ "${#output}" -lt 4000 ]
}

@test "excerpt folds exact repeats of a failure line" {
  log="$BATS_TEST_TMPDIR/repeat.log"
  awk 'BEGIN { for (i = 1; i <= 20000; i++) print "test failed: long message for pipe buffering" }' >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 0 10
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'long message')" -eq 1 ]
  [[ "$output" == *"folded 19999 repeated failure lines"* ]]
  [[ "$output" == *"full log: $log"* ]]
}

@test "excerpt keeps a megabyte single line within the byte budget" {
  log="$BATS_TEST_TMPDIR/wide.log"
  awk 'BEGIN { printf "error "; for (i = 0; i < 1000000; i++) printf "x"; print "" }' >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 0 10
  [ "$status" -eq 0 ]
  [[ "$output" == "1:error xxx"*"...[+"*" bytes]"* ]]
  [ "${#output}" -lt 1000 ]
}

@test "excerpt honours MAX_BYTES across many long lines" {
  log="$BATS_TEST_TMPDIR/budget.log"
  awk 'BEGIN { for (i = 1; i <= 500; i++) { printf "fatal %d ", i; for (j = 0; j < 300; j++) printf "y"; print "" } }' >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 0 120 2000
  [ "$status" -eq 0 ]
  body=$(printf '%s\n' "$output" | grep -v '^full log:' | grep -v '^\.\.\. ')
  [ "${#body}" -le 2000 ]
  [[ "$output" == *"truncated: showing"*"of 500 excerpt lines"* ]]
  [[ "$output" == *"500:fatal 500 "* ]]
}

@test "excerpt separates non-adjacent context groups and rejects bad numbers" {
  log="$BATS_TEST_TMPDIR/ctx.log"
  printf 'a\nb\nerror one\nc\nd\ne\nf\ng\nfatal two\nh\n' >"$log"
  run "$SCRIPTS/excerpt.sh" "$log" 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1,7p | tr '\n' '|')" = "2-b|3:error one|4-c|--|8-g|9:fatal two|10-h|" ]
  run "$SCRIPTS/excerpt.sh" "$log" x
  [ "$status" -eq 2 ]
}

@test "claim is exclusive while fresh and reclaimable by its owner" {
  ORCHESTRATE_NOW=1000 run claim claim --owner A
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=1100 run claim claim --owner B
  [ "$status" -eq 3 ]
  [[ "$output" == *"held by A"* ]]
  ORCHESTRATE_NOW=1100 run claim claim --owner A
  [ "$status" -eq 0 ]
}

@test "stale claim is taken over; old owner can no longer heartbeat" {
  ORCHESTRATE_NOW=1000 claim claim --owner A --ttl 60
  ORCHESTRATE_NOW=2000 run claim claim --owner B --ttl 60
  [ "$status" -eq 0 ]
  [[ "$output" == *"took over stale claim from A"* ]]
  ORCHESTRATE_NOW=2001 run claim heartbeat --owner A
  [ "$status" -eq 3 ]
}

@test "release frees the claim only for its owner; state dir survives" {
  claim claim --owner A
  echo '{"fix_pass_consumed":true}' >"$(claim path --owner A)/state.json"
  claim release --owner B
  [[ "$(claim status --owner B)" == held* ]]
  claim release --owner A
  [ "$(claim status --owner B)" = unclaimed ]
  [ -f "$(claim path --owner B)/state.json" ]
}

@test "intake only lists the configured author's PRs and classifies each" {
  stub_gh
  # 2026-09-27T12:00:00Z = 1790510400; PR 5 was updated 5 minutes earlier.
  ORCHESTRATE_NOW=1790510000 ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" "$SCRIPTS/pr-claim.sh" claim --repo o/r --pr 6 --owner OTHER
  ORCHESTRATE_NOW=1790510000 ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" "$SCRIPTS/pr-claim.sh" claim --repo o/r --pr 7 --owner ME
  git -C "$REPO" worktree add -q -b work/a "$BATS_TEST_TMPDIR/wt-a"
  echo dirty >>"$BATS_TEST_TMPDIR/wt-a/a.txt"
  run intake
  [ "$status" -eq 0 ]
  grep -q -- '--author octocat' "$BATS_TEST_TMPDIR/gh.args"
  [[ "$output" != *"work/b"* ]]
  [[ "$output" == *$'1\tbusy-local:'* ]]
  [[ "$output" == *$'3\tdraft'* ]]
  [[ "$output" == *$'4\tfork'* ]]
  [[ "$output" == *$'5\trecent-activity'* ]]
  [[ "$output" == *$'6\tclaimed:OTHER'* ]]
  [[ "$output" == *$'7\tmine'* ]]
}

@test "intake marks a quiet, unclaimed, clean PR eligible" {
  stub_gh
  run intake --include-drafts
  [[ "$output" == *$'1\teligible'* ]]
  [[ "$output" == *$'3\teligible'* ]]
}
