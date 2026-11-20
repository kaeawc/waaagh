#!/usr/bin/env bats
# Host load attribution (host-load.sh, read from a stubbed spectra) and the worktree budget and
# live-cwd guard (wt-cleanup.sh, against a stubbed spectra and du and gh on PATH). Run: bats host-budget.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin" FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BIN" "$FX"
  export FX PATH="$BIN:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  unset ORCHESTRATE_WORKTREE_ROOT
  stub_spectra   # spectra owner --under answers "who works in this tree" (#331)
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

# --- host-load.sh (readings and attribution from spectra, #330) --------------------------------
hl() { "$SCRIPTS/host-load.sh" "$@"; }
row() { printf '%s\n' "$output" | awk -F'\t' -v k="$1" '$1 == k && !done { sub("^[^\t]*\t", ""); print; done = 1 }'; }
# load_json JSON: what spectra load answers beyond the stub's readings (cause, tables, families).
load_json() { printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/spectra-load.json"; }
proc() { # PID CPU RSS_KIB COMMAND DIR
  jq -cn --argjson p "$1" --argjson c "$2" --argjson r "$3" --arg n "$4" --arg d "$5" \
    '{pid: $p, command: $n, cpu_pct: $c, rss_kib: $r} + (if $d == "" then {dir: "unknown"} else {cwd: $d, dir: $d} end)'
}

@test "host-load holds on load and names Spotlight indexing as the cause, with the owner action" {
  stub_spectra; export SPECTRA_STUB_CPUS=16
  R="$BATS_TEST_TMPDIR/wt"; mkdir -p "$R/lane-a/src"; R=$(cd "$R" && pwd -P)
  load_json "$(jq -n --argjson a "$(proc 310 160.0 18874368 fseventsd "")" --argjson b "$(proc 400 20.04 524288 node "$R/lane-a/src")" \
    '{cause: {kind: "indexing", detail: "indexing leads the CPU table (fseventsd, mds_stores)", cpu_pct: 310},
      top_cpu: [$a, $b], top_rss: [$a], families: [{name: "Spotlight", kind: "indexing", members: 3, cpu_pct: 310.0, rss_kib: 22020096}]}')"
  SPECTRA_STUB_LOAD1=120.5 SPECTRA_STUB_FREE_GB=20 run hl --worktree-root "$R"
  [ "$status" -eq 3 ]
  [[ "$(row verdict)" == $'HOLD\t1-min load 120.5 >= 24.00 (1.5 x 16 CPUs)' ]]
  [[ "$(row cause)" == $'indexing\tindexing leads the CPU table (fseventsd, mds_stores)' ]]
  [[ "$(row hint)" == *"exclude $R from Spotlight (System Settings > Spotlight > Search Privacy) or plan a reboot"* ]]
  # Top tables: by CPU and by RSS, each process tied to its worktree; then the process families.
  [[ "$(row top-cpu)" == $'310\t160\t18432\tfseventsd\t-' ]]
  [[ "$output" == *$'top-cpu\t400\t20\t512\tnode\tlane-a'* ]]
  [[ "$(row top-rss)" == $'310\t160\t18432\tfseventsd\t-' ]]
  [[ "$(row family)" == $'Spotlight\tindexing\t3\t310\t21504' ]]
  # --top N caps each table.
  run hl --worktree-root "$R" --top 1
  [ "$(printf '%s\n' "$output" | grep -c '^top-cpu')" -eq 1 ]
}

@test "host-load names the lane worktree that leads, a CI runner, and other load by spectra's detail" {
  stub_spectra; export SPECTRA_STUB_CPUS=16 SPECTRA_STUB_LOAD1=40
  R="$BATS_TEST_TMPDIR/wt"; mkdir -p "$R/lane-b"; R=$(cd "$R" && pwd -P)
  load_json "$(jq -n --arg r "$R" --argjson a "$(proc 500 300.0 1048576 java "$R/lane-b")" \
    '{cause: {kind: "roots", root: $r, worktree: "lane-b", detail: "worktree lane-b leads the CPU table", cpu_pct: 300}, top_cpu: [$a]}')"
  run hl --worktree-root "$R"
  [ "$status" -eq 3 ]
  [[ "$(row cause)" == $'lanes\tworktree lane-b leads the CPU table' ]]
  [[ "$(row hint)" == "lane processes lead (worktree lane-b): start no lane"* ]]
  [[ "$output" == *$'top-cpu\t500\t300\t1024\tjava\tlane-b'* ]]
  load_json '{"cause": {"kind": "ci-runner", "detail": "a GitHub Actions runner leads the CPU table"}}'
  run hl --worktree-root "$R"
  [[ "$(row cause)" == $'ci-runner\ta GitHub Actions runner leads the CPU table' ]]
  [[ "$(row hint)" == "a CI runner on this host leads: lower the lane cap"* ]]
  load_json '{"cause": {"kind": "other", "detail": "process backupd (pid 600) leads the CPU table"}}'
  run hl --worktree-root "$R"
  [[ "$(row cause)" == $'other\tprocess backupd (pid 600) leads the CPU table' ]]
  [[ "$(row hint)" == *"do not stop it yourself"* ]]
}

@test "host-load admits only under the load limit with 8 GB free; backs off under 4 GB; third slot at 12 GB" {
  stub_spectra; export SPECTRA_STUB_CPUS=16
  SPECTRA_STUB_LOAD1=10 SPECTRA_STUB_FREE_GB=12.7 run hl
  [ "$status" -eq 0 ]
  [[ "$(row verdict)" == ADMIT* ]]
  [ "$(row device-slots)" = 3 ]
  SPECTRA_STUB_LOAD1=10 SPECTRA_STUB_FREE_GB=8.8 run hl
  [ "$status" -eq 0 ]
  [ "$(row device-slots)" = 2 ]
  SPECTRA_STUB_LOAD1=23.9 SPECTRA_STUB_FREE_GB=5.86 run hl
  [ "$status" -eq 3 ]
  [[ "$(row verdict)" == $'HOLD\tfree memory 5.8 GB < 8 GB' ]]
  SPECTRA_STUB_LOAD1=24 SPECTRA_STUB_FREE_GB=8.8 run hl
  [ "$status" -eq 3 ]
  SPECTRA_STUB_LOAD1=1 SPECTRA_STUB_FREE_GB=2.9 run hl
  [ "$status" -eq 4 ]
  [[ "$(row verdict)" == BACKOFF* ]]
  # Thresholds are flags; --top 0 skips the process tables.
  SPECTRA_STUB_LOAD1=30 SPECTRA_STUB_FREE_GB=8.8 run hl --load-factor 2 --top 0
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

@test "wt-cleanup keeps a worktree that any process (per spectra owner --under) has as its cwd, or a cwd below it" {
  wt_repo; mkwt idle; mkwt home; mkwt deep
  printf '700\t%s\n701\t%s\n' "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/deep/sub" >"$BATS_TEST_TMPDIR/spectra-cwds"
  run wtc --apply
  [ "$status" -eq 0 ]
  [[ "$(verdict idle)" == removed* ]]
  [[ "$(verdict home)" == $'keep\ta process is working inside it' ]]
  [[ "$(verdict deep)" == $'keep\ta process is working inside it' ]]
  [ -d "$BATS_TEST_TMPDIR/home" ] && [ -d "$BATS_TEST_TMPDIR/deep" ]
}

@test "wt-cleanup reads cwds again right before removing: a session that entered meanwhile keeps it" {
  wt_repo; mkwt entered
  printf '800\t%s\n' "$BATS_TEST_TMPDIR/entered" >"$BATS_TEST_TMPDIR/spectra-late-cwds"; echo 2 >"$BATS_TEST_TMPDIR/spectra-late-at"
  run wtc
  [[ "$(verdict entered)" == remove* ]]
  rm -f "$BATS_TEST_TMPDIR/spectra-owner-n"
  run wtc --apply
  [[ "$(verdict entered)" == $'keep\ta process is working inside it' ]]
  [ -d "$BATS_TEST_TMPDIR/entered" ]
}

@test "wt-cleanup removes nothing when spectra cannot say who works in a tree (#331)" {
  wt_repo; mkwt a
  : >"$BATS_TEST_TMPDIR/spectra-cwds"
  SPECTRA_STUB_FAIL=1 run wtc --apply
  [[ "$(verdict a)" == $'keep\tcannot check processes: spectra owner --under failed' ]]
  SPECTRA="$BATS_TEST_TMPDIR/none" run wtc --apply
  [[ "$(verdict a)" == $'keep\tcannot check processes: spectra owner --under failed' ]]
  [ -d "$BATS_TEST_TMPDIR/a" ]
  # Spectra is asked about the worktrees and the lane build root, not about every process.
  run wtc --apply
  [[ "$(verdict a)" == removed* ]]
  grep -q "^owner --under --json .*$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/spectra-calls"
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
  printf '1\t%s\n' "$BATS_TEST_TMPDIR/w3" >"$BATS_TEST_TMPDIR/spectra-cwds"
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
