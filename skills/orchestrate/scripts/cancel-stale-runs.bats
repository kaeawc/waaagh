#!/usr/bin/env bats
# cancel-stale-runs.sh (#413): unfinished pull-request runs for heads no open PR points at.
# Stubbed gh. Run: bats cancel-stale-runs.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_READ_SLEEP=0
  # Open PRs: $FX/heads ("branch sha" lines, the --jq output). Runs: $FX/runs-<status> (TSV, the
  # --jq output). $FX/cancel-fail-<id>: that cancel fails. $FX/prs-fail: the PR list fails.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"; set -- ${all% --include}   # gh-read.sh adds --include to api reads
echo "$*" >>"$FX/calls"
case "$1 $2" in
  "api --paginate") [ ! -f "$FX/prs-fail" ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    echo "heads-read" >>"$FX/order"; cat "$FX/heads" ;;
  "api repos/o/r/pulls?state=closed"*) cat "$FX/closed" 2>/dev/null || true ;;
  "api repos/o/r/actions/runs?status="*) st=${2#*status=}; st=${st%%&*}; echo "runs-read" >>"$FX/order"; cat "$FX/runs-$st" 2>/dev/null || true ;;
  "run cancel") [ ! -f "$FX/cancel-fail-$3" ] || exit 1; echo "$3" >>"$FX/cancelled" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  printf 'work/1 aaaa1111\nwork/2 bbbb2222\n' >"$FX/heads"
  T=2026-11-26T10:00:00Z
  printf '101\tpull_request\twork/1\taaaa1111\tTest\t%s\n102\tpull_request\twork/1\toldold00\tTest\t%s\n103\tpush\tmain\tcccc3333\tTest\t%s\n' $T $T $T >"$FX/runs-queued"
  printf '104\tpull_request\tgone\tdddd4444\tCoverage\t%s\n102\tpull_request\twork/1\toldold00\tTest\t%s\n' $T $T >"$FX/runs-in_progress"
  printf '105\tpull_request_target\twork/2\tbbbb2222\tLabel\t%s\n' $T >"$FX/runs-waiting"
}
csr() { run "$SCRIPTS/cancel-stale-runs.sh" --repo o/r "$@"; }

@test "a dry run lists runs for superseded or closed heads and keeps the rest" {
  csr
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "would cancel 102 Test work/1 oldold00" ]
  [ "${lines[1]}" = "would cancel 104 Coverage gone dddd4444" ]
  [ "${lines[2]}" = "stale=2 kept=3 cancelled=0 failed=0" ]
  [ ! -e "$FX/cancelled" ]
}

@test "--apply cancels each stale run once and counts a failed cancel" {
  touch "$FX/cancel-fail-104"
  csr --apply
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "cancelled 102 Test work/1 oldold00" ]
  [ "${lines[1]}" = "cancel failed 104 Coverage gone dddd4444" ]
  [ "${lines[2]}" = "stale=2 kept=3 cancelled=1 failed=1" ]
  [ "$(cat "$FX/cancelled")" = 102 ]
}

@test "review #425: runs are read before heads; a run for a PR's close is kept" {
  printf '106\tpull_request\tdone/3\teeee5555\tTeardown\t2026-11-26T10:05:00Z\n107\tpull_request\tdone/3\teeee5555\tTest\t2026-11-26T09:00:00Z\n' >"$FX/runs-pending"
  printf 'done/3 eeee5555\t2026-11-26T10:00:00Z\n' >"$FX/closed"   # PR closed at 10:00
  csr
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "would cancel 107 Test done/3 eeee5555" ]   # from before the close: stale
  [ "${lines[3]}" = "stale=3 kept=4 cancelled=0 failed=0" ]      # 106, after the close: kept
  [ "$(tail -n 1 "$FX/order")" = heads-read ]
  [ "$(grep -c runs-read "$FX/order")" -eq 5 ]
}

@test "an unreadable PR list cancels nothing (exit 3); usage errors are exit 2" {
  touch "$FX/prs-fail"
  csr --apply
  [ "$status" -eq 3 ]
  [ ! -e "$FX/cancelled" ]
  csr --limit 0
  [ "$status" -eq 2 ]
  csr --limit 101
  [ "$status" -eq 2 ]
  csr --bogus
  [ "$status" -eq 2 ]
}
