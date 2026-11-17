#!/usr/bin/env bats
# failure-triage.sh and a package-mirror outage (#217): an install step that could not reach its
# public mirror is infrastructure (rerun, not a code fix), and several PRs hitting it within the
# hour read as one outage.
# Run: bats scripts/failure-triage-mirror.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX"
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  printf 'Err:1 http://azure.archive.ubuntu.com/ubuntu jammy InRelease\n  Temporary failure resolving azure.archive.ubuntu.com\nE: Failed to fetch http://azure.archive.ubuntu.com/ubuntu/dists/jammy/InRelease\n' >"$FX/apt.log"
  printf 'FAIL src/a.test.ts\n  expected 2, got 3\n' >"$FX/real.log"
}

ft() { "$SCRIPTS/failure-triage.sh" "$1" --repo o/r "${@:2}"; }
decide() { ft decide --pr "$1" --head "${HEAD:0:9}" --check xml --log "$FX/apt.log" --verdict unknown "${@:2}"; }

@test "mirror recognises apt fetch errors and nothing else" {
  run ft mirror --check xml --log "$FX/apt.log"
  [ "$status" -eq 0 ]
  [ "$output" = "mirror apt" ]
  run ft mirror --check xml --log "$FX/real.log"
  [ "$status" -eq 1 ]
  [ "$output" = none ]
}

@test "each apt signature, and the other mirrors, are recognised" {
  for line in 'E: Failed to fetch http://x/y  Hash Sum mismatch' 'E: Could not get lock /var/lib/dpkg/lock-frontend' \
    'Unable to connect to archive.ubuntu.com:80' 'E: Some index files failed to download.' 'Hash Sum mismatch'; do
    printf '%s\n' "$line" >"$FX/l.log"
    run ft mirror --check xml --log "$FX/l.log"
    [ "$output" = "mirror apt" ]
  done
  printf 'WARNING: Retrying (Retry(total=4)) Read timed out. (read timeout=15) pypi.org\n' >"$FX/l.log"
  run ft mirror --check xml --log "$FX/l.log"
  [ "$output" = "mirror pip" ]
  printf 'npm ERR! code ETIMEDOUT\n' >"$FX/l.log"
  run ft mirror --check xml --log "$FX/l.log"
  [ "$output" = "mirror npm" ]
  printf 'Could not transfer artifact org.x:y:pom:1 from/to central\n' >"$FX/l.log"
  run ft mirror --check xml --log "$FX/l.log"
  [ "$output" = "mirror maven" ]
}

@test "decide: a mirror failure with an unknown verdict is rerun once, then the install path is the fix" {
  run decide 5
  [ "$status" -eq 0 ]
  [ "$output" = "rerun mirror-outage mirror=apt" ]
  printf '%s\tpr=5\thead=%s\tcheck=xml\trun=77\trerun-requested\n' "$(date -u +%FT%TZ)" "$HEAD" >"$ST/pr-reruns.tsv"
  run decide 5
  [ "$output" = "triage mirror-outage-persists mirror=apt rerun=77" ]
}

@test "decide: a real failure is untouched and logs no mirror hit" {
  run ft decide --pr 5 --head "${HEAD:0:9}" --check xml --log "$FX/real.log" --verdict test-failure
  [ "$output" = "triage classified verdict=test-failure" ]
  [ ! -f "$ST/mirror-hits.tsv" ]
}

@test "several PRs failing on the mirror read as one outage" {
  run ft outage
  [ "$output" = "mirror-outage ok prs=- hits=0 window=3600" ]
  run decide 5
  [ "$output" = "rerun mirror-outage mirror=apt" ]
  run decide 5
  [ "$(grep -c . "$ST/mirror-hits.tsv")" -eq 1 ]
  run decide 6
  [ "$output" = "rerun mirror-outage mirror=apt pool=suspect prs=6,5" ]
  run ft outage
  [ "$output" = "mirror-outage suspect prs=5,6 hits=2 window=3600" ]
  run ft outage --min 3
  [[ "$output" == "mirror-outage ok prs=5,6 "* ]]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 7200)) run ft outage
  [ "$output" = "mirror-outage ok prs=- hits=0 window=3600" ]
}

@test "mirror and outage reject bad arguments" {
  run ft mirror --check xml
  [ "$status" -eq 2 ]
  run ft outage --min 0
  [ "$status" -eq 2 ]
}
