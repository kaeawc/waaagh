#!/usr/bin/env bats
# host-load.sh paths host-budget.bats does not reach (#330): what it asks spectra (thresholds,
# root, table size), memory spectra could not read, the memory thresholds set by flag, and a
# spectra that is missing, fails or answers something that is not a load reading. Spectra is the
# test_helper.bash stub. Run: bats scripts/host-load-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  stub_spectra
  export SPECTRA_STUB_CPUS=4 SPECTRA_STUB_LOAD1=1
  unset ORCHESTRATE_WORKTREE_ROOT
  cd "$BATS_TEST_TMPDIR"   # outside any checkout: no default worktree root
}

row() { printf '%s\n' "$output" | awk -F'\t' -v k="$1" '$1 == k { sub("^[^\t]*\t", ""); print; exit }'; }
calls() { cat "$BATS_TEST_TMPDIR/spectra-calls"; }

@test "spectra is asked for the thresholds, the root and the table size; --top 0 still reads the load" {
  R="$BATS_TEST_TMPDIR/wt"; mkdir -p "$R"
  run "$SCRIPTS/host-load.sh" --worktree-root "$R" --top 3 --load-factor 2 --min-free-gb 6 --backoff-gb 2
  [ "$status" -eq 0 ]
  [ "$(grep '^load ' "$BATS_TEST_TMPDIR/spectra-calls")" = "load --json --top 3 --max-load-per-cpu 2 --min-free-gb 6 --backoff-free-gb 2 --root $(cd "$R" && pwd -P)" ]
  : >"$BATS_TEST_TMPDIR/spectra-calls"
  run "$SCRIPTS/host-load.sh" --top 0
  [ "$status" -eq 0 ]
  [ "$(grep '^load ' "$BATS_TEST_TMPDIR/spectra-calls")" = "load --json --top 1 --max-load-per-cpu 1.5 --min-free-gb 8 --backoff-free-gb 4" ]
  [ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = "verdict load memory device-slots " ]
}

@test "memory thresholds follow the flags; memory spectra could not read holds nothing" {
  SPECTRA_STUB_FREE_GB=7.04 run "$SCRIPTS/host-load.sh" --top 0
  [ "$status" -eq 3 ]
  [ "$(row memory)" = $'7.0\tmin 8, backoff 4' ]
  [ "$(row verdict)" = $'HOLD\tfree memory 7.0 GB < 8 GB' ]
  SPECTRA_STUB_FREE_GB=7.04 run "$SCRIPTS/host-load.sh" --top 0 --min-free-gb 6 --backoff-gb 2 --third-slot-gb 7
  [ "$status" -eq 0 ]
  [ "$(row memory)" = $'7.0\tmin 6, backoff 2' ]
  [ "$(row device-slots)" = 3 ]
  SPECTRA_STUB_FREE_GB=7.04 run "$SCRIPTS/host-load.sh" --top 0 --backoff-gb 7.5
  [ "$status" -eq 4 ]
  [[ "$(row verdict)" == BACKOFF* ]]
  SPECTRA_STUB_FREE_GB=null run "$SCRIPTS/host-load.sh" --top 0
  [ "$status" -eq 0 ]
  [ "$(row memory)" = $'unknown\tmin 8, backoff 4' ]
  [ "$(row device-slots)" = 2 ]
  SPECTRA_STUB_FREE_GB=null SPECTRA_STUB_LOAD1=6 run "$SCRIPTS/host-load.sh" --top 0
  [ "$status" -eq 3 ]
  [[ "$(row verdict)" == $'HOLD\t1-min load 6 >= 6.00'* ]]
}

@test "a missing, failing or garbled spectra is exit 5 with the reason, never a verdict" {
  SPECTRA="$BATS_TEST_TMPDIR/none" run "$SCRIPTS/host-load.sh"
  [ "$status" -eq 5 ]
  [[ "$output" == "spectra: not found ($BATS_TEST_TMPDIR/none). waaagh requires it"* ]]
  SPECTRA_STUB_FAIL=1 run "$SCRIPTS/host-load.sh"
  [ "$status" -eq 5 ]
  [[ "$output" == "host-load.sh: spectra load gave no reading: "* ]]
  echo '{"load1": "high", "cpus": 4}' >"$BATS_TEST_TMPDIR/spectra-load.json"
  run "$SCRIPTS/host-load.sh"
  [ "$status" -eq 5 ]
  echo '{"cpus": 0}' >"$BATS_TEST_TMPDIR/spectra-load.json"
  run "$SCRIPTS/host-load.sh"
  [ "$status" -eq 5 ]
  [[ "$output" != *$'verdict\t'* ]]
}

@test "an idle host: cause idle, and no tables when spectra lists no processes" {
  run "$SCRIPTS/host-load.sh"
  [ "$status" -eq 0 ]
  [ "$(row cause)" = $'idle\thost is idle' ]
  [ "$(row hint)" = "nothing leads the CPU table: the load is falling or brief" ]
  [ "$(printf '%s\n' "$output" | grep -c '^top-\|^family' || true)" -eq 0 ]
}

@test "device rows come from spectra's devices block, even with --top 0; none when spectra has none (#334)" {
  run "$SCRIPTS/host-load.sh" --top 0
  [[ "$output" != *devices* ]]
  echo '{"devices": {"simulators": 2, "emulators": 1, "booted": 3, "booted_recently": 2, "boot_window_seconds": 300,
    "by_root": [{"root": "/wt/lane-a", "booted": 1, "booted_recently": 1}], "list": []}}' >"$BATS_TEST_TMPDIR/spectra-load.json"
  run "$SCRIPTS/host-load.sh" --top 0
  [ "$status" -eq 0 ]
  [ "$(row devices)" = $'3\t2\t300' ]
  [ "$(row devices-root)" = $'/wt/lane-a\t1\t1' ]
}
