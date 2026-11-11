#!/usr/bin/env bats
# failure-triage.sh and a needs dependency that did not succeed (#207): the `needs.<job>.result`
# signature is told apart from a real failure, re-run in full (`gh run rerun ID`, not `--failed`),
# and several PRs hitting it within the hour flag the runner pool.
# Run: bats scripts/failure-triage-needs.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SKILL="$SCRIPTS/.."
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  stub_gh_routes
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  jq -n --arg h "$HEAD" '{headRefOid: $h}' >"$FX/pr5.json"
  jq -n '{headRefOid: "1111111111111111111111111111111111111111"}' >"$FX/pr6.json"
  gh_route "pr view 5 *" pr5.json
  gh_route "pr view 6 *" pr6.json
  gh_routes <<'R'
case "$a" in
  "run rerun"*) [ ! -f "$FX/rerun-fails" ] || { echo "HTTP 403: cannot rerun" >&2; exit 1; }; echo ok; exit 0 ;;
esac
R
  printf 'Run test "$DETECT" = success\nerror: needs.detect.result is abandoned, expected success\n##[error]Process completed with exit code 1.\n' >"$FX/abandoned.log"
  printf 'FAIL src/a.test.ts\n  expected 2, got 3\n' >"$FX/real.log"
}

ft() { "$SCRIPTS/failure-triage.sh" "$1" --repo o/r "${@:2}"; }
decide() { ft decide --pr 5 --head "${HEAD:0:9}" --check gate "$@"; }

@test "an abandoned needs dependency is classified apart from a real failure, before any verdict" {
  run decide --log "$FX/abandoned.log" --verdict test-failure --file a.ts
  [ "$status" -eq 0 ]
  [ "$output" = "rerun-full needs-not-success needs=detect result=abandoned" ]
  run decide --log "$FX/real.log" --verdict test-failure --file a.ts
  [ "$output" = "triage classified verdict=test-failure" ]
  # cancelled / canceled / skipped, any case and separator
  printf 'needs.build-linux.result == "Canceled"\n' >"$FX/c.log"
  run ft decide --pr 5 --head "$HEAD" --check other --log "$FX/c.log" --file a.ts
  [ "$output" = "rerun-full needs-not-success needs=build-linux result=cancelled" ]
  printf 'needs.detect.result: skipped\n' >"$FX/s.log"
  run ft decide --pr 5 --head "$HEAD" --check third --log "$FX/s.log" --file a.ts
  [ "$output" = "rerun-full needs-not-success needs=detect result=skipped" ]
  # a `!=` comparison and a success result are not the signature
  printf 'if needs.detect.result != skipped\nneeds.detect.result=success\n' >"$FX/n.log"
  run ft decide --pr 5 --head "$HEAD" --check fourth --log "$FX/n.log" --verdict flake
  [ "$output" = "rerun classified verdict=flake" ]
  [ ! -f "$FX/calls" ]
}

@test "rerun --full re-runs every job, once per head, even after a failed-jobs rerun" {
  run ft rerun --pr 5 --head "${HEAD:0:9}" --check gate --run 77
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'run rerun 77 --failed --repo o/r' "$FX/calls")" -eq 1 ]
  # the failed-jobs rerun read the same abandoned result: a full rerun is still the answer
  run decide --log "$FX/abandoned.log"
  [ "$output" = "rerun-full needs-not-success needs=detect result=abandoned rerun=77" ]
  run ft rerun --pr 5 --head "${HEAD:0:9}" --check gate --run 77 --full --reason needs-not-success
  [ "$status" -eq 0 ]
  [ "$output" = "rerun requested (full): run 77 (gate) on PR 5 head abcdef123; every job runs again, the needs dependency included" ]
  [ "$(grep -cx 'run rerun 77 --repo o/r' "$FX/calls")" -eq 1 ]
  grep -q "check=gate	run=77	full-rerun-requested" "$ST/pr-reruns.tsv"
  run ft rerun --pr 5 --head "$HEAD" --check gate --run 77 --full
  [ "$status" -eq 3 ]
  [[ "$output" == "refused: "*"re-run in full"* ]]
  run ft rerun --pr 5 --head "$HEAD" --check gate --run 77
  [ "$status" -eq 3 ]
  [ "$(grep -c '^run rerun' "$FX/calls")" -eq 2 ]
  # still abandoned after the full rerun: the runner pool, not the code
  run decide --log "$FX/abandoned.log"
  [ "$output" = "triage runner-pool needs=detect result=abandoned rerun=77" ]
}

@test "a refused full rerun is logged and may be tried again" {
  touch "$FX/rerun-fails"
  run ft rerun --pr 5 --head "$HEAD" --check gate --run 77 --full
  [ "$status" -eq 5 ]
  grep -q 'full-failed: HTTP 403' "$ST/pr-reruns.tsv"
  run decide --log "$FX/abandoned.log"
  [ "$output" = "rerun-full needs-not-success needs=detect result=abandoned" ]
  rm "$FX/rerun-fails"
  run ft rerun --pr 5 --head "$HEAD" --check gate --run 77 --full
  [ "$status" -eq 0 ]
}

@test "several PRs hitting it within the hour flag the runner pool" {
  run ft pool
  [ "$output" = "runner-pool ok prs=- hits=0 window=3600" ]
  run decide --log "$FX/abandoned.log"
  [ "$output" = "rerun-full needs-not-success needs=detect result=abandoned" ]
  # the same PR, head and check twice is one hit
  run decide --log "$FX/abandoned.log"
  [ "$(wc -l <"$ST/needs-hits.tsv")" -eq 1 ]
  run ft pool
  [ "$output" = "runner-pool ok prs=5 hits=1 window=3600" ]
  run ft decide --pr 6 --head 1111111 --check gate --log "$FX/abandoned.log"
  [ "$output" = "rerun-full needs-not-success needs=detect result=abandoned pool=suspect prs=6,5" ]
  run ft pool
  [ "$output" = "runner-pool suspect prs=5,6 hits=2 window=3600" ]
  run ft pool --min 3
  [[ "$output" == "runner-pool ok "* ]]
  # an hour later the old hits no longer count
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 3601)) run ft pool
  [ "$output" = "runner-pool ok prs=- hits=0 window=3600" ]
  run ft pool --window x
  [ "$status" -eq 2 ]
}

@test "a recorded needs-dependency signature teaches the repository's own wording" {
  printf 'Run test abandoned = success\n' >"$FX/own.log"
  run decide --log "$FX/own.log" --file a.ts
  [ "$output" = "triage no-domain" ]
  run ft record --check gate --pattern 'test (abandoned|cancelled|skipped) = success' --note "needs-dependency: detect gate"
  [ "$output" = sig-1 ]
  run decide --log "$FX/own.log" --file a.ts
  [ "$output" = "rerun-full needs-not-success needs=? result=?" ]
  # another recorded signature is still an ordinary known signature
  run ft record --check gate --pattern 'expected 2' --note "flaky counter"
  run decide --log "$FX/real.log" --file a.ts
  [ "$output" = "rerun known-signature id=sig-2" ]
}

@test "doctrine: full rerun for a needs dependency and the runner-pool check" {
  grep -q 'rerun-full' "$SKILL/failure-triage.md"
  grep -q -- '--full' "$SKILL/failure-triage.md"
  grep -qi 'runner pool' "$SKILL/failure-triage.md"
  grep -q 'rerun-full' "$SKILL/roles/pr-doctor.md"
  grep -q -- 'rerun --full' "$SKILL/roles/pr-doctor.md"
}
