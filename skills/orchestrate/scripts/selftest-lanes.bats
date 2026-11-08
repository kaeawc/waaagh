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
  [ "$(printf '%s\n' "$output" | head -7 | tr '\n' '|')" = "2-b|3:error one|4-c|--|8-g|9:fatal two|10-h|" ]
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
