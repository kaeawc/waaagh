#!/usr/bin/env bats
# Self-test for the orchestrate skill's helper scripts. Run: bats scripts/selftest.bats

setup() {
  load test_helper
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

fp() { "$SCRIPTS/fingerprint.sh" --dir "$REPO" "$@"; }

@test "fixtures ignore an inherited signing setup and hooks" {
  # A hostile user config: signing through a signer that always fails, and a failing hook.
  hostile="$BATS_TEST_TMPDIR/hostile.gitconfig"
  mkdir -p "$BATS_TEST_TMPDIR/hooks"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/hooks/pre-commit"; chmod +x "$BATS_TEST_TMPDIR/hooks/pre-commit"
  printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n[core]\n\thooksPath = %s\n' "$BATS_TEST_TMPDIR/hooks" >"$hostile"
  GIT_CONFIG_GLOBAL="$hostile"
  ! (cd "$REPO" && echo x >>a.txt && git commit -qam signed 2>/dev/null)
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
  [ "$(printf '%s\n' "$output" | head -7 | tr '\n' '|')" = "2-b|3:error one|4-c|--|8-g|9:fatal two|10-h|" ]
  run "$SCRIPTS/excerpt.sh" "$log" x
  [ "$status" -eq 2 ]
}

# --- PR takeover: claims and intake -------------------------------------------------------

claim() { ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" "$SCRIPTS/pr-claim.sh" "$@" --repo o/r --pr 7; }

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

# gh stub: serves $GH_FIXTURE for `gh pr list`, and records the args it was called with.
stub_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/gh.args"
cat "$GH_FIXTURE"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" GH_FIXTURE="$BATS_TEST_TMPDIR/prs.json"
  cat >"$GH_FIXTURE" <<'JSON'
[
 {"number":1,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/a","updatedAt":"2026-09-27T00:00:00Z","url":"u1"},
 {"number":2,"author":{"login":"someone"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/b","updatedAt":"2026-09-27T00:00:00Z","url":"u2"},
 {"number":3,"author":{"login":"octocat"},"isDraft":true,"isCrossRepository":false,"headRefName":"work/c","updatedAt":"2026-09-27T00:00:00Z","url":"u3"},
 {"number":4,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":true,"headRefName":"work/d","updatedAt":"2026-09-27T00:00:00Z","url":"u4"},
 {"number":5,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/e","updatedAt":"2026-09-27T11:55:00Z","url":"u5"},
 {"number":6,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/f","updatedAt":"2026-09-27T00:00:00Z","url":"u6"},
 {"number":7,"author":{"login":"octocat"},"isDraft":false,"isCrossRepository":false,"headRefName":"work/g","updatedAt":"2026-09-27T00:00:00Z","url":"u7"}
]
JSON
}

intake() {
  cd "$REPO"
  ORCHESTRATE_AUTHOR=octocat ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 \
    "$SCRIPTS/pr-intake.sh" --repo o/r --owner ME "$@"
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

# --- codex-lane-run.sh cross-lane guard ---
runner_env() {
  RUNNER="$SCRIPTS/../../../bin/codex-lane-run.sh"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
out=""; while (($#)); do [[ $1 == --output-last-message ]] && out=$2; shift; done
spec=$(cat); printf 'saw:%s\n' "$(printf '%s\n' "$spec" | sed -n 2p)" >"$out"
SH
  chmod +x "$FAKEBIN/codex"
  OTHER="$BATS_TEST_TMPDIR/other"; mkdir -p "$OTHER"
  RUNDIR="$BATS_TEST_TMPDIR/run"; mkdir -p "$RUNDIR"
}
run_lane() { PATH="$FAKEBIN:$PATH" HOME="$BATS_TEST_TMPDIR/home" "$RUNNER" --model gpt-6-luna --spec "$1" --final "$RUNDIR/final.md" --log "$RUNDIR/codex.jsonl" --cd "$REPO" --poll 1; }

@test "runner runs a spec whose first line names its own worktree, from a snapshot" {
  runner_env
  printf 'LANE-WORKTREE: %s\nmy task\n' "$(cd "$REPO" && pwd -P)" >"$RUNDIR/spec.md"
  run run_lane "$RUNDIR/spec.md"
  [ "$status" -eq 0 ]
  [ "$(cat "$RUNDIR/final.md")" = "saw:my task" ]
  [ "$(sed -n 2p "$RUNDIR/codex.jsonl.spec")" = "my task" ]
  [ "$(cat "$RUNDIR/codex.jsonl.exit")" = "0" ]
}

@test "runner refuses a spec naming another worktree (exit 64)" {
  runner_env
  printf 'LANE-WORKTREE: %s\nforeign task\n' "$OTHER" >"$RUNDIR/spec.md"
  run run_lane "$RUNDIR/spec.md"
  [ "$status" -eq 64 ]
  [[ "$output" == *"may belong to another lane"* ]]
  [ ! -e "$RUNDIR/final.md" ]
}

@test "runner refuses a spec without the LANE-WORKTREE header (exit 64)" {
  runner_env
  printf 'no header\n' >"$RUNDIR/spec.md"
  run run_lane "$RUNDIR/spec.md"
  [ "$status" -eq 64 ]
}

@test "runner caps a 50,000-char message in its progress files and keeps the full log" {
  runner_env
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
out=""; while (($#)); do [[ $1 == --output-last-message ]] && out=$2; shift; done
cat >/dev/null
big=$(head -c 50000 /dev/zero | tr '\0' 'm')
printf '{"type":"item.completed","item":{"text":"%s"}}\n' "$big"
sleep 2
echo short >"$out"
SH
  printf 'LANE-WORKTREE: %s\ntask\n' "$(cd "$REPO" && pwd -P)" >"$RUNDIR/spec.md"
  run run_lane "$RUNDIR/spec.md"
  [ "$status" -eq 0 ]
  [ "$(wc -c <"$RUNDIR/codex.jsonl.progress.latest")" -lt 4000 ]
  [ "$(wc -c <"$RUNDIR/codex.jsonl.progress.state")" -lt 4000 ]
  grep -q 'truncated: 50000 chars' "$RUNDIR/codex.jsonl.progress.state"
  [ "$(wc -c <"$RUNDIR/codex.jsonl")" -gt 50000 ]
  [ -s "$RUNDIR/codex.jsonl.progress.rev" ]
}

WAITER() { "$SCRIPTS/../../../bin/codex-lane-wait.sh" "$@"; }

@test "lane wait: unchanged state gives a small no-change, a new revision wakes it, exit finishes it" {
  L="$BATS_TEST_TMPDIR/run/codex.jsonl"; mkdir -p "${L%/*}"
  : >"$L.spec"
  printf 'Codex alive: yes\nChanged entries: 0\n\nMost recent agent message or command:\nreading\n' >"$L.progress.state"
  echo rev1 >"$L.progress.rev"
  run WAITER --log "$L"
  [ "$status" -eq 10 ]
  [[ "${lines[0]}" == "progress rev=rev1" ]]
  run WAITER --log "$L" --since rev1 --timeout 1 --interval 1
  [ "$status" -eq 11 ]
  [[ "$output" == "no-change rev=rev1 alive=yes elapsed="* ]]
  [ "${#output}" -lt 80 ]
  ( sleep 1; echo rev2 >"$L.progress.rev" ) &
  run WAITER --log "$L" --since rev1 --timeout 20 --interval 1
  [ "$status" -eq 10 ]
  [[ "${lines[0]}" == "progress rev=rev2" ]]
  head -c 9000 /dev/zero | tr '\0' 'f' >"$L.final"
  ( sleep 1; echo 0 >"$L.exit" ) &
  run WAITER --log "$L" --since rev2 --timeout 20 --interval 1
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "done exit=0" ]]
  [ "${#output}" -lt 3200 ]
}

@test "lane wait refuses latest.* symlinks and unknown runs" {
  L="$BATS_TEST_TMPDIR/run/codex.jsonl"; mkdir -p "${L%/*}"; : >"$L.spec"
  ln -s "$L" "$BATS_TEST_TMPDIR/run/latest.jsonl"
  run WAITER --log "$BATS_TEST_TMPDIR/run/latest.jsonl"
  [ "$status" -eq 2 ]
  ln -s "$L" "$BATS_TEST_TMPDIR/run/alias.jsonl"
  run WAITER --log "$BATS_TEST_TMPDIR/run/alias.jsonl"
  [ "$status" -eq 2 ]
  run WAITER --log "$BATS_TEST_TMPDIR/run/nothing.jsonl"
  [ "$status" -eq 2 ]
}

@test "lane wait follows a real run to completion; a stalled run still ends at the stall limit" {
  runner_env
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
out=""; while (($#)); do [[ $1 == --output-last-message ]] && out=$2; shift; done
cat >/dev/null; sleep 3; echo finished >"$out"
SH
  printf 'LANE-WORKTREE: %s\ntask\n' "$(cd "$REPO" && pwd -P)" >"$RUNDIR/spec.md"
  run_lane "$RUNDIR/spec.md" >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$RUNDIR/codex.jsonl.spec" ] && break; sleep 0.5; done
  rev=""; st=10
  while [ "$st" -eq 10 ]; do
    run WAITER --log "$RUNDIR/codex.jsonl" --since "$rev" --timeout 30 --interval 1
    st=$status; rev=$(printf '%s' "${lines[0]}" | sed -n 's/^progress rev=//p')
  done
  [ "$st" -eq 0 ]
  [[ "$output" == "done exit=0"*"finished"* ]]
  wait
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null; exec sleep 30
SH
  run env PATH="$FAKEBIN:$PATH" HOME="$BATS_TEST_TMPDIR/home" "$RUNNER" --model gpt-6-luna --spec "$RUNDIR/spec.md" \
    --final "$RUNDIR/final2.md" --log "$RUNDIR/stall.jsonl" --cd "$REPO" --poll 1 --stall 2
  [ "$status" -eq 125 ]
  run WAITER --log "$RUNDIR/stall.jsonl" --timeout 1
  [[ "${lines[0]}" == "done exit=125" ]]
}

@test "lane start writes the spec with header and preamble, starts the run detached, and the waiter finishes it" {
  runner_env
  START="$SCRIPTS/../../../bin/codex-lane-start.sh"
  cd "$REPO"
  out=$(PATH="$FAKEBIN:$PATH" HOME="$BATS_TEST_TMPDIR/home" "$START" --model gpt-6-luna --effort "" <<<"my task")
  log=$(printf '%s\n' "$out" | sed -n 's/^LOG=//p')
  run_dir=$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')
  [ -n "$log" ] && [ -f "$run_dir/spec.md" ]
  [ "$(head -1 "$run_dir/spec.md")" = "LANE-WORKTREE: $(pwd -P)" ]
  grep -q 'explicit opt-out' "$run_dir/spec.md"
  [ "$(tail -1 "$run_dir/spec.md")" = "my task" ]
  run "$SCRIPTS/../../../bin/codex-lane-wait.sh" --log "$log" --timeout 30 --interval 1
  while [ "$status" -eq 10 ]; do run "$SCRIPTS/../../../bin/codex-lane-wait.sh" --log "$log" --since "${lines[0]#progress rev=}" --timeout 30 --interval 1; done
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "done exit=0" ]]
  ! grep -q model_reasoning_effort "$log.args"
  out=$(PATH="$FAKEBIN:$PATH" HOME="$BATS_TEST_TMPDIR/home" "$START" --model gpt-6-luna --effort high <<<"task two")
  log=$(printf '%s\n' "$out" | sed -n 's/^LOG=//p')
  grep -q 'model_reasoning_effort=high' "$log.args"
}

@test "lane start refuses an empty spec and reports a runner that stopped at once" {
  runner_env
  START="$SCRIPTS/../../../bin/codex-lane-start.sh"
  cd "$REPO"
  run env HOME="$BATS_TEST_TMPDIR/home" "$START" --model gpt-6-luna <<<"   "
  [ "$status" -eq 2 ]
  run env PATH="$FAKEBIN:$PATH" HOME="$BATS_TEST_TMPDIR/home" "$START" --model gpt-6-luna --soft nope <<<"task"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: codex-lane-run.sh"* ]]
}

@test "both implementer agents carry one compact, consistent contract" {
  A="$SCRIPTS/../../../agents"
  for f in "$A/codex-implementer.md" "$A/sol-implementer.md"; do
    [ "$(wc -c <"$f")" -lt 6500 ]
    for must in codex-lane-start.sh codex-lane-wait.sh "validate.sh run" -- "--independent" "empty diff" \
                "never implement the task yourself" "STATUS: unavailable" "cross-lane spec" "kill by pattern" \
                "codex-lane-reference.md" "JUDGMENT CALLS" "never wait on \`latest.*\`"; do
      [ "$must" = -- ] && continue
      grep -qF -- "$must" "$f" || { echo "missing in $f: $must"; false; }
    done
    ! grep -qiE 'progress\.latest|run_in_background|verbatim|include its actual output' "$f"
  done
  # The two variants differ only in model-specific lines.
  diff <(sed -E 's/codex-implementer|sol-implementer/LANE/g; s/gpt-6-luna|gpt-6-sol/SLUG/g' "$A/codex-implementer.md" | grep -v -E '^(description|# )|GPT-6|is fixed|architect.s call') \
       <(sed -E 's/codex-implementer|sol-implementer/LANE/g; s/gpt-6-luna|gpt-6-sol/SLUG/g' "$A/sol-implementer.md" | grep -v -E '^(description|# )|GPT-6|is fixed|architect.s call')
  [ -f "$SCRIPTS/../../../lanes/codex-lane-reference.md" ]
}

@test "role briefs agree with the agents on waiting and evidence" {
  R="$SCRIPTS/../roles"
  grep -q 'codex-lane-wait.sh' "$R/_common.md"
  grep -q 'codex-lane-wait.sh' "$R/implementation-lane.md"
  ! grep -q 'polling of the run' "$R/implementation-lane.md"
  ! grep -q "worktree's \`scratch/\`" "$R/_common.md"
}

@test "runner writes a usage receipt from codex's turn.completed events, without double counting" {
  runner_env
  cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
out=""; while (($#)); do [[ $1 == --output-last-message ]] && out=$2; shift; done
cat >/dev/null
echo '{"type":"thread.started","thread_id":"t1"}'
echo 'not json at all'
echo '{"type":"item.completed","item":{"text":"working"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":123,"cached_input_tokens":20,"output_tokens":10,"new_field":5}}'
echo '{"type":"turn.completed","usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":3}}'
echo done >"$out"
SH
  printf 'LANE-WORKTREE: %s\ntask\n' "$(cd "$REPO" && pwd -P)" >"$RUNDIR/spec.md"
  CODEX_LANE_SERVICE_TIER=fast run run_lane "$RUNDIR/spec.md"
  [ "$status" -eq 0 ]
  R="$RUNDIR/codex.jsonl.usage.json"
  jq -e '.schema == "waaagh.lane-usage/1" and .model == "gpt-6-luna" and .service_tier == "fast"
         and .exit == 0 and .turns == 2 and .usage_source == "codex-jsonl:turn.completed"
         and .usage.input_tokens == 130 and .usage.cached_input_tokens == 20 and .usage.output_tokens == 13
         and .usage.reasoning_output_tokens == null and .other_usage.new_field == 5
         and (.duration_s | type) == "number" and .lane_status == null' "$R"
  "$SCRIPTS/../../../bin/codex-lane-usage.sh" mark --log "$RUNDIR/codex.jsonl" --status complete
  [ "$(jq -r .lane_status "$R")" = complete ]
  run "$SCRIPTS/../../../bin/codex-lane-usage.sh" mark --log "$RUNDIR/codex.jsonl" --status great
  [ "$status" -eq 2 ]
}

@test "a log without usage events gives unknown counts, not zeros" {
  L="$BATS_TEST_TMPDIR/u/codex.jsonl"; mkdir -p "${L%/*}"
  printf '{"type":"item.completed","item":{"text":"x"}}\n{"type":"turn.failed","error":{"message":"boom"}}\n' >"$L"
  "$SCRIPTS/../../../bin/codex-lane-usage.sh" write --log "$L" --model gpt-6-sol --exit 1 --outcome "normal exit code 1"
  jq -e '.usage_source == "none" and .usage.input_tokens == null and .usage.output_tokens == null
         and .turns == 0 and .failed_turns == 1 and .effort == null and .duration_s == null' "$L.usage.json"
  rm "$L"
  "$SCRIPTS/../../../bin/codex-lane-usage.sh" write --log "$L"
  jq -e '.usage_source == "none"' "$L.usage.json"
}

@test "usage-report aggregates receipts by model and verified status and keeps unknowns visible" {
  D="$BATS_TEST_TMPDIR/lanes"; mkdir -p "$D/a" "$D/b" "$D/c"
  mk() { # dir model status input output finished source
    jq -n --arg m "$2" --arg s "$3" --argjson i "$4" --argjson o "$5" --arg f "$6" --arg src "$7" \
      '{schema: "waaagh.lane-usage/1", model: $m, lane_status: (if $s == "" then null else $s end),
        usage_source: $src, usage: {input_tokens: $i, cached_input_tokens: null, output_tokens: $o,
        reasoning_output_tokens: null}, duration_s: 10, finished_at: $f}' >"$D/$1/codex.jsonl.usage.json"
  }
  mk a gpt-6-luna complete 100 10 2026-10-01T00:00:00Z codex-jsonl:turn.completed
  mk b gpt-6-luna complete 50 5 2026-10-02T00:00:00Z codex-jsonl:turn.completed
  mk c gpt-6-sol "" null null 2026-10-03T00:00:00Z none
  echo '{"schema":"something/9"}' >"$D/c/other.usage.json"
  run "$SCRIPTS/usage-report.sh" --dir "$D" --dir "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'gpt-6-luna\tcomplete\t2\t0\t150\t-\t15\t-\t20'* ]]
  [[ "$output" == *$'gpt-6-sol\tunmarked\t1\t1\t-\t-\t-\t-\t10'* ]]
  [[ "$output" == *$'total\t-\t3\t1\t150\t-\t15\t-\t30'* ]]
  [[ "$output" == *"skipped 1 receipts with another schema"* ]]
  run "$SCRIPTS/usage-report.sh" --dir "$D" --since 2026-10-02T00:00:00Z
  [[ "$output" == *$'total\t-\t2\t'* ]]
}

# --- campaign scripts: readiness, merge, main health, issues, lanes, device lock ---------------

# gh stub that answers by subcommand from fixture files and records every call.
stub_gh_router() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api user") echo '{"login":"me"}' ;;
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) [ -f "$FX/rules-fails" ] && { echo "HTTP 403: Resource not accessible" >&2; exit 1; }; cat "$FX/rules.json" ;;
  "api repos/o/r/branches/"*) [ -f "$FX/branch-fails" ] && { echo "HTTP 403" >&2; exit 1; }; cat "$FX/branch.json" ;;
  *graphql*) # threads.json maps PR number -> thread nodes, "null" (no data), "more" (a next page
    # without a cursor) or {"pages": [[nodes], [nodes], ...]} (served through real cursors c1, c2, ...)
    [ -f "$FX/graphql-fails" ] && exit 1
    if [[ "$*" == *"cursor=c"* ]]; then
      n=$(printf '%s\n' "$*" | sed -nE 's/.*-F pr=([0-9]+).*/\1/p')
      c=$(printf '%s\n' "$*" | sed -nE 's/.*-f cursor=c([0-9]+).*/\1/p')
      echo "page $n $c" >>"$FX/pages"
      jq -n --argjson t "$(cat "$FX/threads.json")" --arg n "$n" --argjson c "$c" '$t[$n].pages as $p
        | {data: {repository: {pullRequest: {reviewThreads: {pageInfo: {hasNextPage: (($c + 1) < ($p | length)),
           endCursor: ("c" + (($c + 1) | tostring))}, nodes: $p[$c]}}}}}'
    else
      jq -n --argjson t "$(cat "$FX/threads.json")" --args '{data: {repository: (reduce $ARGS.positional[] as $n ({};
        .["p" + $n] = ($t[$n] // [] | if . == "null" then null
          elif . == "more" then {reviewThreads: {pageInfo: {hasNextPage: true}, nodes: []}}
          elif type == "object" then {reviewThreads: {pageInfo: {hasNextPage: ((.pages | length) > 1), endCursor: "c1"}, nodes: .pages[0]}}
          else {reviewThreads: {pageInfo: {hasNextPage: false}, nodes: .}} end)))}}' \
        $(printf '%s\n' "$*" | grep -oE ' p[0-9]+:' | tr -dc '0-9\n')
    fi ;;
  "pr merge"*) [ -f "$FX/merge-fails" ] && { echo "blocked"; exit 1; }
    # Like GitHub: refuse unless --match-head-commit names the current remote head exactly.
    want=$(printf '%s\n' "$*" | sed -nE 's/.*--match-head-commit ([0-9a-f]+).*/\1/p')
    cur=$(cat "$FX/remote-head" 2>/dev/null || jq -r .headRefOid "$FX/pr.json")
    { [ -n "$want" ] && [ "$want" = "$cur" ]; } || { echo "Head branch was modified. Review and try the merge again."; exit 1; }
    echo MERGED >"$FX/merged" ;;
  "pr view"*) if [ -f "$FX/merged" ]; then cat "$FX/pr-merged.json"
    elif [ -f "$FX/remote-head" ]; then jq --arg h "$(cat "$FX/remote-head")" '.headRefOid = $h' "$FX/pr.json"
    else cat "$FX/pr.json"; if [ -f "$FX/race" ]; then rm "$FX/race"; cp "$FX/race-head" "$FX/remote-head"; fi; fi ;;
  "pr list"*merged*) cat "$FX/prs-merged.json" ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "run list"*) cat "$FX/runs.json" ;;
  "issue list"*--label*) cat "$FX/pause.json" ;;
  "issue list"*) cat "$FX/issues.json" ;;
  "issue view"*) cat "$FX/issue.json" ;;
  "issue close"*) : ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400
  echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' >"$FX/rules.json"
  echo '{}' >"$FX/threads.json"
  echo '{"protected":false}' >"$FX/branch.json"
  echo '[]' >"$FX/pause.json"
  echo '[]' >"$FX/prs-merged.json"
}

pr_row() { # number author draft fork mergeable checks-json [labels-json]
  jq -cn --argjson n "$1" --arg a "$2" --argjson d "$3" --argjson f "$4" --arg m "$5" --argjson c "$6" --argjson l "${7:-[]}" \
    '{number:$n,author:{login:$a},isDraft:$d,isCrossRepository:$f,baseRefName:"main",headRefOid:("abcdef0123456789"+($n|tostring)),mergeable:$m,labels:$l,statusCheckRollup:$c}'
}
OKC='[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]'

@test "pr-ready classifies ready, waiting, blocked and skipped PRs" {
  stub_gh_router
  {
    pr_row 1 me false false MERGEABLE "$OKC"
    pr_row 2 me false false MERGEABLE '[{"name":"build","status":"IN_PROGRESS","conclusion":""}]'
    pr_row 3 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"lint","conclusion":"FAILURE"}]'
    pr_row 4 me false false CONFLICTING "$OKC"
    pr_row 5 me true false MERGEABLE "$OKC"
    pr_row 6 me false true MERGEABLE "$OKC"
    pr_row 7 other false false MERGEABLE "$OKC"
    pr_row 8 me false false MERGEABLE '[{"name":"lint","conclusion":"SUCCESS"}]'
    pr_row 9 me false false MERGEABLE "$OKC" '[{"name":"hold"}]'
    pr_row 10 me false false MERGEABLE '[{"name":"build","conclusion":"FAILURE","startedAt":"2026-09-27T01:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/50/job/500"},{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T02:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/50/job/501"}]'
    pr_row 11 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]'
    pr_row 12 me false false MERGEABLE '[{"name":"job (${{ matrix.os }})","conclusion":"CANCELLED","workflowName":"PR","startedAt":"2026-09-27T01:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/60/job/600"},{"name":"build","conclusion":"SUCCESS","workflowName":"PR","startedAt":"2026-09-27T02:00:00Z","detailsUrl":"https://github.com/o/r/actions/runs/61/job/610"}]'
    pr_row 13 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS","workflowName":"PR","startedAt":"2026-09-27T01:00:00Z"},{"name":"slow","conclusion":"CANCELLED","workflowName":"PR","startedAt":"2026-09-27T02:00:00Z"}]'
  } | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r --ignore-check sim
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tREADY'* ]]
  [[ "$output" == *$'2\tWAIT'*"pending:build"* ]]
  [[ "$output" == *$'3\tBLOCK'*"fail:lint"* ]]
  [[ "$output" == *$'4\tBLOCK'*"conflict"* ]]
  [[ "$output" == *$'5\tSKIP'*"draft"* ]]
  [[ "$output" == *$'6\tSKIP'*"fork"* ]]
  [[ "$output" != *$'\n7\t'* ]]
  [[ "$output" == *$'8\tBLOCK'*"missing-required:build"* ]]
  [[ "$output" == *$'9\tSKIP'*"hold"* ]]
  [[ "$output" == *$'10\tREADY'* ]]
  [[ "$output" == *$'11\tREADY'* ]]
  [[ "$output" == *$'12\tREADY'* ]]
  [[ "$output" == *$'13\tBLOCK'*"fail:slow"* ]]
  [[ "$output" == *"open=12 ready=4"* ]]
}

check() { # name conclusion workflow startedAt [run] [job] [typename]
  jq -cn --arg n "$1" --arg c "$2" --arg w "$3" --arg t "$4" --arg r "${5:-}" --arg j "${6:-}" --arg ty "${7:-CheckRun}" \
    '{__typename: $ty, name: $n, conclusion: $c, workflowName: $w, startedAt: $t}
     + (if $r == "" then {} else {detailsUrl: ("https://github.com/o/r/actions/runs/\($r)" + (if $j == "" then "" else "/job/\($j)" end))} end)'
}
verdict_of() { # checks... -> the verdict and detail of one PR built from them
  printf '%s\n' "$@" | jq -s . >"$FX/checks.json"
  pr_row 1 me false false MERGEABLE "$(cat "$FX/checks.json")" | jq -s . >"$FX/prs.json"
  "$SCRIPTS/pr-ready.sh" --repo o/r --no-threads 2>/dev/null | cut -f2,6
}

@test "pr-ready supersedes only proven replacements of the same check" {
  stub_gh_router
  echo '[]' >"$FX/rules.json"
  T1=2026-09-27T01:00:00Z T2=2026-09-27T02:00:00Z
  # A later sibling in the same run does not replace a cancelled job.
  [ "$(verdict_of "$(check unit CANCELLED CI $T1 70 700)" "$(check lint SUCCESS CI $T2 70 701)")" = $'BLOCK\tfail:unit' ]
  # The same without any run identity: still blocked.
  [ "$(verdict_of "$(check unit CANCELLED CI $T1)" "$(check lint SUCCESS CI $T2)")" = $'BLOCK\tfail:unit' ]
  # Same job name in two workflows: the Linux failure is not hidden by the Mac success.
  [ "$(verdict_of "$(check test FAILURE Linux $T1 71 710)" "$(check test SUCCESS Mac $T2 72 720)")" = $'BLOCK\tfail:test' ]
  # Same name from two providers (an Actions job and a status context).
  [ "$(verdict_of "$(check test FAILURE "" $T1 "" "" StatusContext)" "$(check test SUCCESS CI $T2 73 730)")" = $'BLOCK\tfail:test' ]
  # A rerun attempt (same run, newer job id) replaces the failure, whatever the timestamps say.
  [ "$(verdict_of "$(check unit FAILURE CI $T2 74 740)" "$(check unit SUCCESS CI $T2 74 741)")" = $'READY\t-' ]
  [ "$(verdict_of "$(check unit FAILURE CI "" 74 740)" "$(check unit SUCCESS CI "" 74 741)")" = $'READY\t-' ]
  # A genuinely newer run of the same workflow and job replaces a cancellation...
  [ "$(verdict_of "$(check unit CANCELLED CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)")" = $'READY\t-' ]
  # ...but not a failure: two runs of one workflow on the same head (push and pull_request) both count.
  [ "$(verdict_of "$(check unit FAILURE CI $T1 75 750)" "$(check unit SUCCESS CI $T2 76 760)")" = $'BLOCK\tfail:unit' ]
  # Partial rerun: the rerun job replaces only itself; an untouched failure in that run stays.
  [ "$(verdict_of "$(check unit FAILURE CI $T1 77 770)" "$(check e2e FAILURE CI $T1 77 771)" "$(check unit SUCCESS CI $T2 77 772)")" = $'BLOCK\tfail:e2e' ]
  # Matrix jobs are distinct checks; one failing leg blocks.
  [ "$(verdict_of "$(check "test (linux)" SUCCESS CI $T1 78 780)" "$(check "test (mac)" FAILURE CI $T1 78 781)")" = $'BLOCK\tfail:test (mac)' ]
  # Duplicates without run identity and equal or missing timestamps: every instance counts.
  [ "$(verdict_of "$(check build FAILURE CI $T1)" "$(check build SUCCESS CI $T1)")" = $'BLOCK\tfail:build' ]
  [ "$(verdict_of "$(check build SUCCESS CI "")" "$(check build FAILURE CI "")")" = $'BLOCK\tfail:build' ]
  # A cancelled matrix template without run identity is not superseded.
  [ "$(verdict_of "$(check 'job (${{ matrix.os }})' CANCELLED PR $T1)" "$(check build SUCCESS PR $T2)")" = $'BLOCK\tfail:job (${{ matrix.os }})' ]
}

@test "pr-ready lets a legacy status context's newer status replace its older one" {
  stub_gh_router
  echo '[]' >"$FX/rules.json"
  old=$(jq -cn '{__typename: "StatusContext", context: "ci/legacy", state: "FAILURE", startedAt: "2026-09-27T01:00:00Z"}')
  new=$(jq -cn '{__typename: "StatusContext", context: "ci/legacy", state: "SUCCESS", startedAt: "2026-09-27T02:00:00Z"}')
  [ "$(verdict_of "$old" "$new")" = $'READY\t-' ]
  [[ "$(verdict_of "$new" "$(jq -c '.startedAt = "2026-09-27T03:00:00Z"' <<<"$old")")" == $'BLOCK\tfail:ci/legacy'* ]]
}

@test "pr-ready blocks an otherwise ready PR with an unresolved review thread" {
  stub_gh_router
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  echo '{"1":[{"isResolved":false,"isOutdated":false},{"isResolved":false,"isOutdated":true}]}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'1\tBLOCK'*"threads=1"* ]]
}

@test "pr-ready fails closed when review threads are unreadable or span more than one page" {
  stub_gh_router
  { pr_row 1 me false false MERGEABLE "$OKC"; pr_row 2 me false false MERGEABLE "$OKC"; pr_row 3 me false false MERGEABLE "$OKC"; } |
    jq -s . >"$FX/prs.json"
  echo '{"1":"null","2":"more"}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'1\tBLOCK'*"threads=unknown"* ]]
  [[ "$output" == *$'2\tBLOCK'*"threads=unknown"* ]]
  [[ "$output" == *$'3\tREADY'* ]]
  touch "$FX/graphql-fails"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'3\tBLOCK'*"threads=unknown"* ]]
  [[ "$output" == *"ready=0"* ]]
}

@test "pr-ready never reports READY when the required-check policy is unreadable or malformed" {
  stub_gh_router
  pr_row 7 me false false MERGEABLE '[{"name":"lint","conclusion":"SUCCESS"}]' | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"missing-required:build"* ]]
  echo '[]' >"$FX/rules.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tREADY'* ]]
  touch "$FX/rules-fails"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'7\tBLOCK'*"policy=unknown"* ]]
  [[ "$output" == *"policy=unknown diagnostics="* ]]
  diag=$(printf '%s\n' "$output" | sed -n 's/.*diagnostics=//p')
  grep -q 'HTTP 403' "$diag"
  rm "$FX/rules-fails"
  echo '{"message":"oops"}' >"$FX/rules.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"policy=unknown"* ]]
  echo '[]' >"$FX/rules.json"
  touch "$FX/branch-fails"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"policy=unknown"* ]]
}

@test "pr-ready reads required checks from classic branch protection too" {
  stub_gh_router
  echo '[]' >"$FX/rules.json"
  echo '{"protected":true,"protection":{"required_status_checks":{"contexts":["ci/legacy"],"checks":[{"context":"build"}]}}}' >"$FX/branch.json"
  pr_row 7 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"missing-required:ci/legacy"* ]]
}

@test "pr-ready follows review-thread pages: an unresolved 101st thread blocks, all resolved passes" {
  stub_gh_router
  pr_row 7 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
  jq -n '{"7": {pages: [[range(0; 100) | {isResolved: true, isOutdated: false}], [{isResolved: false, isOutdated: false}]]}}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tBLOCK'*"threads=1"* ]]
  [ "$(cat "$FX/pages")" = "page 7 1" ]
  jq -n '{"7": {pages: [[range(0; 100) | {isResolved: true, isOutdated: false}], [range(0; 100) | {isResolved: true, isOutdated: false}], [{isResolved: true, isOutdated: false}]]}}' >"$FX/threads.json"
  : >"$FX/pages"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'7\tREADY'* ]]
  [ "$(wc -l <"$FX/pages")" -eq 2 ]
}

ready_prs() { # n: n mergeable, green PRs by me
  for i in $(seq 1 "$1"); do pr_row "$i" me false false MERGEABLE "$OKC"; done | jq -s . >"$FX/prs.json"
}

@test "pr-ready reads review threads in one batched call per 50 ready PRs" {
  stub_gh_router
  ready_prs 20
  run "$SCRIPTS/pr-ready.sh" --repo o/r --base main --author me
  [ "$status" -eq 0 ]
  [[ "$output" == *"open=20 ready=20"* ]]
  [ "$(grep -c graphql "$FX/calls")" -eq 1 ]
  [ "$(wc -l <"$FX/calls")" -eq 4 ]
  : >"$FX/calls"
  ready_prs 100
  run "$SCRIPTS/pr-ready.sh" --repo o/r --base main
  [[ "$output" == *"open=100 ready=100"* ]]
  [ "$(grep -c graphql "$FX/calls")" -eq 2 ]
}

@test "the merge-bot loop over 20 ready PRs makes 20 thread calls, not 210" {
  stub_gh_router
  for n in $(seq 20 -1 1); do
    ready_prs "$n"
    "$SCRIPTS/pr-ready.sh" --repo o/r --base main >/dev/null 2>&1
  done
  [ "$(grep -c graphql "$FX/calls")" -eq 20 ]
}

@test "pr-ready --delta prints only changes, GONE rows, or a one-line no-change" {
  stub_gh_router
  ready_prs 20
  run "$SCRIPTS/pr-ready.sh" --repo o/r --delta
  [ "$(printf '%s\n' "$output" | grep -c READY)" -eq 20 ]
  run "$SCRIPTS/pr-ready.sh" --repo o/r --delta
  [[ "$output" == "no-change"*"changed=0"* ]]
  [ "${#output}" -lt 80 ]
  # PR 1 merged (gone), PR 2 got a new head, PR 3 gained a failing check.
  jq '.[1:] | (.[0].headRefOid = "ffffffffff") | (.[1].statusCheckRollup += [{"name":"lint","conclusion":"FAILURE"}])' \
    "$FX/prs.json" >"$FX/p2" && mv "$FX/p2" "$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r --delta
  [[ "$output" == *$'1\tGONE'* ]]
  [[ "$output" == *$'2\tREADY\tfffffffff'* ]]
  [[ "$output" == *$'3\tBLOCK'*"fail:lint"* ]]
  [ "$(printf '%s\n' "$output" | grep -vc '^open=')" -eq 3 ]
  # A different invocation (other arguments) keeps its own snapshot.
  run "$SCRIPTS/pr-ready.sh" --repo o/r --delta --no-threads
  [ "$(printf '%s\n' "$output" | grep -c READY)" -eq 18 ]
}

@test "pr-ready reports a PR list that hit its limit" {
  stub_gh_router
  ready_prs 300
  run "$SCRIPTS/pr-ready.sh" --repo o/r --no-threads
  [[ "$output" == *"truncated=yes"* ]]
}

merge_fixture() {
  stub_gh_router
  echo '{"state":"OPEN","isDraft":false,"isCrossRepository":false,"headRefOid":"abcdef0123456789abcdef0123456789abcdef01","author":{"login":"me"},"mergeable":"MERGEABLE"}' >"$FX/pr.json"
  echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}' >"$FX/pr-merged.json"
  pr_row 1 me false false MERGEABLE "$OKC" | jq -s . >"$FX/prs.json"
}
# The readiness row for the admin tests: build passes, "sim" failed (a classified flake).
sim_fails() { pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"; }

@test "pr-merge merges a verified head and logs it" {
  merge_fixture
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 0 ]
  [[ "$output" == "merged 1 feedface" ]]
  grep -q 'pr merge 1 --repo o/r --squash --match-head-commit abcdef0123456789abcdef0123456789abcdef01$' "$FX/calls"
  grep -q $'head=abcdef0123456789abcdef0123456789abcdef01\tmerged feedface' "$ORCHESTRATE_STATE_DIR/o__r/merges.log"
}

@test "pr-merge refuses when the head moves between its check and the merge" {
  merge_fixture
  touch "$FX/race"; echo 1111111111111111111111111111111111111111 >"$FX/race-head"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 3 ]
  [[ "$output" == "head moved during merge: judged abcdef012, now 111111111"* ]]
  [ ! -f "$FX/merged" ]
  [ "$(grep -c 'pr merge' "$FX/calls")" -eq 1 ]
  grep -q $'head=abcdef0123456789abcdef0123456789abcdef01\trefused head moved during merge to 111111111' "$ORCHESTRATE_STATE_DIR/o__r/merges.log"
}

@test "pr-merge --admin keeps the same head guard" {
  merge_fixture
  sim_fails
  touch "$FX/race"; echo 2222222222222222222222222222222222222222 >"$FX/race-head"
  ORCHESTRATE_FAST_PATH_OVER=0 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --except-check sim --evidence "known flake: sim timeout"
  [ "$status" -eq 3 ]
  grep -q 'pr merge 1 --repo o/r --squash --match-head-commit abcdef0123456789abcdef0123456789abcdef01 --admin' "$FX/calls"
  [ ! -f "$FX/merged" ]
}

@test "pr-merge refuses a moved head, a foreign author, and a red default branch" {
  merge_fixture
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head 1234567
  [ "$status" -eq 3 ]
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --author someone
  [ "$status" -eq 3 ]
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red abc" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 4 ]
  ! grep -q 'pr merge' "$FX/calls"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --main-fix
  [ "$status" -eq 0 ]
}

@test "pr-merge allows --admin only in the fast path and only with evidence" {
  merge_fixture
  sim_fails
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin
  [ "$status" -eq 6 ]
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --except-check sim --evidence "known flake: sim timeout"
  [ "$status" -eq 6 ]
  [[ "$output" == *"fast-path only"* ]]
  ! grep -q 'pr merge' "$FX/calls"
  ORCHESTRATE_FAST_PATH_OVER=0 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --evidence "known flake: sim timeout"
  [ "$status" -eq 6 ]
  [[ "$output" == *"needs --except-check"* ]]
  ORCHESTRATE_FAST_PATH_OVER=0 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --except-check sim --evidence "known flake: sim timeout"
  [ "$status" -eq 0 ]
  grep -q 'pr merge 1 --repo o/r --squash --match-head-commit abcdef0123456789abcdef0123456789abcdef01 --admin' "$FX/calls"
}

@test "pr-ready reports every blocker of a failing PR, including review threads it now reads" {
  stub_gh_router
  pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"test","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  echo '{"1":[{"isResolved":false,"isOutdated":false}]}' >"$FX/threads.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'1\tBLOCK\t'*$'\tfail:test threads=1'* ]]
  grep -q graphql "$FX/calls"
  pr_row 2 me false false UNKNOWN '[{"name":"build","status":"IN_PROGRESS"},{"name":"test","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-ready.sh" --repo o/r
  [[ "$output" == *$'2\tBLOCK\t'*$'\tfail:test pending:build mergeable=UNKNOWN'* ]]
  run "$SCRIPTS/pr-ready.sh" --repo o/r --pr 3
  [ -z "$(printf '%s\n' "$output" | grep -v '^open=')" ]
}

@test "the admin exception covers only the excepted checks, never review, policy or other failures" {
  merge_fixture
  sim_fails
  export ORCHESTRATE_FAST_PATH_OVER=0
  adm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 --admin --evidence "sim: known flake" "$@"; }
  # A classified flake plus an unresolved review thread is refused.
  echo '{"1":[{"isResolved":false,"isOutdated":false}]}' >"$FX/threads.json"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"threads=1"* ]]
  # Unreadable review threads cannot authorize it either.
  echo '{"1":"null"}' >"$FX/threads.json"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"threads=unknown"* ]]
  echo '{}' >"$FX/threads.json"
  # A failure that is not excepted, or a pending check, is refused.
  pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"FAILURE"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"fail:build (not excepted)"* ]]
  pr_row 1 me false false MERGEABLE '[{"name":"build","status":"IN_PROGRESS"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"pending:build"* ]]
  # Unknown policy is not waived by a check exception.
  pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"
  touch "$FX/rules-fails"
  adm --except-check sim
  [ "$status" -eq 6 ]
  [[ "$output" == *"policy=unknown"* ]]
  ! grep -q 'pr merge' "$FX/calls"
  rm "$FX/rules-fails"
  adm --except-check sim
  [ "$status" -eq 0 ]
}

@test "pr-merge refuses a PR that is not READY unless direct merging was authorized" {
  merge_fixture
  sim_fails
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 7 ]
  [[ "$output" == "not ready: BLOCK fail:sim"* ]]
  pr_row 1 me false false UNKNOWN '[{"name":"build","status":"IN_PROGRESS"}]' | jq -s . >"$FX/prs.json"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 7 ]
  [[ "$output" == "not ready: WAIT pending:build"* ]]
  ! grep -q 'pr merge' "$FX/calls"
  ORCHESTRATE_DIRECT_MERGE=1 run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 0 ]
}

@test "pr-merge reports a merge GitHub rejected" {
  merge_fixture
  touch "$FX/merge-fails"
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0
  [ "$status" -eq 5 ]
}

@test "main-health sets and clears MAIN_RED from the newest completed run per workflow" {
  stub_gh_router
  cat >"$FX/runs.json" <<'JSON'
[{"workflowName":"On Merge","status":"completed","conclusion":"success","headSha":"aaaaaaaaaaaa","databaseId":1,"createdAt":"2026-09-27T01:00:00Z"},
 {"workflowName":"On Merge","status":"completed","conclusion":"failure","headSha":"bbbbbbbbbbbb","databaseId":2,"createdAt":"2026-09-27T02:00:00Z"},
 {"workflowName":"On Merge","status":"in_progress","conclusion":"","headSha":"cccccccccccc","databaseId":3,"createdAt":"2026-09-27T03:00:00Z"},
 {"workflowName":"Badges","status":"completed","conclusion":"failure","headSha":"bbbbbbbbbbbb","databaseId":4,"createdAt":"2026-09-27T02:00:00Z"}]
JSON
  run "$SCRIPTS/main-health.sh" --repo o/r --ignore-workflow Badges
  [ "$status" -eq 1 ]
  [[ "$output" == "red bbbbbbbbb On Merge=failure(2)" ]]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
  jq '.[1].conclusion="success"' "$FX/runs.json" >"$FX/r2" && mv "$FX/r2" "$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --workflow "On Merge"
  [ "$status" -eq 0 ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
  echo '[]' >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r
  [ "$status" -eq 2 ]
}

run_json() { # workflow status conclusion sha id createdAt
  jq -cn --arg w "$1" --arg s "$2" --arg c "$3" --arg h "$4" --argjson id "$5" --arg t "$6" \
    '{workflowName:$w,status:$s,conclusion:$c,headSha:$h,databaseId:$id,createdAt:$t}'
}

@test "main-health keeps the hold when a selected workflow has no completed evidence" {
  stub_gh_router
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red old" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  { run_json Build completed success aaaaaaaaaaaa 1 2026-09-27T01:00:00Z
    run_json Tests in_progress "" bbbbbbbbbbbb 2 2026-09-27T02:00:00Z; } | jq -s . >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Tests
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Tests(pending)" ]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Deploy
  [ "$output" = "unknown missing=Deploy(no-run)" ]
  # The pending-only control stays unknown.
  run_json Tests in_progress "" bbbbbbbbbbbb 2 2026-09-27T02:00:00Z | jq -s . >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main
  [ "$status" -eq 2 ]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
}

@test "main-health clears the hold only with every selected workflow green, naming each SHA" {
  stub_gh_router
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red old" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  { run_json Build completed success aaaaaaaaaaaa 1 2026-09-27T01:00:00Z
    run_json Tests completed success bbbbbbbbbbbb 2 2026-09-27T02:00:00Z
    run_json Badges completed failure bbbbbbbbbbbb 3 2026-09-27T02:00:00Z; } | jq -s . >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Tests --ignore-workflow Badges
  [ "$status" -eq 0 ]
  [ "$output" = "green bbbbbbbbb Build@aaaaaaaaa,Tests@bbbbbbbbb mixed-heads" ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
  # Ignored workflows stay advisory; the same failure in a selected workflow is red.
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --ignore-workflow Badges
  [ "$status" -eq 0 ]
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Badges
  [ "$status" -eq 1 ]
  [ "$output" = "red bbbbbbbbb Badges=failure(3)" ]
}

@test "main-health tells an exhausted run window from a missing workflow, and an unreadable list from red" {
  stub_gh_router
  for i in 1 2 3; do run_json Build completed success "aaaaaaaaaa0$i" "$i" "2026-09-27T0$i:00:00Z"; done | jq -s . >"$FX/runs.json"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Nightly --limit 3
  [ "$status" -eq 2 ]
  [ "$output" = "unknown missing=Nightly(not-in-window)" ]
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main --workflow Build --workflow Nightly --limit 10
  [ "$output" = "unknown missing=Nightly(no-run)" ]
  echo 'not json' >"$FX/runs.json"
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red old" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  run "$SCRIPTS/main-health.sh" --repo o/r --branch main
  [ "$status" -eq 2 ]
  [[ "$output" == "unknown run list unreadable"* ]]
  [ -f "$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED" ]
}

@test "campaign lanes follow the three tiers and accept overrides" {
  [ "$("$SCRIPTS/campaign.sh" lanes --bots idle --verify idle)" = 16 ]
  [ "$("$SCRIPTS/campaign.sh" lanes --bots working --verify idle)" = 12 ]
  [ "$("$SCRIPTS/campaign.sh" lanes --bots idle --verify running)" = 4 ]
  [ "$(ORCHESTRATE_LANES=8,6,2 "$SCRIPTS/campaign.sh" lanes --bots working --verify idle)" = 6 ]
  [ "$("$SCRIPTS/campaign.sh" lanes --lanes 10,5,1 --bots idle --verify running)" = 1 ]
}

@test "campaign status reports merge mode, verification due, pause and main state" {
  stub_gh_router
  jq -n '[range(0;21)|{number:.}]' >"$FX/prs.json"
  jq -n '[range(0;16)|{number:.}]' >"$FX/prs-merged.json"
  run "$SCRIPTS/campaign.sh" status --repo o/r --bots idle
  [ "$status" -eq 0 ]
  [[ "$output" == *"paused=no"* ]]
  [[ "$output" == *"open_prs=21"* ]]
  [[ "$output" == *"merge_mode=fast"* ]]
  [[ "$output" == *"main=ok"* ]]
  [[ "$output" == *"verification_due=yes"* ]]
  [[ "$output" == *"lanes=16"* ]]
  jq -n '[range(0;20)|{number:.}]' >"$FX/prs.json"
  echo '[{"number":9}]' >"$FX/pause.json"
  run "$SCRIPTS/campaign.sh" status --repo o/r --verify-every 20
  [[ "$output" == *"merge_mode=conservative"* ]]
  [[ "$output" == *"verification_due=no"* ]]
  [[ "$output" == *"paused=yes"* ]]
  "$SCRIPTS/campaign.sh" verified --repo o/r --sha abc123
  [ "$(jq -r .last_verification_sha "$ORCHESTRATE_STATE_DIR/o__r/campaign.json")" = abc123 ]
}

@test "issues-ranked puts priority bugs first, then bugs, newest first, and marks issues in a PR" {
  stub_gh_router
  echo '[{"number":50,"closingIssuesReferences":[{"number":3}]}]' >"$FX/prs.json"
  cat >"$FX/issues.json" <<'JSON'
[{"number":1,"title":"docs typo","labels":[],"updatedAt":"2026-09-27T09:00:00Z"},
 {"number":2,"title":"old bug","labels":[{"name":"bug"}],"updatedAt":"2026-09-25T09:00:00Z"},
 {"number":3,"title":"new bug","labels":[{"name":"bug"}],"updatedAt":"2026-09-27T08:00:00Z"},
 {"number":4,"title":"fold bug","labels":[{"name":"bug"},{"name":"foldable"}],"updatedAt":"2026-09-24T09:00:00Z"},
 {"number":5,"title":"stuck","labels":[{"name":"bug"},{"name":"blocked"}],"updatedAt":"2026-09-27T09:30:00Z"}]
JSON
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --priority-label foldable
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')" = "4 3 2 1 " ]
  [[ "$output" == *$'3\tbug\t50'* ]]
  grep -q 'updated:>=2026-09-20' "$FX/calls"
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --skip-in-pr
  [ "$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')" = "2 4 1 " ]
}

@test "issue-candidates finds fixed-by-merged-PR and duplicate-title leads" {
  stub_gh_router
  cat >"$FX/issues.json" <<'JSON'
[{"number":10,"title":"tapOn hangs when the keyboard is open"},
 {"number":11,"title":"tapOn hangs when keyboard open on foldable"},
 {"number":12,"title":"observe returns stale hierarchy"}]
JSON
  echo '[{"number":90,"mergedAt":"2026-09-26T00:00:00Z","body":"Fixes #12 and refs #10","closingIssuesReferences":[{"number":11}]}]' >"$FX/prs-merged.json"
  run "$SCRIPTS/issue-candidates.sh" fixed --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'11\t90\t'*$'\tlinked\t'* ]]
  [[ "$output" == *$'12\t90\t'*$'\tbody\t'* ]]
  [[ "$output" != $'10\t'* ]]
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -vc '^# ')" = 1 ]
  [[ "$output" == *$'0.8\t10\t11\t'* ]]
  [[ "$output" == *"# shown 1 of 1 leads (0 clusters, 1 pairs; 0 over the per-issue cap); all: $ORCHESTRATE_STATE_DIR/o__r/candidates/dupes-"*.tsv ]]
}

# n issues titled the same, numbered 1..n, plus optional extra JSON rows.
dupes_fixture() {
  jq -n --argjson n "$1" --argjson extra "${2:-[]}" \
    '[range(1; $n + 1) | {number: ., title: "Fix shared device session recovery failure"}] + $extra' >"$FX/issues.json"
}
DIVERSE='[{"number":901,"title":"Crash when the keyboard opens on tablet"},
          {"number":902,"title":"Crash when keyboard opens on tablets"},
          {"number":903,"title":"Login screen shows stale avatar image"},
          {"number":904,"title":"Login screen shows a stale avatar"}]'

@test "dupes collapses a repetitive cluster into one bounded row and keeps unrelated leads" {
  stub_gh_router
  dupes_fixture 100 "$DIVERSE"
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 2000 ]
  [ "$(printf '%s\n' "$output" | grep -vc '^# ')" = 3 ]
  first=$(printf '%s\n' "$output" | head -1)
  [[ "$first" == $'1\t1\t2,3,4,5,6,7,8,9,10,11,+89\tFix shared device session recovery failure\t(same title words)' ]]
  [[ "$output" == *$'\t901\t902\t'* ]]
  [[ "$output" == *$'\t903\t904\t'* ]]
  [[ "$output" == *"# shown 3 of 3 leads (1 clusters, 2 pairs"* ]]
  full=$(printf '%s\n' "$output" | sed -n 's/^# .*; all: //p')
  [ -f "$full" ]
  [[ "$(head -1 "$full")" == $'1\t1\t2,3,'* ]]
}

@test "dupes stays bounded and stable at the 400-issue fetch limit" {
  stub_gh_router
  dupes_fixture 400 "$DIVERSE"
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 2000 ]
  first=$output
  ORCHESTRATE_NOW=1790510401 run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r
  [ "$(printf '%s\n' "$output" | grep -v '^# ')" = "$(printf '%s\n' "$first" | grep -v '^# ')" ]
}

@test "dupes caps rows per issue and in total, and reports what it omitted" {
  stub_gh_router
  # One hub title that shares most words with each of six distinct variants.
  jq -n '[{number: 1, title: "alpha beta gamma delta epsilon"}]
    + [range(2; 8) | {number: ., title: "alpha beta gamma delta variant\(.)"}]' >"$FX/issues.json"
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r --per-issue 2
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -v '^# ' | cut -f2,3 | grep -c '^1	')" = 2 ]
  [[ "$output" == *"over the per-issue cap"* ]]
  run "$SCRIPTS/issue-candidates.sh" dupes --repo o/r --limit 3
  [ "$(printf '%s\n' "$output" | grep -vc '^# ')" = 3 ]
  [[ "$output" == *"# shown 3 of "* ]]
}

@test "issue-close requires verified evidence and refuses protected or unverifiable closes" {
  stub_gh_router
  echo '{"state":"OPEN","labels":[]}' >"$FX/issue.json"
  echo '{"state":"OPEN"}' >"$FX/pr.json"
  E="src/x.ts:10 now awaits the write; the race is gone"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "$E"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not merged"* ]]
  echo '{"state":"MERGED"}' >"$FX/pr.json"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "$E" --dry-run
  [ "$status" -eq 0 ]
  ! grep -q 'issue close' "$FX/calls"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "$E"
  [ "$status" -eq 0 ]
  grep -q 'issue close 5 --repo o/r --reason completed' "$FX/calls"
  grep -q 'issue=5' "$ORCHESTRATE_STATE_DIR/o__r/hygiene-actions.log"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 5 --evidence "$E"
  [ "$status" -eq 3 ]
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 6 --evidence "$E"
  [ "$status" -eq 0 ]
  grep -q 'issue close 5 --repo o/r --duplicate-of 6' "$FX/calls"
  echo '{"state":"OPEN","labels":[{"name":"epic"}]}' >"$FX/issue.json"
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as duplicate --of 6 --evidence "$E"
  [ "$status" -eq 3 ]
  run "$SCRIPTS/issue-close.sh" --repo o/r --issue 5 --as fixed --pr 9 --evidence "short"
  [ "$status" -eq 2 ]
}

@test "device lock is exclusive while its holder is alive and reclaimable when stale" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  [ "$(lock status)" = free ]
  ORCHESTRATE_NOW=1000 run lock claim --name verify --pid $$
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=1100 run lock claim --name explorer --pid $$
  [ "$status" -eq 3 ]
  ORCHESTRATE_NOW=1100 run lock release --name explorer
  [[ "$output" == "not held by explorer" ]]
  ORCHESTRATE_NOW=$((1000 + 10 * 3600)) run lock claim --name explorer --pid $$
  [ "$status" -eq 0 ]
  echo "999999 1000 ghost" >"$L"
  ORCHESTRATE_NOW=1100 run lock claim --name verify --pid $$
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=1100 lock release --name verify
  [ "$(lock status)" = free ]
}

@test "device lock claim prints a token; release by token works for a dead-PID holder" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  # claim from a subshell: its PID is gone by the time release runs
  out=$( (lock claim --name lane1 --pid "$BASHPID") )
  [ "$(echo "$out" | head -1)" = claimed ]
  tok=$(echo "$out" | sed -n 's/^token //p')
  [ -n "$tok" ]
  run lock release --name other --token wrong
  [[ "$output" == "token does not match the holder" ]]
  [ -f "$L" ]
  run lock release --token "$tok"
  [[ "$output" == released ]]
  [ "$(lock status)" = free ]
}

@test "device lock release by name works when the recorded holder PID is dead" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  (lock claim --name lane2 --pid "$BASHPID" >/dev/null)
  run lock status
  [[ "$output" == *"name=lane2"*"live=no"* ]]
  run lock release --name lane2
  [[ "$output" == released ]]
  [ "$(lock status)" = free ]
}

@test "device lock stale dead-PID holder is reclaimable by another name" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  printf '999999 1000 finished-lane\n' >"$L"
  ORCHESTRATE_NOW=1100 run lock claim --name next --pid $$
  [ "$status" -eq 0 ]
  [[ "$output" == claimed* ]]
}

@test "device lock treats a reused PID (start time mismatch) as stale but a matching one as live" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  run lock claim --name holder --pid $$
  [ "$status" -eq 0 ]
  run lock claim --name rival --pid $$
  [ "$status" -eq 3 ]
  # simulate PID reuse: same live PID, different recorded start time
  sed -i.bak 's/ start=.*/ start=Mon Jan 1 00:00:00 1990/' "$L"
  run lock status
  [[ "$output" == *"live=no"* ]]
  run lock claim --name rival --pid $$
  [ "$status" -eq 0 ]
}

@test "device lock legacy single-line format is still read as live while its PID runs" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  printf '%s %s legacy\n' "$$" "$(date +%s)" >"$L"
  run lock claim --name rival --pid $$
  [ "$status" -eq 3 ]
  run lock release --name legacy
  [[ "$output" == released ]]
}

@test "device lock --no-pid holds by age only and stays exclusive" {
  L="$BATS_TEST_TMPDIR/device.lock"
  lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
  ORCHESTRATE_NOW=1000 run lock claim --name sub --no-pid
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=1100 run lock claim --name rival --pid $$
  [ "$status" -eq 3 ]
  ORCHESTRATE_NOW=$((1000 + 10 * 3600)) run lock claim --name rival --pid $$
  [ "$status" -eq 0 ]
}

@test "device lock resolves its path from --state-dir or the env var outside any repo" {
  D="$BATS_TEST_TMPDIR/sd"
  cd "$BATS_TEST_TMPDIR"
  run "$SCRIPTS/device-lock.sh" claim --name a --pid $$ --state-dir "$D"
  [ "$status" -eq 0 ]
  [ -f "$D/device.lock" ]
  ORCHESTRATE_DEVICE_LOCK_DIR="$D" run "$SCRIPTS/device-lock.sh" status
  [[ "$output" == "held name=a"* ]]
  ORCHESTRATE_DEVICE_LOCK_DIR="$D" run "$SCRIPTS/device-lock.sh" claim --name b --pid $$
  [ "$status" -eq 3 ]
  # no repo, no dir: falls back to the global state dir without needing gh
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/st" run "$SCRIPTS/device-lock.sh" claim --name c --pid $$
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/st/device.lock" ]
}

# --- validation receipts ---------------------------------------------------------------------
val() { ORCHESTRATE_VALIDATE_DIR="$BATS_TEST_TMPDIR/store" "$SCRIPTS/validate.sh" "$@" --dir "$REPO"; }

@test "writing validation logs into the checkout changes the fingerprint; validate.sh writes outside it" {
  before=$(fp)
  mkdir -p "$REPO/scratch"; echo "all tests pass" >"$REPO/scratch/validate.log"
  [ "$(fp)" != "$before" ]
  rm -r "$REPO/scratch"
  run val run --cmd "true" --runner validator --independent
  [ "$status" -eq 0 ]
  [[ "$output" == "PASS exit=0 key=v2|"* ]]
  [ "$(fp)" = "$before" ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

@test "an independent passing receipt is reused without re-running; a source change needs a fresh run" {
  val run --cmd "grep -q one a.txt" --runner validator --independent >/dev/null
  run val check --cmd "grep -q one a.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "reuse "*"runner=validator"* ]]
  receipt=$(printf '%s' "$output" | awk '{print $2}')
  jq -e '.schema == 1 and .result == "pass" and .exit == 0 and .verification == "independent"
         and .fingerprint_before == .fingerprint_after and (.log | length > 0)' "$receipt"
  echo two >"$REPO/a.txt"
  run val check --cmd "grep -q one a.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == "fresh-needed: no receipt"* ]]
}

@test "the declared environment is part of the receipt key" {
  NODE_ENV=development val run --cmd 'test "$NODE_ENV" = development' --env NODE_ENV --runner v --independent >/dev/null
  NODE_ENV=development run val check --cmd 'test "$NODE_ENV" = development' --env NODE_ENV
  [ "$status" -eq 0 ]
  NODE_ENV=production run val check --cmd 'test "$NODE_ENV" = development' --env NODE_ENV
  [ "$status" -eq 1 ]
  NODE_ENV=production run val run --cmd 'test "$NODE_ENV" = development' --env NODE_ENV --runner v --independent
  [ "$status" -eq 1 ]
  [[ "$output" == FAIL* ]]
}

@test "failures carry a bounded excerpt and are never reused" {
  run val run --cmd 'for i in $(seq 1 5000); do echo "case $i failed: boom"; done; exit 3' --runner v --independent
  [ "$status" -eq 1 ]
  [[ "$output" == "FAIL exit=3 "* ]]
  [[ "$output" == *"full log: "* ]]
  [ "${#output}" -lt 6000 ]
  run val check --cmd 'for i in $(seq 1 5000); do echo "case $i failed: boom"; done; exit 3'
  [ "$status" -eq 1 ]
  [[ "$output" == *"last result was fail (exit 3)"* ]]
}

@test "self-reported, partial, stale and tree-changing receipts need a fresh run" {
  val run --cmd "true" --runner codex >/dev/null
  run val check --cmd "true"
  [ "$status" -eq 1 ]
  [[ "$output" == *"self-reported"* ]]
  ORCHESTRATE_NOW=1000 val run --cmd "true" --runner v --independent >/dev/null
  ORCHESTRATE_NOW=1100 run val check --cmd "true" --max-age 60
  [[ "$output" == *"100s old"* ]]
  ORCHESTRATE_NOW=1050 run val check --cmd "true" --max-age 60
  [ "$status" -eq 0 ]
  receipt=$(printf '%s' "$output" | awk '{print $2}')
  jq 'del(.finished_epoch)' "$receipt" >"$receipt.tmp" && mv "$receipt.tmp" "$receipt"
  run val check --cmd "true"
  [[ "$output" == *"partial receipt"* ]]
  echo '{"schema":' >"$receipt"
  run val check --cmd "true"
  [[ "$output" == *"unreadable receipt"* ]]
  run val run --cmd "echo new >new.txt" --runner v --independent
  [ "$status" -eq 3 ]
  [[ "$output" == VOID* ]]
}

@test "validate.sh refuses a receipt store inside the checkout" {
  run "$SCRIPTS/validate.sh" run --dir "$REPO" --cmd true --runner v --store "$REPO/scratch"
  [ "$status" -eq 2 ]
  [[ "$output" == *"inside the checkout"* ]]
  [ ! -e "$REPO/scratch" ]
}
