#!/usr/bin/env bats
# failure-triage.sh against a stubbed gh: rerun first when a failing check's domain misses the diff,
# reproduce only on a second failure of the same check on the same head, recorded signatures, and
# the doctrine pointers (failure-triage.md, pr-doctor, cloud brief).
# Run: bats scripts/failure-triage.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SKILL="$SCRIPTS/.."
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  echo "$HEAD" >"$FX/head"
  printf 'gradle/libs.versions.toml\n' >"$FX/files"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
case "$all" in
  "api --paginate repos/o/r/pulls/5/files"*) [ ! -f "$FX/files-fail" ] || { echo "HTTP 404" >&2; exit 1; }; cat "$FX/files" ;;
  "pr view 5 "*) jq -n --arg h "$(cat "$FX/head")" '{headRefOid: $h}' ;;
  "run rerun"*) [ ! -f "$FX/rerun-fails" ] || { echo "HTTP 403: cannot rerun" >&2; exit 1; }; echo ok ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  printf '# check => paths\nlint* => *.ts *.tsx package.json .oxlintrc.json\nandroid* => android/ gradle/ *.gradle.kts\n' >"$ST/check-domains"
}

ft() { "$SCRIPTS/failure-triage.sh" "$1" --repo o/r "${@:2}"; }
decide() { ft decide --pr 5 --head "${HEAD:0:9}" "$@"; }

@test "an unknown failure in a check whose domain misses the diff is re-run first" {
  run decide --check "lint / oxlint" --verdict UNKNOWN
  [ "$status" -eq 0 ]
  [ "$output" = "rerun disjoint files=1 domain=*.ts,*.tsx,package.json,.oxlintrc.json" ]
  grep -q 'api --paginate repos/o/r/pulls/5/files' "$FX/calls"
}

@test "a domain that intersects the diff, no domain, or a classifier verdict means ordinary triage" {
  run decide --check "android / unit" --verdict unknown
  [ "$output" = "triage intersects path=gradle/libs.versions.toml pattern=gradle/" ]
  run decide --check "e2e" --file src/a.ts
  [ "$output" = "triage no-domain" ]
  run decide --check "lint / oxlint" --verdict INVESTIGATE --file a.toml
  [ "$output" = "triage classified verdict=investigate" ]
  # --file skips the GitHub read
  rm -f "$FX/calls"
  run decide --check "lint" --file web/app.ts
  [ "$output" = "triage intersects path=web/app.ts pattern=*.ts" ]
  [ ! -f "$FX/calls" ]
}

@test "known flake and infra verdicts are re-run once whatever the domain" {
  run decide --check "android / unit" --verdict KNOWN_FLAKE
  [ "$output" = "rerun classified verdict=known-flake" ]
  run decide --check "android / unit" --verdict infra
  [ "$output" = "rerun classified verdict=infra" ]
}

@test "rerun re-runs once per PR, head and check; a second failure on that head is reproduced" {
  run ft rerun --pr 5 --head "${HEAD:0:9}" --check "lint / oxlint" --run 77 --reason disjoint
  [ "$status" -eq 0 ]
  [[ "$output" == "rerun requested: run 77 (lint / oxlint) on PR 5 head abcdef123; if it fails again, reproduce" ]]
  grep -qx 'run rerun 77 --failed --repo o/r' "$FX/calls"
  grep -q "pr=5	head=$HEAD	check=lint / oxlint	run=77	rerun-requested" "$ST/pr-reruns.tsv"

  run ft rerun --pr 5 --head "$HEAD" --check "lint / oxlint" --run 78
  [ "$status" -eq 3 ]
  [[ "$output" == refused:* ]]
  [ "$(grep -c '^run rerun' "$FX/calls")" -eq 1 ]

  run decide --check "lint / oxlint" --verdict unknown
  [ "$output" = "reproduce second-failure rerun=77" ]
  run decide --check "lint / oxlint" --verdict flake
  [ "$output" = "reproduce second-failure verdict=flake rerun=77" ]
  # another check, or a new head, starts over
  run decide --check "lint / tsc" --file a.toml
  [ "$output" = "rerun disjoint files=1 domain=*.ts,*.tsx,package.json,.oxlintrc.json" ]
  run ft decide --pr 5 --head 1234567 --check "lint / oxlint" --file a.toml
  [[ "$output" == "rerun disjoint"* ]]
}

@test "rerun refuses a moved head; a refused rerun is logged and may be tried again" {
  echo 9999999999999999999999999999999999999999 >"$FX/head"
  run ft rerun --pr 5 --head "${HEAD:0:9}" --check lint --run 77
  [ "$status" -eq 4 ]
  [[ "$output" == stale:* ]]
  run ! grep -q '^run rerun' "$FX/calls"

  echo "$HEAD" >"$FX/head"; touch "$FX/rerun-fails"
  run ft rerun --pr 5 --head "${HEAD:0:9}" --check lint --run 77
  [ "$status" -eq 5 ]
  grep -q 'failed: HTTP 403' "$ST/pr-reruns.tsv"
  run decide --check lint --file a.toml
  [[ "$output" == "rerun disjoint"* ]]
  rm "$FX/rerun-fails"
  run ft rerun --pr 5 --head "${HEAD:0:9}" --check lint --run 77
  [ "$status" -eq 0 ]
}

@test "a recorded signature classifies the next occurrence" {
  printf 'step 3\nError: oxlint did not emit parseable JSON\n' >"$FX/log"
  run ft match --check "lint / oxlint" --log "$FX/log"
  [ "$status" -eq 1 ]
  run ft record --check "lint*" --pattern 'oxlint did not emit parseable JSON' --note "oxlint JSON flake" --source "PR 5 run 77"
  [ "$status" -eq 0 ] && [ "$output" = sig-1 ]
  run ft record --check "lint*" --pattern 'oxlint did not emit parseable JSON' --note dup
  [ "$status" -eq 3 ] && [ "$output" = "refused: already recorded as sig-1" ]
  run ft record --check "e2e" --pattern 'timeout' --note "e2e timeout"
  [ "$output" = sig-2 ]
  run ft match --check "lint / oxlint" --log "$FX/log"
  [ "$status" -eq 0 ] && [ "$output" = "$(printf 'sig-1\toxlint JSON flake')" ]
  run ft match --check "e2e" --log "$FX/log"
  [ "$status" -eq 1 ]
  # known signature: re-run even where the domain intersects the diff
  run decide --check "lint / oxlint" --log "$FX/log" --file web/a.ts
  [ "$output" = "rerun known-signature id=sig-1" ]
  run ft list
  [ "${#lines[@]}" -eq 2 ]
}

@test "usage and unreadable inputs are typed" {
  run ft record --check lint --pattern '(' --note x
  [ "$status" -eq 2 ]
  run ft decide --pr 5 --head xyz --check lint
  [ "$status" -eq 2 ]
  run ft rerun --pr 5 --head "$HEAD" --check lint
  [ "$status" -eq 2 ]
  run ft bogus
  [ "$status" -eq 2 ]
  touch "$FX/files-fail"
  run decide --check lint
  [ "$status" -eq 9 ] && [[ "$output" == unverified:* ]]
  run "$SCRIPTS/failure-triage.sh" -h
  [ "$status" -eq 0 ]
  [[ "${lines[${#lines[@]}-1]}" == "#       rerun | 9 unverified (changed paths or head unreadable)" ]]
}

@test "doctrine: rerun-first rule, cloud container knobs and the pointers to them" {
  grep -q 'failure-triage.sh' "$SKILL/failure-triage.md"
  grep -qi 'never .*pkill' "$SKILL/failure-triage.md"
  grep -q 'failure-triage.md' "$SKILL/SKILL.md"
  grep -q 'failure-triage.sh' "$SKILL/roles/pr-doctor.md"
  grep -qi 'pkill' "$SKILL/roles/cloud-session-brief.md"
  grep -q 'failure-triage.sh' "$SCRIPTS/../../../README.md"
}
