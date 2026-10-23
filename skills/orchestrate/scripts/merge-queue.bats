#!/usr/bin/env bats
# Self-test for merge-queue.sh: real git against a local bare origin, stubbed gh.
# Run: bats scripts/merge-queue.bats

setup() {
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 # hermetic: ignore user signing/hooks config
  unset MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE
  git init -q --bare -b main "$BATS_TEST_TMPDIR/origin.git"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/seed" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/seed" config user.email t@example.com
  git -C "$BATS_TEST_TMPDIR/seed" config user.name t
  git -C "$BATS_TEST_TMPDIR/seed" config commit.gpgsign false
  echo base >"$BATS_TEST_TMPDIR/seed/f.txt"
  git -C "$BATS_TEST_TMPDIR/seed" add f.txt
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm init
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  "pr list"*--head*) rm -f "$FX/merged"; echo "$*" | sed 's/.*--head \([^ ]*\).*/\1/' >>"$FX/order"; echo '[{"number":5,"headRefOid":"abcdef0123456789"}]' ;;
  "pr list"*) echo '[{"number":5}]' ;;
  "pr merge"*) echo MERGED >"$FX/merged" ;;
  "pr view"*) if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}';
    else echo '{"state":"OPEN","isDraft":false,"isCrossRepository":false,"headRefOid":"abcdef0123456789","author":{"login":"me"},"mergeable":"MERGEABLE"}'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo body >"$BATS_TEST_TMPDIR/body.md"
}

# wt NAME [FILE CONTENT]: a worktree-clone on branch NAME with one commit editing FILE.
wt() {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/$1" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/$1" config user.email t@example.com
  git -C "$BATS_TEST_TMPDIR/$1" config user.name t
  git -C "$BATS_TEST_TMPDIR/$1" config commit.gpgsign false
  git -C "$BATS_TEST_TMPDIR/$1" switch -q -c "$1"
  echo "${3:-$1}" >"$BATS_TEST_TMPDIR/$1/${2:-$1.txt}"
  git -C "$BATS_TEST_TMPDIR/$1" add -A
  git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$1"
}

mq() { "$SCRIPTS/merge-queue.sh" "$@" --repo o/r; }
mqr() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }
enqueue() { # id [requires]
  mq add --id "$1" --worktree "$BATS_TEST_TMPDIR/$1" --branch "$1" --title "t $1" \
    --body-file "$BATS_TEST_TMPDIR/body.md" --requires "${2:--}"
}
outcome() { cat "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/$1.outcome"; }

@test "add rejects a duplicate id and leaves one row" {
  wt a
  enqueue a
  run enqueue a
  [ "$status" -eq 3 ]
  [[ "$output" == *"already queued"* ]]
  [ "$(wc -l <"$ORCHESTRATE_STATE_DIR/o__r/merge-queue/queue.tsv" | tr -d ' ')" = 1 ]
}

@test "run-once merges a clean item through pr-merge and records outcome merged" {
  wt a
  enqueue a
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = merged ]
  grep -q 'pr merge 5 --repo o/r --squash --match-head-commit abcdef0123456789$' "$FX/calls"
  git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/a
}

@test "a conflict records outcome conflict, is not done, and blocks its dependent" {
  wt a f.txt left
  git -C "$BATS_TEST_TMPDIR/seed" switch -q main 2>/dev/null || true
  echo right >"$BATS_TEST_TMPDIR/seed/f.txt"
  git -C "$BATS_TEST_TMPDIR/seed" commit -qam right
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
  wt b
  enqueue a
  enqueue b a
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome a)" = conflict ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/b.outcome" ]
  [[ "$output" == *"b: blocked on a"* ]]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/a" status --porcelain)" ]
  ! grep -q 'pr merge' "$FX/calls"
  run mqr status
  [[ "$output" == *$'a\tconflict\ta'* ]]
  [[ "$output" == *$'b\tblocked:a\tb'* ]]
  # a second pass does not silently skip or re-run the parked item
  run mqr run-once
  [ "$(outcome a)" = conflict ]
}

@test "a failing check records checkfail and nothing is pushed" {
  wt a
  enqueue a
  MERGE_QUEUE_CHECK_CMD='exit 1' run mqr run-once
  [ "$(outcome a)" = checkfail ]
  ! git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/a
}

@test "retry re-arms a non-merged item, which then merges and releases its dependent" {
  wt a
  wt b
  enqueue a
  enqueue b a
  MERGE_QUEUE_CHECK_CMD='exit 1' run mqr run-once
  [ "$(outcome a)" = checkfail ]
  run mqr retry a
  [ "$status" -eq 0 ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/a.outcome" ]
  run mqr run-once
  [ "$(outcome a)" = merged ]
  [ "$(outcome b)" = merged ]
  run mqr retry a
  [ "$status" -eq 3 ]
}

@test "items run in file order and a dependent waits for its requirement" {
  wt a
  wt b
  wt c
  enqueue c
  enqueue b c
  enqueue a b
  run mqr run-once
  [ "$status" -eq 0 ]
  [ "$(outcome c)" = merged ]
  [ "$(outcome b)" = merged ]
  [ "$(outcome a)" = merged ]
  # the first PR lookup per item marks the order it was processed in
  [ "$(awk '!seen[$0]++' "$FX/order" | tr '\n' ' ')" = "c b a " ]
}

@test "a dependency queued after its dependent merges first and releases the dependent next pass" {
  wt a
  wt b
  enqueue a b
  enqueue b
  run mqr run-once
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/a.outcome" ]
  [ "$(outcome b)" = merged ]
  run mqr run-once
  [ "$(outcome a)" = merged ]
}

@test "parent of name-2 is the bare name, not name-1" {
  [ "$("$SCRIPTS/merge-queue.sh" parent feat-2)" = feat ]
  [ "$("$SCRIPTS/merge-queue.sh" parent feat-3)" = feat-2 ]
  [ "$("$SCRIPTS/merge-queue.sh" parent feat-10)" = feat-9 ]
  [ -z "$("$SCRIPTS/merge-queue.sh" parent feat)" ]
  [ -z "$("$SCRIPTS/merge-queue.sh" parent feat-1)" ]
}

@test "--requires auto resolves the queued parent branch and refuses when none is queued" {
  wt feat
  wt feat-2
  enqueue feat
  run mq add --id feat-2 --worktree "$BATS_TEST_TMPDIR/feat-2" --branch feat-2 --title t \
    --body-file "$BATS_TEST_TMPDIR/body.md" --requires auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires feat)"* ]]
  run mq add --id x --worktree w --branch other-3 --title t --body-file b --requires auto
  [ "$status" -eq 3 ]
}

@test "a red default branch stops the pass without writing an outcome" {
  wt a
  enqueue a
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"; echo "red abc" >"$ORCHESTRATE_STATE_DIR/o__r/MAIN_RED"
  run mqr run-once
  [ "$status" -eq 4 ]
  [ ! -f "$ORCHESTRATE_STATE_DIR/o__r/merge-queue/a.outcome" ]
}
