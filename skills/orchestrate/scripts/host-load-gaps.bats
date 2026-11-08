#!/usr/bin/env bats
# host-load.sh paths host-budget.bats does not reach: free memory read from vm_stat (macOS), the
# memory thresholds set by flag, and no process table (ps fails). Stubbed vm_stat and ps on PATH.
# Run: bats scripts/host-load-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH" ORCHESTRATE_HOST_CPUS=4 ORCHESTRATE_HOST_LOAD1=1
  unset ORCHESTRATE_HOST_FREE_MB ORCHESTRATE_WORKTREE_ROOT
}

row() { printf '%s\n' "$output" | awk -F'\t' -v k="$1" '$1 == k { sub("^[^\t]*\t", ""); print; exit }'; }

@test "free memory comes from vm_stat's free, inactive and speculative pages; thresholds follow the flags" {
  # 16384-byte pages: (262144 + 131072 + 65536) pages = 7 GiB.
  cat >"$BIN/vm_stat" <<'EOF'
#!/bin/sh
cat <<'OUT'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              262144.
Pages active:                            999999.
Pages inactive:                          131072.
Pages speculative:                        65536.
OUT
EOF
  chmod +x "$BIN/vm_stat"
  run "$SCRIPTS/host-load.sh" --top 0
  [ "$status" -eq 3 ]
  [ "$(row memory)" = $'7.0\tmin 8, backoff 4' ]
  [ "$(row verdict)" = $'HOLD\tfree memory 7.0 GB < 8 GB' ]
  run "$SCRIPTS/host-load.sh" --top 0 --min-free-gb 6 --backoff-gb 2 --third-slot-gb 7
  [ "$status" -eq 0 ]
  [ "$(row memory)" = $'7.0\tmin 6, backoff 2' ]
  [ "$(row device-slots)" = 3 ]
  run "$SCRIPTS/host-load.sh" --top 0 --backoff-gb 7.5
  [ "$status" -eq 4 ]
  [[ "$(row verdict)" == BACKOFF* ]]
}

@test "no process table: the cause is unknown and the hint says to check by hand" {
  printf '#!/bin/sh\nexit 1\n' >"$BIN/ps"; chmod +x "$BIN/ps"
  ORCHESTRATE_HOST_FREE_MB=20480 run "$SCRIPTS/host-load.sh"
  [ "$status" -eq 0 ]
  [ "$(row cause)" = $'-\tno processes read' ]
  [ "$(row hint)" = "no process table: check with uptime and top by hand" ]
  [ "$(printf '%s\n' "$output" | grep -c '^top-' || true)" -eq 0 ]
}
