#!/usr/bin/env bats
# Self-test for merge-sensitive.sh and its use by pr-merge.sh and merge-queue.sh: stubbed gh, real
# git for the merge-result check.
# Run: bats scripts/merge-sensitive.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_DIRECT_MERGE ORCHESTRATE_SENSITIVE_LOCK_TTL
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  echo "$HEAD" >"$FX/head"
  echo 0 >"$FX/behind"
  printf 'src/app.ts\n' >"$FX/files"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
case "$all" in
  "api --paginate repos/o/r/pulls/5/files"*) [ ! -f "$FX/files-fail" ] || { echo "HTTP 404" >&2; exit 1; }; cat "$FX/files" ;;
  "api repos/o/r/pulls/5 "*) echo main ;;
  "api repos/o/r/compare/main..."*) cat "$FX/behind" ;;
  "pr view"*) if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}';
    else jq -n --arg h "$(cat "$FX/head")" '{state: "OPEN", isDraft: false, isCrossRepository: false,
      headRefOid: $h, author: {login: "me"}, mergeable: "MERGEABLE", autoMergeRequest: null}'; fi ;;
  "pr merge"*) echo MERGED >"$FX/merged" ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

ms() { "$SCRIPTS/merge-sensitive.sh" "$1" --repo o/r --pr 5 "${@:2}"; }
# pr-merge.sh in direct mode with evidence: only the identity, head and sensitive-path gates run.
merge() { ORCHESTRATE_DIRECT_MERGE=1 "$SCRIPTS/pr-merge.sh" --repo o/r --pr 5 --head "${HEAD:0:9}" --evidence test "$@"; }

@test "no patterns configured: clear, and GitHub is not read" {
  run ms check --head "$HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == "clear: no merge-sensitive paths configured" ]]
  [ ! -f "$FX/calls" ]
  run ms paths
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "paths: globs, directory prefixes and renamed-from names match; comments ignored" {
  mkdir -p "$STATE"
  printf '# catalogs\ngradle/libs.versions.toml\n\nweb/budget*.test.ts  # size\ncontracts/\nnever/*\n' >"$STATE/merge-sensitive"
  printf 'src/a.ts\nweb/budget.size.test.ts\ncontracts/v1/api.json\nold/libs.toml\ngradle/libs.versions.toml\n' >"$FX/files"
  run ms paths
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'gradle/libs.versions.toml\nweb/budget*.test.ts\ncontracts/')" ]
}

@test "paths: patterns also come from ORCHESTRATE_MERGE_SENSITIVE, comma-separated" {
  export ORCHESTRATE_MERGE_SENSITIVE="docs/,src/*.ts"
  run ms paths
  [ "$status" -eq 0 ] && [ "$output" = "src/*.ts" ]
}

@test "check: a PR that touches no sensitive path is clear without comparing" {
  export ORCHESTRATE_MERGE_SENSITIVE="gradle/libs.versions.toml"
  run ms check --head "$HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == "clear: PR 5 touches no merge-sensitive path" ]]
  ! grep -q compare "$FX/calls"
}

@test "check: touching a sensitive path with the base contained is clear; behind is stale" {
  export ORCHESTRATE_MERGE_SENSITIVE="src/"
  run ms check --head "$HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == "clear: PR 5 touches src/ and its head contains main" ]]
  echo 2 >"$FX/behind"
  run ms check --head "$HEAD"
  [ "$status" -eq 3 ]
  [[ "$output" == "stale: PR 5 touches merge-sensitive src/ and is 2 commit(s) behind main; merge main in"* ]]
}

@test "check: an unreadable file list is unverified, never clear" {
  export ORCHESTRATE_MERGE_SENSITIVE="src/"
  touch "$FX/files-fail"
  run ms check --head "$HEAD"
  [ "$status" -eq 9 ]
  [[ "$output" == unverified:* ]]
}

# A local origin where main and the PR branch each add a key to the same catalog, in different
# places: git merges them cleanly; the check command decides.
catalog_repos() {
  git init -q --bare -b main "$BATS_TEST_TMPDIR/origin.git"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/seed" 2>/dev/null
  printf '[versions]\na = "1"\nb = "1"\nc = "1"\nd = "1"\n' >"$BATS_TEST_TMPDIR/seed/libs.toml"
  git -C "$BATS_TEST_TMPDIR/seed" add libs.toml
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm init
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
  git -C "$BATS_TEST_TMPDIR/seed" switch -q -c pr
  sed -i.bak 's/^a = "1"/a = "1"\nx = "2"/' "$BATS_TEST_TMPDIR/seed/libs.toml"
  git -C "$BATS_TEST_TMPDIR/seed" commit -qam "pr adds x"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin pr
  git -C "$BATS_TEST_TMPDIR/seed" rev-parse HEAD >"$FX/head"
  git -C "$BATS_TEST_TMPDIR/seed" switch -q main
  sed -i.bak "s/^d = \"1\"/d = \"1\"\n${1:-y} = \"3\"/" "$BATS_TEST_TMPDIR/seed/libs.toml"
  git -C "$BATS_TEST_TMPDIR/seed" commit -qam "main adds a key"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin main
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/checkout" 2>/dev/null
  HEAD=$(cat "$FX/head")
  echo 1 >"$FX/behind"
  printf 'libs.toml\n' >"$FX/files"
  export ORCHESTRATE_MERGE_SENSITIVE="libs.toml"
}
# Fails when a key is declared twice, as Gradle does for a duplicate TOML key.
DUPCHECK='! sed -n "s/ =.*//p" libs.toml | sort | uniq -d | grep .'

@test "merge-result check: a clean merge that passes the check is clear" {
  catalog_repos y
  run ms check --head "$HEAD" --worktree "$BATS_TEST_TMPDIR/checkout" --check-cmd "$DUPCHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"but the merge-result check passed"* ]]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/checkout" worktree list | awk 'NR > 1')" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/checkout" status --porcelain)" = "" ]
}

@test "merge-result check: a clean merge with a duplicate key is stale" {
  catalog_repos x
  run ms check --head "$HEAD" --worktree "$BATS_TEST_TMPDIR/checkout" --check-cmd "$DUPCHECK"
  [ "$status" -eq 3 ]
  [[ "$output" == *"and the merge-result check failed"* ]]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/checkout" worktree list | awk 'NR > 1')" ]
}

@test "merge-result check: --worktree without --check-cmd is a usage error" {
  run ms check --head "$HEAD" --worktree "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
}

@test "pr-merge: no patterns, the merge goes ahead and nothing extra is read" {
  run merge
  [ "$status" -eq 0 ]
  [[ "$output" == "merged 5 feedface" ]]
  ! grep -q "pulls/5/files" "$FX/calls"
}

@test "pr-merge: stale on a sensitive path refuses with exit 11, merges nothing, frees the lock" {
  export ORCHESTRATE_MERGE_SENSITIVE="src/"
  echo 3 >"$FX/behind"
  run merge
  [ "$status" -eq 11 ]
  [[ "$output" == stale:* ]]
  run ! grep -q "pr merge" "$FX/calls"
  [ -z "$(ls "$STATE/locks")" ]
  grep -q "refused stale: PR 5 touches merge-sensitive src/" "$STATE/merges.log"
}

@test "pr-merge: up to date on a sensitive path merges and frees the lock" {
  export ORCHESTRATE_MERGE_SENSITIVE="src/"
  run merge
  [ "$status" -eq 0 ]
  grep -q "pr merge" "$FX/calls"
  [ -z "$(ls "$STATE/locks")" ]
  grep -q "sensitive clear: PR 5 touches src/" "$STATE/merges.log"
}

@test "pr-merge: another PR holding the path lock is busy (exit 12); an expired lock is taken over" {
  export ORCHESTRATE_MERGE_SENSITIVE="src/"
  d="$STATE/locks/sensitive-$(printf '%s' 'src/' | cksum | cut -d' ' -f1)"
  mkdir -p "$d"; echo 7 >"$d/pr"; echo $((ORCHESTRATE_NOW - 60)) >"$d/at"
  run merge
  [ "$status" -eq 12 ]
  [[ "$output" == "busy: PR 7 is merging over merge-sensitive path src/"* ]]
  run ! grep -q "pr merge" "$FX/calls"
  [ "$(cat "$d/pr")" = 7 ]
  echo $((ORCHESTRATE_NOW - 901)) >"$d/at"
  run merge
  [ "$status" -eq 0 ]
  [ ! -d "$d" ]
}

@test "pr-merge: the merge-result check lets a behind PR merge without a refresh" {
  catalog_repos y
  run merge --worktree "$BATS_TEST_TMPDIR/checkout" --merge-check "$DUPCHECK"
  [ "$status" -eq 0 ]
  grep -q "pr merge" "$FX/calls"
  rm -f "$FX/merged"; : >"$FX/calls"
  run merge
  [ "$status" -eq 11 ]
}

@test "merge-queue: a stale refusal leaves the item waiting; the next pass merges main in and pushes again" {
  # The real merge-queue.sh beside a pr-merge.sh that answers with the exit code in $FX/pm-rc.
  S="$BATS_TEST_TMPDIR/s"; mkdir -p "$S"
  cp "$SCRIPTS/merge-queue.sh" "$SCRIPTS/_lib.sh" "$SCRIPTS/gh-read.sh" "$SCRIPTS/regen-merge.sh" "$SCRIPTS/hold.sh" "$SCRIPTS/review-ledger.sh" "$S/"
  printf '#!/usr/bin/env bash\necho "$*" >>"$FX/pm-calls"\nexit "$(cat "$FX/pm-rc")"\n' >"$S/pr-merge.sh"
  chmod +x "$S/pr-merge.sh"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  "pr list"*"--state open"*) jq -n --arg h "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/pr)" '[{number: 5, headRefOid: $h}]' ;;
  "pr view"*) echo '{"state":"OPEN"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  catalog_repos y
  git -C "$BATS_TEST_TMPDIR/checkout" switch -q pr
  export ORCHESTRATE_DIRECT_MERGE=1
  echo body >"$BATS_TEST_TMPDIR/body.md"
  "$S/merge-queue.sh" add --repo o/r --id q1 --worktree "$BATS_TEST_TMPDIR/checkout" --branch pr \
    --title t --body-file "$BATS_TEST_TMPDIR/body.md"
  echo 11 >"$FX/pm-rc"
  run "$S/merge-queue.sh" run-once --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"q1: waiting (base moved past a merge-sensitive path"* ]]
  first=$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/pr)
  # main moves again; the next pass must not resume at the stale head.
  git -C "$BATS_TEST_TMPDIR/seed" switch -q main
  echo more >"$BATS_TEST_TMPDIR/seed/other.txt"
  git -C "$BATS_TEST_TMPDIR/seed" add other.txt
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm "main moves"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin main
  echo 0 >"$FX/pm-rc"
  run "$S/merge-queue.sh" run-once --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"q1: merged"* ]]
  second=$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse refs/heads/pr)
  [ "$first" != "$second" ]
  git -C "$BATS_TEST_TMPDIR/origin.git" merge-base --is-ancestor refs/heads/main refs/heads/pr
  [ "$(wc -l <"$FX/pm-calls")" -eq 2 ]
}

@test "merge-queue: a busy refusal leaves the item waiting" {
  grep -q '12) set_outcome "$qid" waiting "another merge holds a merge-sensitive path lock"' "$SCRIPTS/merge-queue.sh"
}

@test "headers: -h prints exactly the header comment" {
  for s in merge-sensitive.sh pr-merge.sh merge-queue.sh; do
    [ "$("$SCRIPTS/$s" -h)" = "$(awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$SCRIPTS/$s")" ]
  done
}
