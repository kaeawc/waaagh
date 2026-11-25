#!/usr/bin/env bats
# wt-session-hint.sh, the SessionStart hook (#395): one line from a cached wt-cleanup.sh report,
# refreshed in a detached background process when missing or stale; never waits on gh or git
# fetch, never removes. Against stubbed spectra, gh and (for hangs) git. Run: bats wt-session-hint.bats

setup() {
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin" FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BIN" "$FX"
  export FX PATH="$BIN:$PATH" ORCHESTRATE_BUILD_ROOT="$BATS_TEST_TMPDIR/build" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  unset ORCHESTRATE_WT_REPORT_TTL ORCHESTRATE_WT_REPORT_FETCH ORCHESTRATE_NOW
  stub_spectra
  : >"$BATS_TEST_TMPDIR/spectra-cwds"
  # gh: blocks while $FX/gh-hang exists; `repo view` names acme/widget unless $FX/no-repo exists;
  # PR reads as in wt-cleanup.bats ($FX/pulls-SHA, $FX/pull-N, $FX/pr-BRANCH).
  cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/gh-calls"
while [ -e "$FX/gh-hang" ]; do sleep 0.05; done
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
  if [ "\$a" = fetch ]; then echo "\$*" >>"\$FX/fetches"; while [ -e "\$FX/fetch-hang" ]; do sleep 0.05; done; break; fi
done
exec "$real_git" "\$@"
STUB
  chmod +x "$BIN/gh" "$BIN/git"
  O="$BATS_TEST_TMPDIR/origin.git" M="$BATS_TEST_TMPDIR/main" U="$BATS_TEST_TMPDIR/up"
  git init -q --bare "$O"
  git clone -q "$O" "$M" 2>/dev/null
  printf 'a\n' >"$M/f"; git -C "$M" add f; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main
  git -C "$O" symbolic-ref HEAD refs/heads/main
  git clone -q "$O" "$U" 2>/dev/null
  old=$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)
}

# A refresh left running holds nothing of bats' (its stdio is /dev/null), but must not outlive the
# test: release every hang and wait for the refresh lock to go.
teardown() {
  rm -f "$FX/gh-hang" "$FX/fetch-hang"
  local _; for _ in $(seq 1 200); do ls "$ORCHESTRATE_STATE_DIR"/wt-reports/*.lock >/dev/null 2>&1 || return 0; sleep 0.05; done
}

lane() { git -C "$M" worktree add -q -b "$1" "$BATS_TEST_TMPDIR/$1" origin/main; }
commit() { printf '%s\n' "$3" >"$BATS_TEST_TMPDIR/$1/$2"; git -C "$BATS_TEST_TMPDIR/$1" add -A; git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$4"; }
land() {
  git -C "$U" pull -q --rebase origin main
  printf '%s\n' "$2" >"$U/$1"; git -C "$U" add -A; git -C "$U" commit -qm "$3"; git -C "$U" push -q origin HEAD:main
}
idle() { touch -t "$old" "$BATS_TEST_TMPDIR/$1" "$(git -C "$BATS_TEST_TMPDIR/$1" rev-parse --path-format=absolute --git-path index)"; }
# Two squash-merged lanes, one likely merged, one unfinished.
lanes() {
  lane s1; commit s1 g1 one "s1"; idle s1; land g1 one "S1 (#1)"
  lane s2; commit s2 g2 two "s2"; idle s2; land g2 two "S2 (#2)"
  lane lk; commit lk f b "Add the widget"; idle lk; sleep 1; land f B "Add the widget (#3)"
  echo '{"number":3,"merged_at":"2026-11-20T00:00:00Z"}' >"$FX/pull-3"
  lane wip; commit wip h wip "wip"; idle wip
  git -C "$M" fetch -q origin
}
hook() { (cd "${1:-$M}" && "$SCRIPTS/wt-session-hint.sh"); }
report() { ls "$ORCHESTRATE_STATE_DIR"/wt-reports/*.tsv 2>/dev/null; }
await() { local _; for _ in $(seq 1 200); do eval "$1" && return 0; sleep 0.05; done; echo "timed out: $1"; return 1; }
no_lock() { ! ls "$ORCHESTRATE_STATE_DIR"/wt-reports/*.lock >/dev/null 2>&1; }
line="waaagh: 2 merged, 1 likely merged worktrees in main - review with"

@test "first start is silent and refreshes in the background; the next start prints one line; nothing is removed" {
  lanes
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  await '[ -n "$(report)" ] && no_lock'
  read -r first <"$(report)"
  [[ "$first" =~ ^"# wt-cleanup report at="[0-9]+" pr-closed=yes repo-dir=$M"$ ]]
  grep -q "^-q origin\$\|fetch -q origin" "$FX/fetches"
  run hook "$BATS_TEST_TMPDIR/wip"   # from any worktree of the repository: the same report
  [ "$status" -eq 0 ]
  [[ "$output" == "$line $SCRIPTS/wt-cleanup.sh --repo-dir $M (dry run; removing needs --apply after the owner agrees)" ]]
  for d in s1 s2 lk wip; do [ -d "$BATS_TEST_TMPDIR/$d" ]; done
  [ "$(git -C "$M" worktree list | wc -l)" -eq 5 ]
}

@test "a fresh report is only read: no fetch, no gh, no wt-cleanup run" {
  lanes
  run hook; await '[ -n "$(report)" ] && no_lock'
  rm -f "$FX/gh-calls" "$FX/fetches"; r=$(report); cp "$r" "$BATS_TEST_TMPDIR/before"
  run hook
  [[ "$output" == "$line"* ]]
  sleep 0.3   # a refresh, had one started, would have fetched by now
  [ ! -e "$FX/gh-calls" ]
  [ ! -e "$FX/fetches" ]
  cmp -s "$r" "$BATS_TEST_TMPDIR/before"
}

@test "a stale report is silent and refreshed once, however many sessions start meanwhile" {
  lanes
  run hook; await '[ -n "$(report)" ] && no_lock'
  r=$(report)
  ORCHESTRATE_NOW=$(( $(date +%s) + 43200 )) run hook
  [ -z "$output" ]   # older than 12h: not trusted, not printed
  rm -f "$FX/fetches"; touch "$FX/fetch-hang"
  ORCHESTRATE_NOW=$(( $(date +%s) + 43200 )) run hook
  await '[ -s "$FX/fetches" ]'
  ORCHESTRATE_NOW=$(( $(date +%s) + 43200 )) run hook
  ORCHESTRATE_NOW=$(( $(date +%s) + 43200 )) run hook
  sleep 0.3
  [ "$(wc -l <"$FX/fetches")" -eq 1 ]
  rm -f "$FX/fetch-hang"; await no_lock
  # A lock left by a refresh that died is taken over after an hour.
  mkdir "$r.lock"; echo 1 >"$r.lock/at"; rm -f "$FX/fetches"
  ORCHESTRATE_NOW=$(( $(date +%s) + 2 * 43200 )) run hook   # the refresh above dated its report +12h
  await '[ -s "$FX/fetches" ] && no_lock'
}

@test "the hook never waits on gh or git fetch: with both hanging it returns at once (timing)" {
  lanes
  touch "$FX/gh-hang" "$FX/fetch-hang"
  s=$SECONDS
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  (( SECONDS - s <= 1 ))
  await '[ -s "$FX/fetches" ]'   # the refresh did start, in the background
  # Reading a fresh report: ten starts in well under a second each.
  rm -f "$FX/gh-hang" "$FX/fetch-hang"; await '[ -n "$(report)" ] && no_lock'
  s=$SECONDS
  for _ in 1 2 3 4 5 6 7 8 9 10; do hook >/dev/null; done
  (( SECONDS - s <= 3 ))
}

@test "no GitHub repository: the refresh falls back to the local proofs, and pushed rows are not counted" {
  lanes
  touch "$FX/no-repo"
  lane pushed; commit pushed p p "pushed"; git -C "$BATS_TEST_TMPDIR/pushed" push -q origin pushed; idle pushed
  run hook; await '[ -n "$(report)" ] && no_lock'
  read -r first <"$(report)"; [[ "$first" == *" pr-closed=no "* ]]
  run hook
  # The subject proof reads GitHub: without a repository it is not tried.
  [[ "$output" == "waaagh: 2 merged, 0 likely merged worktrees in main - review with"* ]]
}

@test "--refresh writes the report in the foreground: header, wt-cleanup rows, no removal, one refresh at a time" {
  lanes
  run "$SCRIPTS/wt-session-hint.sh" --refresh "$M"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  r=$(report)
  read -r first <"$r"
  [[ "$first" =~ ^"# wt-cleanup report at="[0-9]+" pr-closed=yes repo-dir=$M"$ ]]
  grep -q $'^remove\t'"$BATS_TEST_TMPDIR/s1"$'\tclean, idle 72h, merged (' "$r"
  grep -q $'^keep\t'"$BATS_TEST_TMPDIR/lk"$'\tlikely merged (subject)' "$r"
  [ -d "$BATS_TEST_TMPDIR/s1" ] && no_lock
  # The fallback without a GitHub repository; then a directory that is no checkout writes nothing.
  touch "$FX/no-repo"; ORCHESTRATE_WT_REPORT_FETCH=0 run "$SCRIPTS/wt-session-hint.sh" --refresh "$M"
  read -r first <"$r"; [[ "$first" == *" pr-closed=no "* ]]
  cp "$r" "$BATS_TEST_TMPDIR/before"
  run "$SCRIPTS/wt-session-hint.sh" --refresh "$BATS_TEST_TMPDIR"   # not a checkout
  [ "$status" -eq 0 ]
  cmp -s "$r" "$BATS_TEST_TMPDIR/before"
  [ "$(ls "$ORCHESTRATE_STATE_DIR/wt-reports")" = "${r##*/}" ]   # no tmp file or lock left behind
  # A refresh already in flight (its lock held) is left alone.
  mkdir "$r.lock"; rm -f "$FX/fetches"
  run "$SCRIPTS/wt-session-hint.sh" --refresh "$M"
  [ "$status" -eq 0 ]
  [ -d "$r.lock" ]
  [ ! -e "$FX/fetches" ]
  rmdir "$r.lock"
}

@test "silent with nothing to say: no merged worktrees, no linked worktrees, outside git" {
  lane wip; commit wip h wip "wip"; idle wip
  run hook; await '[ -n "$(report)" ] && no_lock'
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -rf "$ORCHESTRATE_STATE_DIR"
  git -C "$U" status >/dev/null
  run hook "$U"   # a clone with no linked worktree: no report, no refresh
  [ -z "$output" ]
  sleep 0.3; [ ! -d "$ORCHESTRATE_STATE_DIR/wt-reports" ]
  mkdir "$BATS_TEST_TMPDIR/plain"
  run hook "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$SCRIPTS/wt-session-hint.sh" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPTS/wt-session-hint.sh" --refresh "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 2 ]
  run "$SCRIPTS/wt-session-hint.sh" -h
  [ "$status" -eq 0 ] && [[ "$output" == *"never waits on gh or git fetch"* ]]
}

@test "the plugin registers it as a SessionStart command hook with a short timeout" {
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  jq -e '.hooks.SessionStart[] | select(.matcher == "startup|resume|clear") | .hooks[]
    | select(.type == "command" and .command == "${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/scripts/wt-session-hint.sh" and .timeout <= 5)' "$ROOT/hooks/hooks.json" >/dev/null
  ! grep -n -- '--apply' "$SCRIPTS/wt-session-hint.sh" | grep -v '^[0-9]*:#' | grep -v 'needs --apply'
}
