#!/usr/bin/env bats
# boot-slot.sh (#314): device boots go one at a time, only while the 1-minute load is below
# F x CPUs, and the slot is kept for a settle time. The load comes from a stubbed host-load.sh
# (ORCHESTRATE_SCRIPTS_DIR) that reads a file, so a test can lower it. Run: bats boot-slot.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  T=$BATS_TEST_TMPDIR
  mkdir -p "$T/stubs"
  export ORCHESTRATE_SLOT_DIR="$T/slots" SLOT_POLL=0.05 ORCHESTRATE_SCRIPTS_DIR="$T/stubs" LOADF="$T/load"
  unset ORCHESTRATE_BOOT_LOAD_FACTOR ORCHESTRATE_BOOT_SETTLE ORCHESTRATE_BOOT_WAIT ORCHESTRATE_BOOT_SLOT_HELD ORCHESTRATE_BOOT_SLOT_HOLDER
  # host-load.sh's rows, with the load read from a file at each call; exit 3 (HOLD) when it is high.
  cat >"$T/stubs/host-load.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$LOADF.calls"
l=$(cat "$LOADF" 2>/dev/null || true)
[[ "$l" != unreadable ]] || exit 1
printf 'verdict\tADMIT\tok\nload\t%s\t16 CPUs, limit 24.0\n' "$l"
awk -v l="$l" 'BEGIN { exit (l + 0 >= 24) ? 3 : 0 }'
STUB
  chmod +x "$T/stubs/host-load.sh"
  echo 5.20 >"$LOADF"
}

boot() { "$SCRIPTS/boot-slot.sh" --settle 0 "$@"; }
holders() { find "$ORCHESTRATE_SLOT_DIR/boot" -name holder 2>/dev/null | wc -l | tr -d ' '; }
held() { echo "while [ ! -e '$T/release-$1' ]; do sleep 0.05; done"; }
release() { touch "$T/release-$1"; }
await() { local _; for _ in $(seq 1 200); do eval "$1" && return 0; sleep 0.05; done; echo "timed out: $1"; return 1; }
teardown() { release a; release b; }

@test "a boot runs when the load is below the limit, passes its exit code and frees the slot" {
  run boot -- bash -c 'echo booted'
  [ "$status" -eq 0 ]
  [ "$output" = booted ]
  run boot -- bash -c 'exit 7'
  [ "$status" -eq 7 ]
  [ "$(holders)" -eq 0 ]
  # Only the load is asked for: no process tables.
  [ "$(sort -u "$LOADF.calls")" = "--top 0" ]
}

@test "boots go one at a time; the second waits for the first" {
  L="$T/order"
  boot -- bash -c "echo a-start >>'$L'; $(held a); echo a-end >>'$L'" &
  await '[ -s "$L" ]'
  boot -- bash -c "echo b-start >>'$L'; echo b-end >>'$L'" &
  sleep 0.3   # time for the second to start, if it did not wait
  [ "$(cat "$L")" = a-start ]
  [ "$(holders)" -eq 1 ]
  release a
  wait
  [ "$(tr '\n' ' ' <"$L")" = "a-start a-end b-start b-end " ]
  [ "$(holders)" -eq 0 ]
}

@test "a boot waits for the load to fall below F x CPUs, and gives up with exit 75" {
  echo 235.00 >"$LOADF"          # the incident: 235 on 16 CPUs, limit 48
  boot -- bash -c "echo booted >'$T/out'" 2>"$T/err" &
  await 'grep -c "waiting for the load to fall (235.00, limit 48.0)" "$T/err" >/dev/null'
  [ ! -e "$T/out" ]
  echo 47.90 >"$LOADF"
  wait
  [ "$(cat "$T/out")" = booted ]
  # At the limit is not below it; a lower factor moves the limit.
  echo 48.00 >"$LOADF"
  run boot --wait 0 -- true
  [ "$status" -eq 75 ]
  [[ "$output" == *"load 48.00 still at or above 48.0 after 0s"* ]]
  echo 20.00 >"$LOADF"
  run boot --wait 0 --load-factor 1 -- true
  [ "$status" -eq 75 ]
  ORCHESTRATE_BOOT_LOAD_FACTOR=1.5 run boot --wait 0 -- bash -c 'echo ok'
  [ "$output" = ok ]
  [ "$(holders)" -eq 0 ]
}

@test "a busy slot past --wait is exit 75; an unreadable load is exit 3, never a blind boot" {
  boot -- bash -c "$(held a)" &
  await '[ "$(holders)" = 1 ]'
  run boot --wait 0 -- true
  [ "$status" -eq 75 ]
  [[ "$output" == *"another boot holds the slot"* ]]
  release a
  wait
  echo unreadable >"$LOADF"
  run boot -- bash -c "echo booted >'$T/out'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"could not be read"* ]]
  [ ! -e "$T/out" ]
  echo "" >"$LOADF"
  run boot -- true
  [ "$status" -eq 3 ]
  [ "$(holders)" -eq 0 ]
}

@test "the slot is kept for the settle time after a boot that succeeded, not after one that failed" {
  boot() { "$SCRIPTS/boot-slot.sh" "$@"; }
  s=$(date +%s)
  run boot --settle 2 -- true
  [ "$status" -eq 0 ]
  [ $(($(date +%s) - s)) -ge 2 ]
  s=$(date +%s)
  ORCHESTRATE_BOOT_SETTLE=30 run boot -- false
  [ "$status" -eq 1 ]
  [ $(($(date +%s) - s)) -lt 10 ]
}

@test "a nested boot-slot runs in the slot already held; a stale marker does not" {
  B="$SCRIPTS/boot-slot.sh"
  run boot -- "$B" --settle 0 --wait 0 -- bash -c 'echo inner'
  [ "$status" -eq 0 ]
  [[ "$output" == *inner* && "$output" == *"already inside a boot slot"* ]]
  # Another process's slot: the marker names a PID that does not hold it.
  boot -- bash -c "$(held a)" &
  await '[ "$(holders)" = 1 ]'
  ORCHESTRATE_BOOT_SLOT_HELD="$ORCHESTRATE_SLOT_DIR/boot/slot-1" ORCHESTRATE_BOOT_SLOT_HOLDER=$$ run boot --wait 0 -- true
  [ "$status" -eq 75 ]
  release a
  wait
}

@test "usage, and the briefs and docs send device boots through the gate" {
  run "$SCRIPTS/boot-slot.sh"
  [ "$status" -eq 2 ]
  run boot --load-factor x -- true
  [ "$status" -eq 2 ]
  run boot --wait soon -- true
  [ "$status" -eq 2 ]
  [ ! -e "$LOADF.calls" ]
  D="$ROOT/skills/orchestrate"
  for f in "$D/roles/verification.md" "$D/roles/verify-batch.md" "$D/host-load.md" "$D/SKILL.md" "$ROOT/README.md"; do
    grep -qF 'boot-slot.sh' "$f" || { echo "no boot-slot.sh in ${f#"$ROOT"/}"; return 1; }
  done
  grep -qF 'one at a time, shutting each down' "$D/roles/verification.md"
  grep -qF 'pause' "$D/host-load.md"
}
