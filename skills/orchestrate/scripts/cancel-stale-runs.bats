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
  "api --paginate") case "$3" in repos/o/r/issues/*/events*) n=${3#repos/o/r/issues/}; n=${n%%/*}; echo "events $n" >>"$FX/order"
      [ ! -f "$FX/events-fail" ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }; cat "$FX/events-$n" 2>/dev/null; exit 0 ;; esac
    [ ! -f "$FX/prs-fail" ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    echo "heads-read" >>"$FX/order"; cat "$FX/heads" ;;
  "api repos/o/r/pulls?state=closed"*) pg=${2##*page=}
    [ ! -f "$FX/closed-fail-$pg" ] || exit 1
    if [ -f "$FX/closed-p$pg" ]; then cat "$FX/closed-p$pg"; elif [ "$pg" = 1 ]; then cat "$FX/closed" 2>/dev/null || true; fi ;;
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
  printf 'done/3 eeee5555\t2026-11-26T10:00:00Z\t7\t2026-11-26T10:00:00Z\n' >"$FX/closed"   # PR closed at 10:00
  csr
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "would cancel 107 Test done/3 eeee5555" ]   # from before the close: stale
  [ "${lines[3]}" = "stale=3 kept=4 cancelled=0 failed=0" ]      # 106, after the close: kept
  [ "$(grep -v '^events' "$FX/order" | tail -n 1)" = heads-read ]
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

# The closed list as the --jq output: "branch sha<TAB>closed_at<TAB>number<TAB>updated_at".
full_page() { # <first number> <updated_at>: 100 unrelated closed PRs
  local i; for i in $(seq "$1" $(($1 + 99))); do printf 'x/%s xxxx%s\t2026-11-26T12:00:00Z\t%s\t%s\n' "$i" "$i" "$i" "$2"; done
}

@test "#426: a closed PR on page 2 is found; its close run is kept" {
  printf '110\tpull_request\tdone/4\tffff6666\tTeardown\t2026-11-26T10:05:00Z\n' >"$FX/runs-pending"
  full_page 200 2026-11-26T11:00:00Z >"$FX/closed-p1"
  printf 'done/4 ffff6666\t2026-11-26T10:00:00Z\t9\t2026-11-26T10:00:00Z\n' >"$FX/closed-p2"
  csr --apply
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "stale=2 kept=4 cancelled=2 failed=0" ]   # 102, 104 stale; 110 kept
  [ "$(grep -cx 110 "$FX/cancelled" || true)" -eq 0 ]
  grep -q 'page=2' "$FX/calls"
  [ "$(grep -c 'page=3' "$FX/calls" || true)" -eq 0 ]
}

@test "#426 review: paging stops an hour before the oldest run, not at it" {
  # The oldest candidate starts at 10:00. done/5 closed at 09:59:56, so its close run (10:00) is
  # newer than the close, but the PR's updated_at is older than the run: page 2 must still be read.
  printf '111\tpull_request\tdone/5\tabab7777\tTeardown\t2026-11-26T10:00:00Z\n' >"$FX/runs-pending"
  full_page 200 2026-11-26T09:59:58Z >"$FX/closed-p1"
  printf 'done/5 abab7777\t2026-11-26T09:59:56Z\t11\t2026-11-26T09:59:56Z\n' >"$FX/closed-p2"
  csr --apply
  [ "$status" -eq 0 ]
  [ "$(grep -cx 111 "$FX/cancelled" || true)" -eq 0 ]
  grep -q 'page=2' "$FX/calls"
  # A page whose oldest update is more than an hour before the oldest run ends the read.
  rm -f "$FX/calls" "$FX/cancelled"
  full_page 200 2026-11-26T08:00:00Z >"$FX/closed-p1"
  csr
  [ "$status" -eq 0 ]
  [ "$(grep -c 'page=2' "$FX/calls" || true)" -eq 0 ]
}

@test "#426: closed, reopened, closed again: a run for the first close is kept" {
  printf '111\tpull_request\tdone/5\tgggg7777\tTeardown\t2026-11-26T10:05:00Z\n' >"$FX/runs-pending"
  printf 'done/5 gggg7777\t2026-11-26T11:00:00Z\t12\t2026-11-26T11:00:00Z\n' >"$FX/closed"
  printf '2026-11-26T10:00:00Z\n2026-11-26T11:00:00Z\n' >"$FX/events-12"
  csr
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "stale=2 kept=4 cancelled=0 failed=0" ]
  [ "$(grep -c '^events 12' "$FX/order")" -eq 1 ]
}

@test "#426: an unreadable events read keeps the run" {
  printf '111\tpull_request\tdone/5\tgggg7777\tTeardown\t2026-11-26T10:05:00Z\n' >"$FX/runs-pending"
  printf 'done/5 gggg7777\t2026-11-26T11:00:00Z\t12\t2026-11-26T11:00:00Z\n' >"$FX/closed"
  touch "$FX/events-fail"
  csr --apply
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "stale=2 kept=4 cancelled=2 failed=0" ]
  [ "$(grep -cx 111 "$FX/cancelled" || true)" -eq 0 ]
}

@test "#426: pages that never reach the oldest run exit 3 with nothing cancelled" {
  for p in $(seq 1 20); do full_page $((p * 1000)) 2026-11-26T11:00:00Z >"$FX/closed-p$p"; done
  csr --apply
  [ "$status" -eq 3 ]
  [ ! -e "$FX/cancelled" ]
  [ "$(grep -c 'state=closed' "$FX/calls")" -eq 20 ]
  rm "$FX/closed-p20"; touch "$FX/closed-fail-3"
  csr --apply
  [ "$status" -eq 3 ]
  [ ! -e "$FX/cancelled" ]
}

@test "#426 pin: runs from before every close are still cancelled; events are read only for them" {
  printf '112\tpull_request\tdone/6\thhhh8888\tTest\t2026-11-26T09:00:00Z\n' >"$FX/runs-pending"
  printf 'done/6 hhhh8888\t2026-11-26T11:00:00Z\t13\t2026-11-26T11:00:00Z\n' >"$FX/closed"
  printf '2026-11-26T10:00:00Z\n2026-11-26T11:00:00Z\n' >"$FX/events-13"
  csr --apply
  [ "$status" -eq 0 ]
  grep -qx 112 "$FX/cancelled"
  [ "$(grep -c '^events' "$FX/order")" -eq 1 ]
  # No closed head involved: no events read at all.
  rm "$FX/order" "$FX/cancelled" "$FX/runs-pending"
  csr --apply
  [ "$status" -eq 0 ]
  [ "$(grep -c '^events' "$FX/order" || true)" -eq 0 ]
}
