#!/usr/bin/env bats
# wt-cleanup.sh merged-lane proofs (#393): a squash- or rebase-merged lane whose HEAD is on no
# remote branch is proven merged (ancestor, cherry, tree, squash, pr) or likely merged (subject)
# instead of being kept as unpushed forever. Against a stubbed spectra and gh. Run: bats wt-cleanup.bats

setup() {
  # git prints worktree paths physically (macOS: /var/... is /private/var/...); spell them alike.
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin" FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BIN" "$FX"
  export FX PATH="$BIN:$PATH" ORCHESTRATE_BUILD_ROOT="$BATS_TEST_TMPDIR/build"
  stub_spectra
  : >"$BATS_TEST_TMPDIR/spectra-cwds"   # nobody works in any tree
  # gh: `api repos/R/commits/SHA/pulls` prints $FX/pulls-SHA (default []), `api repos/R/pulls/N`
  # prints $FX/pull-N (default {}), `pr list --head B` prints $FX/pr-B (default []).
  cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/gh-calls"
case "${1:-} ${2:-}" in
  "api "*/commits/*/pulls) s=${2%/pulls}; cat "$FX/pulls-${s##*/}" 2>/dev/null || echo '[]' ;;
  "api "*/pulls/*) cat "$FX/pull-${2##*/}" 2>/dev/null || echo '{}' ;;
  *) h=""; while (($#)); do [ "$1" = --head ] && h=$2; shift; done
     cat "$FX/pr-$h" 2>/dev/null || echo '[]' ;;
esac
STUB
  chmod +x "$BIN/gh"
  O="$BATS_TEST_TMPDIR/origin.git" M="$BATS_TEST_TMPDIR/main" U="$BATS_TEST_TMPDIR/up"
  git init -q --bare "$O"
  git clone -q "$O" "$M" 2>/dev/null
  printf 'a\n' >"$M/f"; git -C "$M" add f; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main
  git -C "$O" symbolic-ref HEAD refs/heads/main
  git clone -q "$O" "$U" 2>/dev/null   # another checkout: what merges on GitHub lands from here
  old=$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)
}

# lane NAME: a worktree on a new local branch NAME, never pushed.
lane() { git -C "$M" worktree add -q -b "$1" "$BATS_TEST_TMPDIR/$1" origin/main; }
# commit NAME FILE CONTENT SUBJECT [EPOCH]: a lane commit, at EPOCH when given.
commit() {
  local w="$BATS_TEST_TMPDIR/$1"
  printf '%s\n' "$3" >"$w/$2"; git -C "$w" add -A
  GIT_COMMITTER_DATE=${5:+"$5 +0000"} GIT_AUTHOR_DATE=${5:+"$5 +0000"} git -C "$w" commit -qm "$4"
}
# land FILE CONTENT SUBJECT [EPOCH]: a commit on main from the other checkout, pushed.
land() {
  git -C "$U" pull -q --rebase origin main
  printf '%s\n' "$2" >"$U/$1"; git -C "$U" add -A
  GIT_COMMITTER_DATE=${4:+"$4 +0000"} GIT_AUTHOR_DATE=${4:+"$4 +0000"} git -C "$U" commit -qm "$3"
  git -C "$U" push -q origin HEAD:main
}
# idle NAME: untouched for 3 days.
idle() { touch -t "$old" "$BATS_TEST_TMPDIR/$1" "$(git -C "$BATS_TEST_TMPDIR/$1" rev-parse --path-format=absolute --git-path index)"; }
sync() { git -C "$M" fetch -q origin; }
wtc() { "$SCRIPTS/wt-cleanup.sh" --repo-dir "$M" "$@"; }
verdict() { printf '%s\n' "$output" | awk -F'\t' -v p="$BATS_TEST_TMPDIR/$1" '$2 == p { print $1 "\t" $3 }'; }
has_merge_tree() { git merge-tree --write-tree HEAD HEAD >/dev/null 2>&1; }

@test "ancestor: a lane fast-forwarded into main counts as merged, even under --pr-closed with no PR" {
  lane ff; commit ff g ff "ff"; idle ff
  git -C "$BATS_TEST_TMPDIR/ff" push -q origin ff:main; sync
  run wtc --pr-closed --repo acme/widget
  [ "$status" -eq 0 ]
  [[ "$(verdict ff)" == $'remove\tclean, idle 72h, merged (ancestor): HEAD is an ancestor of origin/main (dry run'* ]]
  [ ! -e "$FX/gh-calls" ]   # proven locally: no PR read
}

@test "cherry: every lane commit rebased onto main is patch-equivalent" {
  lane rb; commit rb g one "one"; commit rb h two "two"; idle rb
  land other x "unrelated"
  git -C "$U" fetch -q "$M" rb; git -C "$U" cherry-pick FETCH_HEAD~1 FETCH_HEAD >/dev/null
  git -C "$U" push -q origin HEAD:main; sync
  run wtc --apply
  [ "$status" -eq 0 ]
  [[ "$(verdict rb)" == $'removed\tclean, idle 72h, merged (cherry): all 2 commits are patch-equivalent to commits on origin/main' ]]
  [ ! -d "$BATS_TEST_TMPDIR/rb" ]
  git -C "$M" rev-parse -q --verify refs/heads/rb   # the branch stays; only the tree goes
}

@test "tree: a squash that also holds later review fixes still merges to nothing (git 2.38+)" {
  lane sq; commit sq f b "first"; commit sq g c "second"; idle sq
  # Squashed from a later head: the lane's two changes plus a fix the lane never saw.
  git -C "$U" pull -q --rebase origin main
  printf 'b\n' >"$U/f"; printf 'c\n' >"$U/g"; printf 'fix\n' >"$U/review"; git -C "$U" add -A
  git -C "$U" commit -qm "Lane (#12)"; git -C "$U" push -q origin HEAD:main; sync
  run wtc
  if has_merge_tree; then
    [[ "$(verdict sq)" == $'remove\tclean, idle 72h, merged (tree): merging HEAD into origin/main changes nothing'* ]]
  else
    # Older git has no merge-tree --write-tree: the proof is skipped, never guessed.
    [[ "$(verdict sq)" == $'keep\tHEAD is not on any remote branch (unpushed work): not merged into origin/main'* ]]
  fi
}

@test "squash: the lane's whole diff is one commit on main, though main changed those lines since" {
  lane sq; commit sq f b "first"; commit sq g c "second"; idle sq
  git -C "$U" pull -q --rebase origin main
  printf 'b\n' >"$U/f"; printf 'c\n' >"$U/g"; git -C "$U" add -A; git -C "$U" commit -qm "Lane (#13)"
  land f later "later edit"; sync   # a merge of the lane into main now conflicts on f
  run wtc
  [[ "$(verdict sq)" == $'remove\tclean, idle 72h, merged (squash): the lane\'s whole diff is patch-equivalent to a commit on origin/main'* ]]
}

@test "pr: a merged PR whose head is HEAD proves it when nothing local can, and only with a repo" {
  lane pr; commit pr f b "change f"; idle pr
  land f B "Change f, edited while merging (#20)"; sync
  head=$(git -C "$BATS_TEST_TMPDIR/pr" rev-parse HEAD)
  run wtc
  [[ "$(verdict pr)" == $'keep\tHEAD is not on any remote branch (unpushed work): not merged into origin/main (ancestor, cherry, tree, squash; pass --repo or --pr-closed for the PR proofs)' ]]
  [ ! -e "$FX/gh-calls" ]
  printf '[{"number":20,"merged_at":"2026-11-20T00:00:00Z","head":{"sha":"%s"}},{"number":19,"merged_at":null,"head":{"sha":"%s"}}]\n' "$head" "$head" >"$FX/pulls-$head"
  run wtc --pr-closed --repo acme/widget --apply
  [[ "$(verdict pr)" == $'removed\tclean, idle 72h, merged (pr): PR #20 merged with HEAD as its head' ]]
  grep -q "api repos/acme/widget/commits/$head/pulls" "$FX/gh-calls"
  # An open or unmerged PR at HEAD proves nothing.
  lane pr2; commit pr2 f c "change f again"; idle pr2
  head=$(git -C "$BATS_TEST_TMPDIR/pr2" rev-parse HEAD)
  printf '[{"number":21,"merged_at":null,"head":{"sha":"%s"}}]\n' "$head" >"$FX/pulls-$head"
  run wtc --repo acme/widget
  [[ "$(verdict pr2)" == $'keep\tHEAD is not on any remote branch (unpushed work): not merged into origin/main (ancestor, cherry, tree, squash, pr, subject)' ]]
}

@test "subject: a lane subject squashed as '<subject> (#N)' is likely merged, removed only with --include-likely" {
  lane ls; commit ls f b "Add the widget" 1700000000; idle ls
  land f B "Add the widget (#30)" 1700001000; sync
  echo '{"number":30,"merged_at":"2026-11-20T00:00:00Z"}' >"$FX/pull-30"
  run wtc --repo acme/widget --apply
  [[ "$(verdict ls)" == $'keep\tlikely merged (subject): "Add the widget" landed on origin/main as '*' (#30, merged), after every lane commit (--include-likely removes it)' ]]
  [ -d "$BATS_TEST_TMPDIR/ls" ]
  run wtc --include-likely --repo acme/widget --apply
  [[ "$(verdict ls)" == $'removed\tclean, idle 72h, likely merged (subject): "Add the widget"'* ]]
  [ ! -d "$BATS_TEST_TMPDIR/ls" ]
}

@test "negative: one commit squash-merged, a later one not, is kept as unpushed" {
  lane ng; commit ng f b "Part one" 1700000000
  land f b "Part one (#40)" 1700001000
  commit ng g c "Part two" 1700002000; idle ng; sync
  echo '{"number":40,"merged_at":"2026-11-20T00:00:00Z"}' >"$FX/pull-40"
  run wtc --pr-closed --include-likely --repo acme/widget --apply
  [ "$status" -eq 0 ]
  [[ "$(verdict ng)" == $'keep\tHEAD is not on any remote branch (unpushed work): not merged into origin/main (ancestor, cherry, tree, squash, pr, subject)' ]]
  [ -d "$BATS_TEST_TMPDIR/ng" ]
  # The same subject on an unmerged PR proves nothing either.
  lane ng2; commit ng2 h d "Part three" 1700000000; idle ng2
  land h D "Part three (#41)" 1700001000; sync
  echo '{"number":41,"merged_at":null}' >"$FX/pull-41"
  run wtc --include-likely --repo acme/widget --apply
  [[ "$(verdict ng2)" == $'keep\tHEAD is not on any remote branch (unpushed work)'* ]]
}

@test "merge proofs keep every other guard: dirty, busy, recent and locked merged lanes stay" {
  for n in dirty busy recent locked; do lane "$n"; commit "$n" "$n" x "$n"; git -C "$BATS_TEST_TMPDIR/$n" push -q origin "$n:main"; done
  sync
  for n in dirty busy locked; do idle "$n"; done
  echo junk >"$BATS_TEST_TMPDIR/dirty/new"
  printf '9\t%s\n' "$BATS_TEST_TMPDIR/busy" >"$BATS_TEST_TMPDIR/spectra-cwds"
  git -C "$M" worktree lock "$BATS_TEST_TMPDIR/locked"
  run wtc --apply
  [[ "$(verdict dirty)" == $'keep\tuncommitted'* ]]
  [[ "$(verdict busy)" == $'keep\ta process is working inside it' ]]
  [[ "$(verdict recent)" == $'keep\ttouched 0h ago'* ]]
  [[ "$(verdict locked)" == $'keep\tlocked' ]]
  for n in dirty busy recent locked; do [ -d "$BATS_TEST_TMPDIR/$n" ]; done
}

@test "--default-branch picks the branch to prove against; without its remote ref nothing is proven" {
  lane dv; commit dv g x "dev work"; idle dv
  git -C "$BATS_TEST_TMPDIR/dv" push -q origin dv:develop; sync
  run wtc --default-branch develop
  [[ "$(verdict dv)" == $'remove\tclean, idle 72h, merged (ancestor): HEAD is an ancestor of origin/develop'* ]]
  lane local; commit local h y "local work"; idle local
  run wtc --default-branch nope
  [[ "$(verdict local)" == $'keep\tHEAD is not on any remote branch (unpushed work): no origin/nope to prove a merge against' ]]
  [[ "$(verdict dv)" == $'remove\tclean, idle 72h, pushed'* ]]
}

@test "the -h header names every proof and --include-likely" {
  run "$SCRIPTS/wt-cleanup.sh" -h
  for w in ancestor cherry tree squash pr subject --include-likely --default-branch; do [[ "$output" == *"$w"* ]]; done
}
