#!/usr/bin/env bats
# dev/coverage.sh --check after a --changed run (#255): the resultset holds partial numbers for
# scripts the changed suites only brushed, so a plain --check judges only the scripts in
# coverage/changed.txt, as --changed did. A full run clears the markers and judges every script.
# Runs a copy of the script in a repo of its own against a stub bashcov that writes a fixture.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  R="$BATS_TEST_TMPDIR/root"
  S="$R/skills/orchestrate/scripts"
  mkdir -p "$R/dev" "$S" "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/dev/coverage.sh" "$R/dev/coverage.sh"
  for f in a.sh b.sh; do printf '#!/usr/bin/env bash\necho %s\n' "$f" >"$S/$f"; done
  printf '@test "a" { "$SCRIPTS/a.sh"; }\n' >"$S/a.bats"
  printf '@test "b" { "$SCRIPTS/b.sh"; }\n' >"$S/b.bats"
  printf 'skills/orchestrate/scripts/a.sh\t89\nskills/orchestrate/scripts/b.sh\t95\n' >"$R/dev/coverage-floor.tsv"
  # a.sh 90% (holds 89), b.sh 10% (below 95: what a subset that only brushed it reads).
  cat >"$BATS_TEST_TMPDIR/fixture.json" <<JSON
{"dev/test.sh": {"coverage": {
  "$S/a.sh": {"lines": [1,1,1,1,1,1,1,1,1,0]},
  "$S/b.sh": {"lines": [1,0,0,0,0,0,0,0,0,0]}
}, "timestamp": 1}}
JSON
  cat >"$BATS_TEST_TMPDIR/bin/bashcov" <<STUB
#!/usr/bin/env bash
mkdir -p coverage && cp "$BATS_TEST_TMPDIR/fixture.json" coverage/.resultset.json
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/bashcov"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  cd "$BATS_TEST_TMPDIR"
}

@test "--check after --changed judges only the changed scripts and says so" {
  echo "# edit" >>"$S/a.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$R/dev/coverage.sh" --check "$R/dev/coverage-floor.tsv"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"from --changed: judging only the 1 script(s) in $R/coverage/changed.txt"* ]]
  [[ "$output" == *"coverage floors held"* ]]
  [ "$(grep -c 'b.sh' <<<"$output" || true)" -eq 0 ]
  grep -q 'from --changed: judging only' summary.md
}

@test "--check after --changed still fails a changed script below its floor" {
  echo "# edit" >>"$S/b.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 3 ]
  run "$R/dev/coverage.sh" --check "$R/dev/coverage-floor.tsv"
  [ "$status" -eq 3 ]
  [[ "$output" == *"below floor: skills/orchestrate/scripts/b.sh at 10% (floor 95%)"* ]]
  [ "$(grep -c 'a.sh' <<<"$(grep 'floor:' <<<"$output")" || true)" -eq 0 ]
}

@test "a full run clears the --changed markers, and --check judges every script" {
  echo "# edit" >>"$S/a.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$R/dev/coverage.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$R/coverage/changed.txt" ]
  [ ! -e "$R/coverage/subset.txt" ]
  run "$R/dev/coverage.sh" --check "$R/dev/coverage-floor.tsv"
  [ "$status" -eq 3 ]
  [[ "$output" == *"below floor: skills/orchestrate/scripts/b.sh at 10% (floor 95%)"* ]]
  [[ "$output" != *"partial"* ]]
}

@test "a changed.txt without subset.txt beside it is ignored: every script is judged" {
  mkdir -p cov
  cp "$BATS_TEST_TMPDIR/fixture.json" cov/.resultset.json
  printf 'skills/orchestrate/scripts/a.sh\n' >cov/changed.txt
  run "$R/dev/coverage.sh" --check "$R/dev/coverage-floor.tsv" --resultset cov/.resultset.json
  [ "$status" -eq 3 ]
  [[ "$output" == *"below floor: skills/orchestrate/scripts/b.sh"* ]]
}

@test "a bare-suite subset (no changed.txt) is still judged in full, with the partial note" {
  run "$R/dev/coverage.sh" a.bats
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$R/coverage/changed.txt" ]
  run "$R/dev/coverage.sh" --check "$R/dev/coverage-floor.tsv"
  [ "$status" -eq 3 ]
  [[ "$output" == *"partial resultset: only 1 suite(s) ran"* ]]
  [[ "$output" != *"from --changed"* ]]
  [[ "$output" == *"below floor: skills/orchestrate/scripts/b.sh"* ]]
}
