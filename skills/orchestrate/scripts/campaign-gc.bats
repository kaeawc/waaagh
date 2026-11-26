#!/usr/bin/env bats
# campaign-gc.sh (#418): rebuildable output and raw captures in old campaign state; evidence,
# ledgers, recent candidates and busy entries are left alone. A dry run unless --apply.
# Run: bats campaign-gc.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  stub_spectra
  : >"$BATS_TEST_TMPDIR/spectra-cwds"   # nobody works anywhere
  export ORCHESTRATE_NOW=1795000000      # 2026-11-18T07:06:40Z
  C="$BATS_TEST_TMPDIR/state/o__r"
  mkdir -p "$C/verify/run1/checkout/node_modules/pkg" "$C/verify/run1/App.app/Contents" "$C/evidence/l1" \
    "$C/learnings" "$C/fresh" "$C/busy/build"
  echo ledger >"$C/lanes.tsv"
  echo '{}' >"$C/verify/run1/checkout/package.json"   # node_modules beside a build definition
  : >"$C/busy/Makefile"
  mk() { head -c "$2" /dev/zero >"$1"; }
  mk "$C/verify/run1/checkout/node_modules/pkg/index.js" 4096
  mk "$C/verify/run1/App.app/Contents/bin" 8192
  mk "$C/verify/run1/app-debug.apk" 16384
  mk "$C/verify/run1/scratch.tmp" 2048
  mk "$C/evidence/l1/audio.pcm" 65536
  echo "PASS on device" >"$C/evidence/l1/result.md"
  mk "$C/evidence/l1/screen.png" 4096
  mk "$C/learnings/note.tmp" 1024
  mk "$C/fresh/new.apk" 4096
  mk "$C/busy/build/out.o" 4096
  # Everything old, then one recent file under fresh/.
  find "$C" -exec env TZ=UTC touch -t 202601010000 {} +
  TZ=UTC touch -t 202611170000 "$C/fresh/new.apk"
}
gc() { run "$SCRIPTS/campaign-gc.sh" --state-dir "$C" "$@"; }

@test "the dry run lists only rebuildable output and captures in old entries, and changes nothing" {
  gc --top 3
  [ "$status" -eq 0 ]
  # Directory sizes differ by filesystem (a directory is 0K on APFS, 4K on ext4): counts only.
  [[ "${lines[0]}" == $'build\t2\t'* ]]          # node_modules, busy/build (nobody is in busy/)
  [[ "${lines[1]}" == $'binary\t2\t'* ]]         # App.app, app-debug.apk
  [ "${lines[2]}" = $'temp\t1\t4K' ]
  [ "${lines[3]}" = $'capture\t1\t64K' ]
  [ "${lines[4]}" = $'64K\tcapture\tevidence/l1/audio.pcm' ]
  [[ "${lines[7]}" == "mode=dry-run entries=4 busy=0 recent=1 remove="*"K compress=64K" ]]
  [ "${#lines[@]}" -eq 8 ]
  [ -f "$C/verify/run1/app-debug.apk" ]
  [ -f "$C/evidence/l1/audio.pcm" ]
  [ ! -e "$C/campaign-gc.log" ]
}

@test "--apply removes build output, binaries and temp files, gzips captures, and keeps evidence" {
  gc --apply --top 0
  [ "$status" -eq 0 ]
  [[ "${lines[4]}" == "mode=apply entries=4 busy=0 recent=1 remove="*" compress=64K freed="* ]]
  [ ! -e "$C/verify/run1/checkout/node_modules" ]
  [ ! -e "$C/verify/run1/App.app" ]
  [ ! -e "$C/verify/run1/app-debug.apk" ]
  [ ! -e "$C/verify/run1/scratch.tmp" ]
  [ ! -e "$C/evidence/l1/audio.pcm" ]
  [ -f "$C/evidence/l1/audio.pcm.gz" ]
  [ "$(gzip -dc "$C/evidence/l1/audio.pcm.gz" | wc -c | tr -d ' ')" -eq 65536 ]
  [ -f "$C/evidence/l1/result.md" ]
  [ -f "$C/evidence/l1/screen.png" ]
  [ -f "$C/lanes.tsv" ]
  [ -f "$C/learnings/note.tmp" ]      # protected directory
  [ -f "$C/fresh/new.apk" ]           # recent candidate
  [ "$(wc -l <"$C/campaign-gc.log" | tr -d ' ')" -eq 6 ]
  grep -q $'\tgzip\tcapture\t64K\tevidence/l1/audio.pcm$' "$C/campaign-gc.log"
}

@test "an entry a process works in is skipped; --apply without spectra refuses with exit 5" {
  printf '9\t%s\n' "$C/busy" >"$BATS_TEST_TMPDIR/spectra-cwds"
  gc --top 0
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == $'build\t1\t'* ]]
  [[ "${lines[4]}" == "mode=dry-run entries=3 busy=1 recent=1 remove="*" compress=64K" ]]
  SPECTRA_STUB_FAIL=1 gc --apply
  [ "$status" -eq 5 ]
  [[ "$output" == *"nothing was changed"* ]]
  [ -f "$C/verify/run1/app-debug.apk" ]
}

@test "review #419: names that look like build output but are not, odd paths and .git are left alone" {
  mkdir -p "$C/evidence/src/com/acme/build" "$C/evidence/repo/.git/refs/heads/build" "$C/target" \
    "$C/evidence/keep"$'\n'"y/build" "$C/evidence/out"$'\t'"x/build"
  echo 'fun main() {}' >"$C/evidence/src/com/acme/build/Main.kt"   # a source package named build
  echo abc >"$C/evidence/repo/.git/refs/heads/build/topic"          # refs of branches build/*
  : >"$C/evidence/repo/.git/x.tmp"
  echo ledger >"$C/target/ledger.tsv"                               # a top-level entry named target
  : >"$C/target/Makefile"
  : >"$C/evidence/keep"$'\n'"y/Makefile"; echo keep >"$C/evidence/keep"$'\n'"y/result.md"
  : >"$C/evidence/out"$'\t'"x/Makefile"; echo keep >"$C/evidence/out"$'\t'"x/result.md"
  : >"$C/evidence/keep"$'\n'"y/build/o"; : >"$C/evidence/out"$'\t'"x/build/o"
  find "$C" -exec env TZ=UTC touch -t 202601010000 {} +
  TZ=UTC touch -t 202611170000 "$C/fresh/new.apk"
  gc --apply --top 0
  [ "$status" -eq 0 ]
  [[ "${lines[4]}" == "mode=apply entries=5 busy=0 recent=1 odd-names=2 kept-generic=1 remove="* ]]
  [ -f "$C/evidence/src/com/acme/build/Main.kt" ]
  [ -f "$C/evidence/repo/.git/refs/heads/build/topic" ]
  [ -f "$C/evidence/repo/.git/x.tmp" ]
  [ -f "$C/target/ledger.tsv" ]
  [ -f "$C/evidence/keep"$'\n'"y/result.md" ]
  [ -f "$C/evidence/out"$'\t'"x/result.md" ]
  [ -d "$C/evidence/keep"$'\n'"y/build" ]
  [ ! -e "$C/verify/run1/checkout/node_modules" ]   # the real build output still goes
}

@test "delta review #419: a rejected generic directory is searched and counted; Flutter and Python builds count" {
  mkdir -p "$C/evidence/src/build/sub" "$C/evidence/flutter/build" "$C/evidence/py/build"
  : >"$C/evidence/src/build/sub/app.apk"; echo 'fun x() {}' >"$C/evidence/src/build/Keep.kt"
  : >"$C/evidence/flutter/pubspec.yaml"; : >"$C/evidence/flutter/build/out.bin"
  : >"$C/evidence/py/pyproject.toml"; : >"$C/evidence/py/build/lib.so"
  find "$C" -exec env TZ=UTC touch -t 202601010000 {} +
  TZ=UTC touch -t 202611170000 "$C/fresh/new.apk"
  gc --apply --top 0
  [ "$status" -eq 0 ]
  [[ "${lines[4]}" == *" kept-generic=1 "* ]]
  [ ! -e "$C/evidence/src/build/sub/app.apk" ]     # found inside the rejected source dir
  [ -f "$C/evidence/src/build/Keep.kt" ]
  [ ! -e "$C/evidence/flutter/build" ]
  [ ! -e "$C/evidence/py/build" ]
}

@test "a candidate written to after the listing is skipped at apply time" {
  # The age check runs again right before each action: a stub du touches the apk while sizing it.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *.apk) touch "$a" ;; esac; done\nexec /usr/bin/du "$@"\n' >"$BATS_TEST_TMPDIR/bin/du"
  chmod +x "$BATS_TEST_TMPDIR/bin/du"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" gc --apply --top 0
  [ "$status" -eq 0 ]
  [ -f "$C/verify/run1/app-debug.apk" ]
  grep -q $'\tskipped (changed)\tbinary\t.*verify/run1/app-debug.apk$' "$C/campaign-gc.log"
  [ ! -e "$C/verify/run1/scratch.tmp" ]
}

@test "--older-than moves the cutoff; usage errors are exit 2" {
  gc --older-than 0 --top 0   # the cutoff is now: fresh/ is old enough too
  [ "$status" -eq 0 ]
  [[ "${lines[4]}" == "mode=dry-run entries=4 busy=0 recent=0 remove="*" compress=64K" ]]
  [[ "${lines[1]}" == $'binary\t3\t'* ]]   # fresh/new.apk counts now
  gc --older-than x
  [ "$status" -eq 2 ]
  run "$SCRIPTS/campaign-gc.sh"
  [ "$status" -eq 2 ]
  run "$SCRIPTS/campaign-gc.sh" --state-dir "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 2 ]
}
