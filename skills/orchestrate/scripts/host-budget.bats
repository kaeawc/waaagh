#!/usr/bin/env bats
# Host load attribution (host-load.sh) and the worktree budget and live-cwd guard (wt-cleanup.sh),
# against stubbed ps, lsof, du and gh on PATH. Run: bats host-budget.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin" FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BIN" "$FX"
  export FX PATH="$BIN:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  unset ORCHESTRATE_WORKTREE_ROOT
  # lsof: this process's own cwd (a trustworthy listing) unless $FX/no-self, then $FX/cwds
  # ("PID<TAB>path" lines); from call number $FX/late-at on, $FX/late-cwds too.
  cat >"$BIN/lsof" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$FX/lsof-n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FX/lsof-n"
[ -f "$FX/no-self" ] || printf 'p%s\nn%s\n' "$$" "$(pwd -P)"
for f in cwds late-cwds; do
  [ -f "$FX/$f" ] || continue
  [ "$f" = cwds ] || [ "$n" -ge "$(cat "$FX/late-at")" ] || continue
  awk -F'\t' '{ print "p" $1; print "n" $2 }' "$FX/$f"
done
STUB
  # ps: the table in $FX/ps ("pid pcpu rss comm").
  printf '#!/bin/sh\ncat "$FX/ps"\n' >"$BIN/ps"
  # du: "<KB><TAB>path", KB from $FX/du-kb (default 1048576 = 1 GB per tree).
  printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" "$(cat "$FX/du-kb" 2>/dev/null || echo 1048576)" "$2"\n' >"$BIN/du"
  # gh: `pr list --head B` prints $FX/pr-B (default []).
  cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/gh-calls"
h=""; while (($#)); do [ "$1" = --head ] && h=$2; shift; done
cat "$FX/pr-$h" 2>/dev/null || echo '[]'
STUB
  chmod +x "$BIN"/*
}

# --- host-load.sh -----------------------------------------------------------------------------
hl() { ORCHESTRATE_HOST_CPUS=16 "$SCRIPTS/host-load.sh" "$@"; }
row() { printf '%s\n' "$output" | awk -F'\t' -v k="$1" '$1 == k && !done { sub("^[^\t]*\t", ""); print; done = 1 }'; }

@test "host-load holds on load and names Spotlight indexing as the cause, with the owner action" {
  R="$BATS_TEST_TMPDIR/wt"; mkdir -p "$R/lane-a/src"
  cat >"$FX/ps" <<EOF
  310 160.0 18874368 /usr/sbin/fseventsd
  311  90.0  2097152 /System/Library/Frameworks/CoreServices.framework/mds_stores
  312  60.0  1048576 mds
  400  20.0   524288 node
  401   0.1     2048 bash
EOF
  printf '400\t%s\n' "$R/lane-a/src" >"$FX/cwds"
  ORCHESTRATE_HOST_LOAD1=120.5 ORCHESTRATE_HOST_FREE_MB=20480 run hl --worktree-root "$R"
  [ "$status" -eq 3 ]
  [[ "$(row verdict)" == $'HOLD\t1-min load 120.5 >= 24.00 (1.5 x 16 CPUs)' ]]
  [[ "$(row cause)" == $'indexing\tfseventsd 160.0%, mds_stores 90.0%, mds 60.0%' ]]
  [[ "$(row hint)" == *"exclude $R from Spotlight (System Settings > Spotlight > Search Privacy) or plan a reboot"* ]]
  # Top tables: by CPU and by RSS, each process tied to its worktree.
  [[ "$(row top-cpu)" == $'310\t160.0\t18432\tfseventsd\t-' ]]
  [[ "$output" == *$'top-cpu\t400\t20.0\t512\tnode\tlane-a'* ]]
  [[ "$(row top-rss)" == $'310\t160.0\t18432\tfseventsd\t-' ]]
  [ "$(printf '%s\n' "$output" | grep -c '^top-cpu')" -eq 5 ]
  run hl --worktree-root "$R" --top 2
  [ "$(printf '%s\n' "$output" | grep -c '^top-rss')" -eq 2 ]
}

@test "host-load attributes lane load to the worktree, and other load to its process" {
  R="$BATS_TEST_TMPDIR/wt"; mkdir -p "$R/lane-b" "$R/lane-c"
  printf '  500 300.0 1048576 java\n  501 150.0 524288 node\n  502 40.0 1024 WindowServer\n' >"$FX/ps"
  printf '500\t%s\n501\t%s\n' "$R/lane-b" "$R/lane-c" >"$FX/cwds"
  ORCHESTRATE_HOST_LOAD1=40 ORCHESTRATE_HOST_FREE_MB=20480 run hl --worktree-root "$R"
  [ "$status" -eq 3 ]
  [[ "$(row cause)" == $'lanes\tjava 300.0%, node 150.0%' ]]
  [[ "$(row hint)" == "lane processes lead"* ]]
  [[ "$output" == *$'top-cpu\t500\t300.0\t1024\tjava\tlane-b'* ]]
  printf '  600 900.0 1048576 backupd\n  601 10.0 1024 node\n' >"$FX/ps"
  ORCHESTRATE_HOST_LOAD1=40 ORCHESTRATE_HOST_FREE_MB=20480 run hl --worktree-root "$R"
  [[ "$(row cause)" == $'other\tbackupd 900.0%, node 10.0%' ]]
  [[ "$(row hint)" == *"do not stop it yourself"* ]]
}

@test "host-load admits only under the load limit with 8 GB free; backs off under 4 GB; third slot at 12 GB" {
  printf '  1 1.0 1024 launchd\n' >"$FX/ps"
  ORCHESTRATE_HOST_LOAD1=10 ORCHESTRATE_HOST_FREE_MB=13000 run hl
  [ "$status" -eq 0 ]
  [[ "$(row verdict)" == ADMIT* ]]
  [ "$(row device-slots)" = 3 ]
  ORCHESTRATE_HOST_LOAD1=10 ORCHESTRATE_HOST_FREE_MB=9000 run hl
  [ "$status" -eq 0 ]
  [ "$(row device-slots)" = 2 ]
  ORCHESTRATE_HOST_LOAD1=23.9 ORCHESTRATE_HOST_FREE_MB=6000 run hl
  [ "$status" -eq 3 ]
  [[ "$(row verdict)" == $'HOLD\tfree memory 5.9 GB < 8 GB' ]]
  ORCHESTRATE_HOST_LOAD1=24 ORCHESTRATE_HOST_FREE_MB=9000 run hl
  [ "$status" -eq 3 ]
  ORCHESTRATE_HOST_LOAD1=1 ORCHESTRATE_HOST_FREE_MB=3000 run hl
  [ "$status" -eq 4 ]
  [[ "$(row verdict)" == BACKOFF* ]]
  # Thresholds are flags; --top 0 skips the process tables.
  ORCHESTRATE_HOST_LOAD1=30 ORCHESTRATE_HOST_FREE_MB=9000 run hl --load-factor 2 --top 0
  [ "$status" -eq 0 ]
  [[ "$output" != *top-cpu* && "$output" != *cause* ]]
  run hl --load-factor x
  [ "$status" -eq 2 ]
}

# --- wt-cleanup.sh: live cwd guard and budget ---------------------------------------------------
wt_repo() {
  O="$BATS_TEST_TMPDIR/origin.git" M="$BATS_TEST_TMPDIR/main"
  git init -q --bare "$O"
  git clone -q "$O" "$M" 2>/dev/null
  echo x >"$M/f"; git -C "$M" add f; git -C "$M" commit -qm init; git -C "$M" push -q origin HEAD:main
  old=$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)
}
mkwt() { # name: a finished worktree (committed, pushed, idle 3 days)
  local w="$BATS_TEST_TMPDIR/$1"
  git -C "$M" worktree add -q -b "$1" "$w"
  mkdir -p "$w/sub"; echo "$1" >"$w/sub/$1.txt"; git -C "$w" add -A; git -C "$w" commit -qm "$1"
  git -C "$w" push -q origin "$1"; git -C "$M" fetch -q origin
  touch -t "$old" "$w" "$(git -C "$w" rev-parse --path-format=absolute --git-path index)"
}
wtc() { "$SCRIPTS/wt-cleanup.sh" --repo-dir "$M" "$@"; }
verdict() { printf '%s\n' "$output" | awk -F'\t' -v p="$BATS_TEST_TMPDIR/$1" '$2 == p { print $1 "\t" $3 }'; }

@test "wt-cleanup keeps a worktree that any process (per lsof) has as its cwd, or a cwd below it" {
  wt_repo; mkwt idle; mkwt home; mkwt deep
  printf '700\t%s\n701\t%s\n' "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/deep/sub" >"$FX/cwds"
  run wtc --apply
  [ "$status" -eq 0 ]
  [[ "$(verdict idle)" == removed* ]]
  [[ "$(verdict home)" == $'keep\ta process is working inside it' ]]
  [[ "$(verdict deep)" == $'keep\ta process is working inside it' ]]
  [ -d "$BATS_TEST_TMPDIR/home" ] && [ -d "$BATS_TEST_TMPDIR/deep" ]
}

@test "wt-cleanup reads cwds again right before removing: a session that entered meanwhile keeps it" {
  wt_repo; mkwt entered
  printf '800\t%s\n' "$BATS_TEST_TMPDIR/entered" >"$FX/late-cwds"; echo 2 >"$FX/late-at"
  run wtc
  [[ "$(verdict entered)" == remove* ]]
  rm -f "$FX/lsof-n"
  run wtc --apply
  [[ "$(verdict entered)" == $'keep\ta process is working inside it' ]]
  [ -d "$BATS_TEST_TMPDIR/entered" ]
}

@test "wt-cleanup distrusts an lsof listing without its own cwd: /proc next, else nothing is removed" {
  wt_repo; mkwt a
  touch "$FX/no-self"
  # /proc stand-in: one process whose cwd is the worktree.
  P="$BATS_TEST_TMPDIR/proc"; mkdir -p "$P/self" "$P/900"; ln -s "$BATS_TEST_TMPDIR/a" "$P/900/cwd"
  ORCHESTRATE_PROC_DIR="$P" run wtc --apply
  [[ "$(verdict a)" == $'keep\ta process is working inside it' ]]
  ORCHESTRATE_PROC_DIR="$BATS_TEST_TMPDIR/no-proc" run wtc --apply
  [[ "$(verdict a)" == $'keep\tcannot check processes (no lsof or /proc)' ]]
  [ -d "$BATS_TEST_TMPDIR/a" ]
}

@test "wt-cleanup reports the worktree budget by count and size, exit 3 when over" {
  wt_repo; mkwt w1; mkwt w2; mkwt w3
  run wtc --max-count 2
  [ "$status" -eq 3 ]
  [[ "$output" == *$'budget\t-\tover budget (count): live 3 worktrees (max 2); 3 removable with --apply'* ]]
  echo 2097152 >"$FX/du-kb"   # 2 GB each
  run wtc --max-count 5 --max-gb 5
  [ "$status" -eq 3 ]
  [[ "$output" == *$'over budget (size): live 3 worktrees (max 5), 6.0 GB (max 5)'* ]]
  # Removing the finished ones brings it back within budget.
  printf '1\t%s\n' "$BATS_TEST_TMPDIR/w3" >"$FX/cwds"
  run wtc --max-count 2 --max-gb 5 --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *$'budget\t-\twithin budget: live 1 worktrees (max 2), 2.0 GB (max 5)'* ]]
  run wtc --max-count x
  [ "$status" -eq 2 ]
}

@test "wt-cleanup --pr-closed removes only trees whose PRs are all merged or closed" {
  wt_repo; mkwt merged; mkwt open; mkwt nopr
  echo '[{"state":"MERGED"},{"state":"CLOSED"}]' >"$FX/pr-merged"
  echo '[{"state":"CLOSED"},{"state":"OPEN"}]' >"$FX/pr-open"
  run wtc --pr-closed --repo acme/widget --apply
  [ "$status" -eq 0 ]
  [[ "$(verdict merged)" == removed* ]]
  [[ "$(verdict open)" == $'keep\tPR still open' ]]
  [[ "$(verdict nopr)" == $'keep\tno PR for nopr' ]]
  grep -q -- '--head merged' "$FX/gh-calls"
  grep -q -- '--repo acme/widget' "$FX/gh-calls"
}

@test "the new host scripts kill nothing and document their exits in the -h header" {
  run ! grep -nE '\b(pkill|killall|renice)\b' "$SCRIPTS"/host-load.sh "$SCRIPTS"/wt-cleanup.sh
  run ! grep -n '\bkill\b' "$SCRIPTS"/host-load.sh "$SCRIPTS"/wt-cleanup.sh
  run "$SCRIPTS/host-load.sh" -h
  [[ "$output" == *"Exit: 0 ADMIT | 3 HOLD"* && "$output" != *"set -euo"* ]]
  run "$SCRIPTS/wt-cleanup.sh" -h
  [[ "$output" == *"Exit: 0 | 3 over the worktree budget"* && "$output" != *"set -euo"* ]]
}
