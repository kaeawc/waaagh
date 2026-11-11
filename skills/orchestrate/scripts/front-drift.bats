#!/usr/bin/env bats
# The serial front is re-validated only on protected-area drift (#204): merge-sensitive.sh drift
# and the drift scope of `check`, and merge-queue.sh resuming a waiting item whose base moved only
# outside the protected paths instead of merging it in, re-running the check and pushing (which
# restarts its CI on every merge to main). Real git against a local bare origin, stubbed gh.
# Run: bats scripts/front-drift.bats

setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_MERGE_MANIFESTS ORCHESTRATE_DIRECT_MERGE MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_UPDATE_BEHIND
  seed_origin_copy
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin" "$STATE"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  echo 2 >"$FX/behind"
  printf 'src/app.ts\n' >"$FX/files"
  printf 'docs/readme.md\n' >"$FX/drift"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  "api --paginate repos/o/r/pulls/5/files"*) cat "$FX/files" ;;
  "api repos/o/r/pulls/5 "*) echo main ;;
  "api repos/o/r/compare/main..."*) cat "$FX/behind" ;;
  "api repos/o/r/compare/"*"...main "*) [ ! -f "$FX/drift-fail" ] || { echo "HTTP 502" >&2; exit 1; }; cat "$FX/drift" ;;
  "pr list"*"--state open"*) jq -n --arg h "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/q)" '[{number: 5, headRefOid: $h}]' ;;
  "pr view"*) echo '{"state":"OPEN"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  # A front clone on branch q, one commit ahead of main.
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/q" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/q" switch -q -c q
  echo q >"$BATS_TEST_TMPDIR/q/q.txt"
  git -C "$BATS_TEST_TMPDIR/q" add -A
  git -C "$BATS_TEST_TMPDIR/q" commit -qm q
}

ms() { "$SCRIPTS/merge-sensitive.sh" "$@" --repo o/r; }
drift() { git -C "$BATS_TEST_TMPDIR/q" fetch -q origin; ms drift --worktree "$BATS_TEST_TMPDIR/q" --base main; }
main_moves() { # FILE: a new commit on origin/main that edits FILE
  mkdir -p "$(dirname "$BATS_TEST_TMPDIR/seed/$1")"
  echo "$RANDOM" >>"$BATS_TEST_TMPDIR/seed/$1"
  git -C "$BATS_TEST_TMPDIR/seed" add -A
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm "main $1"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
}

@test "drift: unrelated base commits print nothing; a sensitive pattern or a default manifest is listed" {
  export ORCHESTRATE_MERGE_SENSITIVE="gradle/libs.versions.toml,contracts/"
  run drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  main_moves docs/a.md
  run drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  main_moves contracts/v1.json
  main_moves web/package.json
  main_moves api/user.schema.json
  run drift
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'contracts/\n*/package.json\n*.schema.json')" ]
  [ ! -f "$FX/calls" ]   # read locally, never from GitHub
}

@test "drift: the base's commits the front already contains do not count" {
  main_moves package.json
  git -C "$BATS_TEST_TMPDIR/q" fetch -q origin
  git -C "$BATS_TEST_TMPDIR/q" -c commit.gpgsign=false merge -q --no-edit origin/main
  main_moves docs/a.md
  run drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "drift: configured manifests replace the default list; an empty list means none" {
  main_moves package.json
  main_moves deps/versions.txt
  export ORCHESTRATE_MERGE_MANIFESTS="deps/"
  run drift
  [ "$output" = "deps/" ]
  export ORCHESTRATE_MERGE_MANIFESTS=""
  run drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unset ORCHESTRATE_MERGE_MANIFESTS
  printf '# ours\npackage.json\n' >"$STATE/merge-manifests"
  run drift
  [ "$output" = "package.json" ]
}

@test "drift: a checkout without the base is unverified (exit 9); bad arguments are usage errors" {
  run ms drift --worktree "$BATS_TEST_TMPDIR/q" --base nosuch
  [ "$status" -eq 9 ]
  [[ "$output" == unverified:* ]]
  run ms drift --worktree "$BATS_TEST_TMPDIR/q"
  [ "$status" -eq 2 ]
  run ms drift --worktree "$BATS_TEST_TMPDIR/q" --base main --pr 5
  [ "$status" -eq 2 ]
  run ms check --pr 5 --head "$HEAD" --base main
  [ "$status" -eq 2 ]
}

@test "check: a sensitive PR behind only unrelated drift is clear; drift on a protected path is stale" {
  export ORCHESTRATE_MERGE_SENSITIVE="src/"
  run ms check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "clear: PR 5 touches src/ and is 2 commit(s) behind main, which touch no protected path" ]
  printf 'docs/x.md\nyarn.lock\n' >"$FX/drift"
  run ms check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [[ "$output" == "stale: PR 5 touches merge-sensitive src/ and is 2 commit(s) behind main, which touch yarn.lock; merge main in"* ]]
  printf 'src/other.ts\n' >"$FX/drift"
  run ms check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [[ "$output" == *"which touch src/;"* ]]
}

@test "check: a cut-short drift list is stale; an unreadable one is unverified, never clear" {
  export ORCHESTRATE_MERGE_SENSITIVE="src/"
  echo '*' >"$FX/drift"
  run ms check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [[ "$output" == *"which touch 300+ files;"* ]]
  touch "$FX/drift-fail"
  run ms check --pr 5 --head "$HEAD"
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: could not read the files main changed since abcdef123" ]
}

# The real merge-queue.sh beside a pr-merge.sh stub answering with the exit code in $FX/pm-rc.
queue_front() {
  S="$BATS_TEST_TMPDIR/s"; mkdir -p "$S"
  cp "$SCRIPTS/merge-queue.sh" "$SCRIPTS/_lib.sh" "$SCRIPTS/gh-read.sh" "$SCRIPTS/regen-merge.sh" "$SCRIPTS/hold.sh" \
    "$SCRIPTS/review-ledger.sh" "$SCRIPTS/merge-sensitive.sh" "$S/"
  printf '#!/usr/bin/env bash\necho "$*" >>"$FX/pm-calls"\nexit "$(cat "$FX/pm-rc")"\n' >"$S/pr-merge.sh"
  chmod +x "$S/pr-merge.sh"
  export ORCHESTRATE_DIRECT_MERGE=1 MERGE_QUEUE_CHECK_CMD='echo ran >>"$FX/check-runs"'
  echo body >"$BATS_TEST_TMPDIR/body.md"
  "$S/merge-queue.sh" add --repo o/r --id q --worktree "$BATS_TEST_TMPDIR/q" --branch q --title t \
    --body-file "$BATS_TEST_TMPDIR/body.md"
  echo 7 >"$FX/pm-rc"   # not ready yet: waiting
  run "$S/merge-queue.sh" run-once --repo o/r
  [[ "$output" == *"q: waiting"* ]]
  pushed=$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/q)
}
pushed_now() { git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/q; }

@test "merge-queue: unrelated drift resumes the waiting front without a base merge, check or push" {
  queue_front
  main_moves docs/a.md
  echo 0 >"$FX/pm-rc"
  run "$S/merge-queue.sh" run-once --repo o/r
  [[ "$output" == *"q: merged"* ]]
  [ "$(pushed_now)" = "$pushed" ]
  [ "$(grep -c ran "$FX/check-runs")" -eq 1 ]
  grep -q "resuming at ${pushed:0:9}: main moved, but over no protected path" "$STATE/merge-queue/logs/q.log"
}

@test "merge-queue: drift over a shared manifest merges the base in, re-runs the check and pushes" {
  queue_front
  main_moves docs/a.md
  run "$S/merge-queue.sh" run-once --repo o/r
  [ "$(pushed_now)" = "$pushed" ]
  main_moves package-lock.json
  echo 0 >"$FX/pm-rc"
  run "$S/merge-queue.sh" run-once --repo o/r
  [[ "$output" == *"q: merged"* ]]
  [ "$(pushed_now)" != "$pushed" ]
  git -C "$BATS_TEST_TMPDIR/origin.git" merge-base --is-ancestor refs/heads/main refs/heads/q
  [ "$(grep -c ran "$FX/check-runs")" -eq 2 ]
  grep -q "q: main moved over protected package-lock.json; merging it in" "$STATE/merge-queue/logs/q.log"
}

@test "merge-queue: MERGE_QUEUE_UPDATE_BEHIND=always, or an unverifiable drift, merges any drift in" {
  queue_front
  main_moves docs/a.md
  export MERGE_QUEUE_UPDATE_BEHIND=always
  run "$S/merge-queue.sh" run-once --repo o/r
  second=$(pushed_now)
  [ "$second" != "$pushed" ]
  unset MERGE_QUEUE_UPDATE_BEHIND
  rm "$S/merge-sensitive.sh"
  main_moves docs/b.md
  run "$S/merge-queue.sh" run-once --repo o/r
  [ "$(pushed_now)" != "$second" ]
  grep -q "q: main moved over protected paths (drift unverified); merging it in" "$STATE/merge-queue/logs/q.log"
}

@test "merge-queue: a stale refusal (exit 11) forces the next base merge once, then unrelated drift resumes" {
  queue_front
  echo 11 >"$FX/pm-rc"
  main_moves docs/a.md
  run "$S/merge-queue.sh" run-once --repo o/r   # resumes (unrelated), pr-merge says stale
  [ "$(pushed_now)" = "$pushed" ]
  [ -f "$STATE/merge-queue/q.refresh" ]
  main_moves docs/b.md
  echo 7 >"$FX/pm-rc"
  run "$S/merge-queue.sh" run-once --repo o/r
  second=$(pushed_now)
  [ "$second" != "$pushed" ]
  [ ! -f "$STATE/merge-queue/q.refresh" ]
  main_moves docs/c.md
  run "$S/merge-queue.sh" run-once --repo o/r
  [ "$(pushed_now)" = "$second" ]
}
