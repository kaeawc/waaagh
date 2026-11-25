#!/usr/bin/env bats
# wt-session-hint.sh, the SessionStart hook (#395): one line from a cached wt-cleanup.sh report,
# refreshed in a detached background process when missing or stale; never waits on gh or git
# fetch, never removes. The hook's mechanics run against a stub wt-cleanup.sh (ORCHESTRATE_SCRIPTS_DIR,
# #233), so no slow real refresh runs in the background (under bashcov one takes minutes); the
# real wt-cleanup.sh runs in the foreground --refresh case. Run: bats wt-session-hint.bats

setup() {
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR BIN="$BATS_TEST_TMPDIR/bin" FX="$BATS_TEST_TMPDIR/fx" STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$BIN" "$FX" "$STUBS"
  export FX PATH="$BIN:$PATH" ORCHESTRATE_BUILD_ROOT="$T/build" ORCHESTRATE_STATE_DIR="$T/state" ORCHESTRATE_SCRIPTS_DIR="$STUBS"
  unset ORCHESTRATE_WT_REPORT_TTL ORCHESTRATE_WT_REPORT_FETCH ORCHESTRATE_NOW
  stub_spectra
  : >"$T/spectra-cwds"
  # wt-cleanup.sh stub: logs its arguments, blocks while $FX/cleanup-hang exists, exits 2 for
  # --pr-closed when $FX/no-repo exists (as the real one does when it cannot tell the repository),
  # else prints $FX/rows.
  cat >"$STUBS/wt-cleanup.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/cleanup-calls"
while [ -e "$FX/cleanup-hang" ]; do sleep 0.2; done
case " $* " in *" --pr-closed "*) [ ! -e "$FX/no-repo" ] || exit 2 ;; esac
cat "$FX/rows" 2>/dev/null
STUB
  # gh, for the real wt-cleanup.sh: `repo view` names acme/widget unless $FX/no-repo exists; PR
  # reads from $FX/pulls-SHA, $FX/pull-N, $FX/pr-BRANCH (defaults [] and {}).
  cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/gh-calls"
case "${1:-} ${2:-}" in
  "repo view") [ ! -e "$FX/no-repo" ] || { echo "no repo" >&2; exit 1; }; echo '{"nameWithOwner":"acme/widget"}' ;;
  "api "*/commits/*/pulls) s=${2%/pulls}; cat "$FX/pulls-${s##*/}" 2>/dev/null || echo '[]' ;;
  "api "*/pulls/*) cat "$FX/pull-${2##*/}" 2>/dev/null || echo '{}' ;;
  *) h=""; while (($#)); do [ "$1" = --head ] && h=$2; shift; done
     cat "$FX/pr-$h" 2>/dev/null || echo '[]' ;;
esac
STUB
  # git: every fetch is logged, and blocks while $FX/fetch-hang exists.
  real_git=$(command -v git)
  cat >"$BIN/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = fetch ]; then echo "\$*" >>"\$FX/fetches"; while [ -e "\$FX/fetch-hang" ]; do sleep 0.2; done; break; fi
done
exec "$real_git" "\$@"
STUB
  chmod +x "$STUBS/wt-cleanup.sh" "$BIN/gh" "$BIN/git"
  O="$T/origin.git" M="$T/main" U="$T/up"
  git init -q --bare "$O"
  git clone -q "$O" "$M" 2>/dev/null
  printf 'a\n' >"$M/f"; git -C "$M" add f; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main
  git -C "$O" symbolic-ref HEAD refs/heads/main
  git -C "$M" worktree add -q -b l0 "$T/l0" origin/main   # one linked worktree: the hook has a repository to report on
  # What the stub reports: 2 merged, 1 likely merged, 1 only pushed, 1 unfinished.
  {
    printf 'remove\t%s\tclean, idle 72h, merged (cherry): all 2 commits are patch-equivalent to commits on origin/main (dry run: --apply removes it)\n' "$T/s1"
    printf 'remove\t%s\tclean, idle 72h, merged (ancestor): HEAD is an ancestor of origin/main (dry run: --apply removes it)\n' "$T/s2"
    printf 'keep\t%s\tlikely merged (subject): "Add the widget" landed on origin/main as abc (#3, merged), after every lane commit (--include-likely removes it)\n' "$T/lk"
    printf 'remove\t%s\tclean, idle 72h, pushed (dry run: --apply removes it)\n' "$T/pu"
    printf 'keep\t%s\tHEAD is not on any remote branch (unpushed work): not merged into origin/main\n' "$T/wip"
    printf 'keep\t%s\tmain worktree\n' "$M"
  } >"$FX/rows"
  old=$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)
}

# A refresh left running holds nothing of bats' (its stdio is /dev/null), but must not outlive the
# test: release every hang and wait for the refresh lock to go.
teardown() {
  rm -f "$FX/cleanup-hang" "$FX/fetch-hang"
  local _; for _ in $(seq 1 150); do no_lock && return 0; sleep 0.2; done
}

hook() { (cd "${1:-$M}" && "$SCRIPTS/wt-session-hint.sh"); }
report() { ls "$ORCHESTRATE_STATE_DIR"/wt-reports/*.tsv 2>/dev/null; }
# Polls every 0.2 s, up to 2 minutes: under bashcov every traced poll queues behind one reader.
await() { local _; for _ in $(seq 1 600); do eval "$1" && return 0; sleep 0.2; done; echo "timed out: $1"; return 1; }
no_lock() { ! ls "$ORCHESTRATE_STATE_DIR"/wt-reports/*.lock >/dev/null 2>&1; }
refreshed() { await '[ -n "$(report)" ] && no_lock'; }
line="waaagh: 3 merged, 1 likely merged worktrees in main - review with"

@test "first start is silent and refreshes in the background; the next start prints one line; nothing is removed" {
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  refreshed
  read -r first <"$(report)"
  [[ "$first" =~ ^"# wt-cleanup report at="[0-9]+" pr-closed=yes repo-dir=$M"$ ]]
  [ "$(cat "$FX/cleanup-calls")" = "--repo-dir $M --pr-closed" ]   # a dry run: never --apply
  grep -q "fetch -q origin" "$FX/fetches"
  run hook "$T/l0"   # from any worktree of the repository: the same report
  [ "$status" -eq 0 ]
  [[ "$output" == "$line $SCRIPTS/wt-cleanup.sh --repo-dir $M (dry run; removing needs --apply after the owner agrees)" ]]
  [ -d "$T/l0" ]
}

@test "a fresh report is only read: no fetch, no wt-cleanup run" {
  "$SCRIPTS/wt-session-hint.sh" --refresh "$M"   # in the foreground: no background poll needed
  rm -f "$FX/cleanup-calls" "$FX/fetches"
  r=$(report)
  cp "$r" "$T/before"
  run hook
  [[ "$output" == "$line"* ]]
  sleep 0.3   # a refresh, had one started, would have fetched by now
  [ ! -e "$FX/cleanup-calls" ]
  [ ! -e "$FX/fetches" ]
  cmp -s "$r" "$T/before"
}

@test "a stale report is silent and refreshed once, however many sessions start meanwhile" {
  "$SCRIPTS/wt-session-hint.sh" --refresh "$M"
  r=$(report)
  later=$(( $(date +%s) + 43200 ))
  rm -f "$FX/cleanup-calls"; touch "$FX/cleanup-hang"
  ORCHESTRATE_NOW=$later run hook
  [ -z "$output" ]   # older than 12h: not trusted, not printed
  await '[ -s "$FX/cleanup-calls" ]'
  ORCHESTRATE_NOW=$later run hook
  ORCHESTRATE_NOW=$later run hook
  sleep 0.3
  [ "$(wc -l <"$FX/cleanup-calls")" -eq 1 ]
  rm -f "$FX/cleanup-hang"
  await no_lock
  # A lock left by a refresh that died is taken over after an hour.
  mkdir "$r.lock"; echo 1 >"$r.lock/at"; rm -f "$FX/cleanup-calls"
  ORCHESTRATE_NOW=$(( later + 43200 )) run hook   # the refresh above dated its report +12h
  await '[ -s "$FX/cleanup-calls" ] && no_lock'
}

@test "the hook never waits on the refresh: with git fetch and wt-cleanup hanging it returns at once (timing)" {
  # The bounds hold on a plain run (measured about 20 ms a start). Under dev/coverage.sh every
  # traced line goes through bashcov (xtrace on: $- has x), so they widen there; the hangs last
  # until released below, so returning within either bound still proves the hook does not wait.
  one=1 ten=3
  [[ $- != *x* ]] || one=15 ten=60
  touch "$FX/fetch-hang" "$FX/cleanup-hang"
  s=$SECONDS
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  (( SECONDS - s <= one ))
  await '[ -s "$FX/fetches" ]'   # the refresh did start, in the background
  # Reading a fresh report: ten starts in well under a second each.
  rm -f "$FX/fetch-hang" "$FX/cleanup-hang"
  refreshed
  s=$SECONDS
  for _ in 1 2 3 4 5 6 7 8 9 10; do hook >/dev/null; done
  (( SECONDS - s <= ten ))
}

@test "counting: merged proofs always, pushed rows only under --pr-closed, likely apart; zero prints nothing" {
  touch "$FX/no-repo"   # wt-cleanup --pr-closed exits 2: the refresh falls back to the local proofs
  "$SCRIPTS/wt-session-hint.sh" --refresh "$M"
  read -r first <"$(report)"
  [[ "$first" == *" pr-closed=no "* ]]
  [ "$(cat "$FX/cleanup-calls")" = $'--repo-dir '"$M"$' --pr-closed\n--repo-dir '"$M" ]
  run hook
  [[ "$output" == "waaagh: 2 merged, 1 likely merged worktrees in main - review with"* ]]
  rm -f "$FX/no-repo"
  printf 'keep\t%s\tmain worktree\n' "$M" >"$FX/rows"
  "$SCRIPTS/wt-session-hint.sh" --refresh "$M"
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--refresh with the real wt-cleanup.sh, in the foreground: its rows, its counts, no removal, one refresh at a time" {
  unset ORCHESTRATE_SCRIPTS_DIR
  git clone -q "$O" "$U" 2>/dev/null
  land() { git -C "$U" pull -q --rebase origin main; printf '%s\n' "$2" >"$U/$1"; git -C "$U" add -A; git -C "$U" commit -qm "$3"; git -C "$U" push -q origin HEAD:main; }
  lane() { git -C "$M" worktree add -q -b "$1" "$T/$1" origin/main; printf '%s\n' "$3" >"$T/$1/$2"; git -C "$T/$1" add -A; git -C "$T/$1" commit -qm "$4"; touch -t "$old" "$T/$1" "$(git -C "$T/$1" rev-parse --path-format=absolute --git-path index)"; }
  lane s1 g1 one "s1"; land g1 one "S1 (#1)"
  lane lk f b "Add the widget"; sleep 1; land f B "Add the widget (#3)"
  echo '{"number":3,"merged_at":"2026-11-20T00:00:00Z"}' >"$FX/pull-3"
  lane wip h wip "wip"
  git -C "$M" fetch -q origin
  run "$SCRIPTS/wt-session-hint.sh" --refresh "$M"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  r=$(report)
  read -r first <"$r"
  [[ "$first" =~ ^"# wt-cleanup report at="[0-9]+" pr-closed=yes repo-dir=$M"$ ]]
  grep -q $'^remove\t'"$T/s1"$'\tclean, idle 72h, merged (' "$r"
  grep -q $'^keep\t'"$T/lk"$'\tlikely merged (subject)' "$r"
  grep -q $'^keep\t'"$T/wip"$'\tHEAD is not on any remote branch' "$r"
  run hook
  [[ "$output" == "waaagh: 1 merged, 1 likely merged worktrees in main - review with"* ]]
  for d in s1 lk wip l0; do [ -d "$T/$d" ]; done
  [ "$(ls "$ORCHESTRATE_STATE_DIR/wt-reports")" = "${r##*/}" ]   # no tmp file or lock left behind
  # A directory that is no checkout writes nothing (the no-repository fallback: the counting case).
  cp "$r" "$T/before"
  run "$SCRIPTS/wt-session-hint.sh" --refresh "$T"   # not a checkout
  [ "$status" -eq 0 ]
  cmp -s "$r" "$T/before"
  # A refresh already in flight (its lock held) is left alone.
  mkdir "$r.lock"; rm -f "$FX/fetches"
  run "$SCRIPTS/wt-session-hint.sh" --refresh "$M"
  [ "$status" -eq 0 ]
  [ -d "$r.lock" ]
  [ ! -e "$FX/fetches" ]
  rmdir "$r.lock"
}

@test "silent with nothing to say: no linked worktrees, outside git; bad arguments" {
  git clone -q "$O" "$U" 2>/dev/null
  run hook "$U"   # a clone with no linked worktree: no report, no refresh
  [ -z "$output" ]
  sleep 0.3
  [ ! -d "$ORCHESTRATE_STATE_DIR/wt-reports" ]
  mkdir "$T/plain"
  run hook "$T/plain"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$SCRIPTS/wt-session-hint.sh" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPTS/wt-session-hint.sh" --refresh "$T/none"
  [ "$status" -eq 2 ]
  run "$SCRIPTS/wt-session-hint.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"never waits on gh or git fetch"* ]]
}

@test "the plugin registers it as a SessionStart command hook with a short timeout" {
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  jq -e '.hooks.SessionStart[] | select(.matcher == "startup|resume|clear") | .hooks[]
    | select(.type == "command" and .command == "${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/scripts/wt-session-hint.sh" and .timeout <= 5)' "$ROOT/hooks/hooks.json" >/dev/null
  ! grep -n -- '--apply' "$SCRIPTS/wt-session-hint.sh" | grep -v '^[0-9]*:#' | grep -v 'needs --apply'
}
