#!/usr/bin/env bats
# Lane-driver hygiene (#68): the device lock records the lane's serial or UDID and `check` confirms
# ownership before any adb or simctl command; one blocking wait per gate; ready PRs that list
# missing device evidence; blocked-by links checked before dispatch. Run: bats device-ownership.bats

setup() {
  load test_helper
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPTS="$ROOT/skills/orchestrate/scripts"
  L="$BATS_TEST_TMPDIR/device.lock"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # adb stub: `adb -s SERIAL emu avd name` prints the AVD named in $BIN/avd-SERIAL, then OK.
  cat >"$BIN/adb" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/adb.calls"
[[ "\$1" == -s && "\$3 \$4 \$5" == "emu avd name" ]] || exit 1
f="$BIN/avd-\$2"
[[ -f "\$f" ]] || { echo "error: device '\$2' not found" >&2; exit 1; }
printf '%s\r\nOK\r\n' "\$(cat "\$f")"
EOF
  # xcrun stub: `xcrun simctl list devices` lists the UDIDs in $BIN/sims.
  cat >"$BIN/xcrun" <<EOF
#!/usr/bin/env bash
[[ "\$*" == "simctl list devices" ]] || exit 1
echo "== Devices =="
while read -r u; do echo "    iPhone 17 (\$u) (Booted)"; done <"$BIN/sims"
EOF
  chmod +x "$BIN/adb" "$BIN/xcrun"
  : >"$BIN/sims"
  export PATH="$BIN:$PATH"
  # spectra devices (#369): no simulator booted and adb's server not running until a test says
  # otherwise, so the adb and simctl stubs above decide.
  stub_spectra
}

# devices ANDROID_STATUS SERIALS SIM_STATUS UDIDS: what the spectra stub's `devices --json` lists
# (SERIALS and UDIDS space-separated).
devices() {
  jq -n --arg as "$1" --arg ad "$2" --arg ss "$3" --arg su "$4" '{os: "darwin",
    android: {status: $as, devices: [$ad | splits(" ") | select(. != "") | {serial: ., state: "device", emulator: true}]},
    ios_simulators: {status: $ss, booted: [$su | splits(" ") | select(. != "") | {udid: ., name: "iPhone 17", state: "Booted"}]}}' \
    >"$BATS_TEST_TMPDIR/spectra-devices.json"
}

lock() { "$SCRIPTS/device-lock.sh" "$@" --path "$L"; }
has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "claim records each --device; status shows them; old locks still read" {
  run lock claim --name lane-car --pid $$ --device emulator-5554 --device emulator-5556
  [ "$status" -eq 0 ]
  [ "$(sed -n 3p "$L")" = "devices=emulator-5554,emulator-5556" ]
  run lock status
  [[ "$output" == "held name=lane-car pid=$$ "*" live=yes devices=emulator-5554,emulator-5556" ]]
  echo "$$ 1000 old" >"$L"
  ORCHESTRATE_NOW=1100 run lock status
  [ "$output" = "held name=old pid=$$ age=100 live=yes" ]
}

@test "check passes only for the holder and its recorded device" {
  lock claim --name lane-a --pid $$ --device emulator-5554 >/dev/null
  run lock check --name lane-a --device emulator-5554
  [ "$status" -eq 0 ]
  [ "$output" = "owned emulator-5554 by lane-a" ]
  # Another lane's emulator: the incident in #68.
  run lock check --name lane-a --device emulator-5556
  [ "$status" -eq 4 ]
  [[ "$output" == "not owned: emulator-5556 is not a device of lane-a (recorded: emulator-5554)" ]]
  run lock check --name lane-b --device emulator-5554
  [ "$status" -eq 4 ]
  [[ "$output" == "not owned: the lock is held by lane-a" ]]
}

@test "check refuses with no lock, a stale lock, or a lock without devices" {
  run lock check --name lane-a --device emulator-5554
  [ "$status" -eq 4 ]
  [[ "$output" == "not owned: no live device lock"* ]]
  printf '999999 1000 lane-a\ntoken=t start=\ndevices=emulator-5554\n' >"$L"
  ORCHESTRATE_NOW=1100 run lock check --name lane-a --device emulator-5554
  [ "$status" -eq 4 ]
  [[ "$output" == "not owned: no live device lock"* ]]
  rm -f "$L"
  lock claim --name lane-a --pid $$ >/dev/null
  run lock check --name lane-a --device emulator-5554
  [ "$status" -eq 4 ]
  [[ "$output" == *"(recorded: none)" ]]
}

@test "check --avd compares the emulator's AVD name with the lane's suffix" {
  echo "Pixel_9_API_36_lane-a" >"$BIN/avd-emulator-5554"
  echo "Automotive_API_35_lane-b" >"$BIN/avd-emulator-5556"
  lock claim --name lane-a --pid $$ --device emulator-5554 --device emulator-5556 >/dev/null
  run lock check --name lane-a --device emulator-5554 --avd _lane-a
  [ "$status" -eq 0 ]
  grep -qx -- "-s emulator-5554 emu avd name" "$BATS_TEST_TMPDIR/adb.calls"
  # Recorded by mistake, but the emulator runs another lane's AVD.
  run lock check --name lane-a --device emulator-5556 --avd _lane-a
  [ "$status" -eq 4 ]
  [ "$output" = "not owned: emulator-5556 runs AVD Automotive_API_35_lane-b, not *_lane-a" ]
  rm "$BIN/avd-emulator-5554"
  run lock check --name lane-a --device emulator-5554 --avd _lane-a
  [ "$status" -eq 4 ]
  [ "$output" = "not owned: adb could not read the AVD name of emulator-5554" ]
}

@test "record adds a simulator UDID after the claim; check --simulator needs simctl to list it" {
  udid=0D3C1E2A-1111-4222-8333-944455556666
  out=$(lock claim --name lane-ios --pid $$)
  tok=$(echo "$out" | sed -n 's/^token //p')
  run lock record --token wrong --device "$udid"
  [ "$status" -eq 4 ]
  run lock record --token "$tok" --device "$udid"
  [ "$status" -eq 0 ]
  [ "$output" = "recorded $udid" ]
  run lock record --token "$tok" --device "$udid"
  [ "$output" = "recorded $udid" ]
  [[ "$(sed -n 2p "$L")" == "token=$tok start="* ]]
  [ "$(wc -l <"$L" | tr -d ' ')" -eq 3 ]
  run lock check --token "$tok" --device "$udid" --simulator
  [ "$status" -eq 4 ]
  [ "$output" = "not owned: simctl lists no simulator $udid" ]
  echo "$udid" >"$BIN/sims"
  run lock check --token "$tok" --device "$udid" --simulator
  [ "$status" -eq 0 ]
  run lock check --token wrong --device "$udid"
  [ "$status" -eq 4 ]
  # The token survives record, so release still works.
  run lock release --token "$tok"
  [ "$output" = released ]
}

@test "check --simulator: a simulator spectra lists as booted is present without simctl" {
  udid=0D3C1E2A-1111-4222-8333-944455556666
  lock claim --name lane-ios --pid $$ --device "$udid" >/dev/null
  printf '#!/usr/bin/env bash\ntouch "%s/xcrun.called"; exit 1\n' "$BATS_TEST_TMPDIR" >"$BIN/xcrun"   # simctl is not asked
  devices ok "" ok "AAAA0000-1111-4222-8333-944455556666 $udid"
  run lock check --name lane-ios --device "$udid" --simulator
  [ "$status" -eq 0 ]
  [ "$output" = "owned $udid by lane-ios" ]
  grep -qx 'devices --json' "$BATS_TEST_TMPDIR/spectra-calls"
  [ ! -e "$BATS_TEST_TMPDIR/xcrun.called" ]
}

@test "check --simulator: one spectra does not list as booted is looked up with simctl (spectra#704)" {
  udid=0D3C1E2A-1111-4222-8333-944455556666
  lock claim --name lane-ios --pid $$ --device "$udid" >/dev/null
  devices ok "" ok "AAAA0000-1111-4222-8333-944455556666"
  run lock check --name lane-ios --device "$udid" --simulator
  [ "$status" -eq 4 ]
  [ "$output" = "not owned: simctl lists no simulator $udid" ]
  echo "$udid" >"$BIN/sims"   # shut down, before simctl boot
  run lock check --name lane-ios --device "$udid" --simulator
  [ "$status" -eq 0 ]
  # simctl also decides when spectra could not ask it.
  : >"$BIN/sims"
  devices ok "" error "$udid"
  run lock check --name lane-ios --device "$udid" --simulator
  [ "$status" -eq 4 ]
  [ "$output" = "not owned: simctl lists no simulator $udid" ]
}

@test "check --avd: with adb's status ok, spectra must list the serial; the AVD name still comes from adb" {
  echo "Pixel_9_API_36_lane-a" >"$BIN/avd-emulator-5554"
  echo "Pixel_9_API_36_lane-a" >"$BIN/avd-emulator-5556"
  lock claim --name lane-a --pid $$ --device emulator-5554 --device emulator-5556 >/dev/null
  devices ok "emulator-5554" ok ""
  run lock check --name lane-a --device emulator-5554 --avd _lane-a
  [ "$status" -eq 0 ]
  [ "$output" = "owned emulator-5554 by lane-a" ]
  grep -qx -- "-s emulator-5554 emu avd name" "$BATS_TEST_TMPDIR/adb.calls"
  # Gone from adb's list: not owned, and adb is not asked.
  run lock check --name lane-a --device emulator-5556 --avd _lane-a
  [ "$status" -eq 4 ]
  [ "$output" = "not owned: spectra lists no Android device emulator-5556" ]
  [ "$(grep -c emulator-5556 "$BATS_TEST_TMPDIR/adb.calls" || true)" -eq 0 ]
  # Listed, but running another lane's AVD.
  devices ok "emulator-5554 emulator-5556" ok ""
  echo "Automotive_API_35_lane-b" >"$BIN/avd-emulator-5556"
  run lock check --name lane-a --device emulator-5556 --avd _lane-a
  [ "$status" -eq 4 ]
  [ "$output" = "not owned: emulator-5556 runs AVD Automotive_API_35_lane-b, not *_lane-a" ]
}

@test "check --avd: adb decides when spectra's adb status is not ok (server_not_running)" {
  echo "Pixel_9_API_36_lane-a" >"$BIN/avd-emulator-5554"
  lock claim --name lane-a --pid $$ --device emulator-5554 >/dev/null
  devices server_not_running "" ok ""
  run lock check --name lane-a --device emulator-5554 --avd _lane-a
  [ "$status" -eq 0 ]
  grep -qx -- "-s emulator-5554 emu avd name" "$BATS_TEST_TMPDIR/adb.calls"
  rm "$BIN/avd-emulator-5554"
  run lock check --name lane-a --device emulator-5554 --avd _lane-a
  [ "$status" -eq 4 ]
  [ "$output" = "not owned: adb could not read the AVD name of emulator-5554" ]
}

@test "check --avd or --simulator without spectra is not owned, with spectra's named error" {
  echo "Pixel_9_API_36_lane-a" >"$BIN/avd-emulator-5554"
  lock claim --name lane-a --pid $$ --device emulator-5554 >/dev/null
  rm "$BIN/spectra"
  run lock check --name lane-a --device emulator-5554 --avd _lane-a
  [ "$status" -eq 4 ]
  [[ "$output" == *"spectra: not found ($SPECTRA). waaagh requires it; install spectra 0.1.2 or newer:"* ]]
  [[ "$output" == *"not owned: spectra cannot list the host's devices" ]]
  [ ! -f "$BATS_TEST_TMPDIR/adb.calls" ]
  run lock check --name lane-a --device emulator-5554 --simulator
  [ "$status" -eq 4 ]
  # A plain check reads only the lock.
  run lock check --name lane-a --device emulator-5554
  [ "$status" -eq 0 ]
}

@test "bad device ids and incomplete check or record calls are usage errors" {
  run lock claim --name a --pid $$ --device 'emu 1'
  [ "$status" -eq 2 ]
  run lock check --device emulator-5554
  [ "$status" -eq 2 ]
  run lock check --name a --device a --device b
  [ "$status" -eq 2 ]
  run lock record --device a
  [ "$status" -eq 2 ]
  run "$SCRIPTS/device-lock.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check (--name WHO | --token T)"* ]]
  [[ "$output" == *"Never kills any process."* ]]
  [[ "$output" != *"set -euo pipefail"* ]]
}

@test "doctrine: one blocking wait per gate, device ownership, ready PRs, blockers before dispatch" {
  HYG="$ROOT/skills/orchestrate/subagent-hygiene.md"
  COMMON="$ROOT/skills/orchestrate/roles/_common.md"
  has "$HYG" "## Lanes on gates and devices"
  has "$HYG" "**One blocking wait per gate.**"
  has "$HYG" "until grep -q EXIT= <log>; do sleep 30; done"
  has "$HYG" "Never arm a repeating monitor"
  has "$HYG" "**Confirm device ownership before acting.**"
  has "$HYG" "device-lock.sh check"
  has "$HYG" "**Open PRs ready for review.**"
  has "$HYG" "**Check blockers before dispatch.**"
  has "$COMMON" "device-lock.sh check"
  has "$COMMON" "one blocking command"
  has "$ROOT/skills/orchestrate/SKILL.md" "**Lanes wait once and own their devices**"
  has "$ROOT/skills/orchestrate/SKILL.md" "Missing device evidence is no reason for a draft"
  has "$ROOT/skills/orchestrate/roles/verify-batch.md" "--device <serial or UDID>"
  has "$ROOT/skills/orchestrate/roles/verification.md" "--device <serial or UDID>"
}
