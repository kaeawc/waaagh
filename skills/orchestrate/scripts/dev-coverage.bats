#!/usr/bin/env bats
# dev/coverage.sh --check: the coverage floor check reads an existing resultset (a small synthetic
# fixture here), so it runs without bashcov and without running any suite.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  COV="$ROOT/dev/coverage.sh"
  cd "$BATS_TEST_TMPDIR"
  # Written under another root, as CI's resultset is: --check matches scripts by repo-relative path.
  # a.sh: 9 of 10 lines (90%); gh: 1 of 2 (50%); bin/x.sh: no relevant lines; the suite is filtered out.
  cat >rs.json <<'JSON'
{"dev/test.sh": {"coverage": {
  "/ci/work/waaagh/skills/orchestrate/scripts/a.sh": {"lines": [1,1,1,1,1,1,1,1,1,0,null,null]},
  "/ci/work/waaagh/skills/orchestrate/scripts/gh-shim/gh": {"lines": [3,0,null]},
  "/ci/work/waaagh/bin/x.sh": {"lines": [null]},
  "/ci/work/waaagh/skills/orchestrate/scripts/a.bats": {"lines": [0,0]}
}, "timestamp": 1}}
JSON
  printf '# script\tmin%%\nskills/orchestrate/scripts/a.sh\t89\n\nskills/orchestrate/scripts/gh-shim/gh\t50\nbin/x.sh\t0\n' >floor.tsv
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
}

@test "--check passes when every script holds its floor, and says so in the step summary" {
  run "$COV" --check floor.tsv --resultset rs.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"coverage floors held"* ]]
  grep -q 'every script at or above its floor' summary.md
}

@test "--check fails with exit 3 and names a script that dropped below its floor" {
  printf 'skills/orchestrate/scripts/a.sh\t90.5\nskills/orchestrate/scripts/gh-shim/gh\t50\nbin/x.sh\t0\n' >floor.tsv
  run "$COV" --check floor.tsv --resultset rs.json
  [ "$status" -eq 3 ]
  [[ "$output" == *"below floor: skills/orchestrate/scripts/a.sh at 90% (floor 90.5%)"* ]]
  [[ "$output" != *"gh-shim/gh"* ]]
  grep -q 'below floor: skills/orchestrate/scripts/a.sh' summary.md
}

@test "--check fails with exit 3 when a measured script has no floor row" {
  grep -v 'gh-shim' floor.tsv >f2.tsv
  run "$COV" --check f2.tsv --resultset rs.json
  [ "$status" -eq 3 ]
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/gh-shim/gh at 50%"* ]]
  [[ "$output" == *"1 coverage floor failure"* ]]
}

@test "--check works without a step summary: same verdicts, no broken pipe" {
  unset GITHUB_STEP_SUMMARY
  run "$COV" --check floor.tsv --resultset rs.json
  [ "$status" -eq 0 ]
  grep -v 'gh-shim' floor.tsv >f2.tsv
  run "$COV" --check f2.tsv --resultset rs.json
  [ "$status" -eq 3 ]
  [ ! -e summary.md ]
}

@test "--check reports a floor row for an unmeasured script as stale without failing" {
  printf 'skills/orchestrate/scripts/gone.sh\t70\n' >>floor.tsv
  run "$COV" --check floor.tsv --resultset rs.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale floor row: skills/orchestrate/scripts/gone.sh"* ]]
}

@test "--check exits 4 on a malformed, empty or missing resultset" {
  echo '{"dev/test.sh": {"coverage": ' >bad.json
  run "$COV" --check floor.tsv --resultset bad.json
  [ "$status" -eq 4 ]
  [[ "$output" == *"cannot read bad.json"* ]]
  echo '{}' >empty.json
  run "$COV" --check floor.tsv --resultset empty.json
  [ "$status" -eq 4 ]
  run "$COV" --check floor.tsv --resultset nope.json
  [ "$status" -eq 4 ]
  [[ "$output" == *"no resultset at nope.json"* ]]
}

@test "--check exits 4 on a malformed floor row and names it" {
  printf 'skills/orchestrate/scripts/a.sh 89\n' >f3.tsv
  run "$COV" --check f3.tsv --resultset rs.json
  [ "$status" -eq 4 ]
  [[ "$output" == *"f3.tsv:1:"* ]]
  printf 'skills/orchestrate/scripts/a.sh\t101\n' >f4.tsv
  run "$COV" --check f4.tsv --resultset rs.json
  [ "$status" -eq 4 ]
}

@test "usage errors exit 2: --check without a file, --resultset without --check" {
  run "$COV" --check
  [ "$status" -eq 2 ]
  run "$COV" --resultset rs.json
  [ "$status" -eq 2 ]
  run "$COV" --bogus
  [ "$status" -eq 2 ]
}

@test "the repo's floor file is well formed and every row names an existing script" {
  f="$ROOT/dev/coverage-floor.tsv"
  [ -f "$f" ]
  bad=$(awk -F'\t' '/^[[:space:]]*(#|$)/ { next } NF != 2 || $2 !~ /^[0-9]+(\.[0-9]+)?$/ { print }' "$f")
  [ -z "$bad" ]
  while IFS=$'\t' read -r script _; do
    case "$script" in '#'* | '') continue ;; esac
    [ -f "$ROOT/$script" ] || { echo "floor row for a missing script: $script"; return 1; }
  done <"$f"
}

@test "-h prints the header, which documents --check and its exit codes" {
  run "$COV" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--check F"* ]]
  [[ "$output" == *"3 --check"* ]]
  [ "$output" = "$(awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$COV")" ]
}

@test "without bashcov on PATH, exit 2 names gem's executable directory (#140)" {
  # A PATH with only what the script needs before that check, and a gem stub.
  b="$BATS_TEST_TMPDIR/bin" gb="$BATS_TEST_TMPDIR/gembin"
  mkdir -p "$b" "$gb"
  for t in bash dirname sed; do ln -s "$(command -v "$t")" "$b/$t"; done
  cat >"$b/gem" <<STUB
#!/bin/sh
echo "RubyGems Environment:"
echo "  - EXECUTABLE DIRECTORY: $gb"
STUB
  chmod +x "$b/gem"
  PATH="$b" run "$COV"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bashcov not found"*"put gem's executable directory $gb on PATH"* ]]
  printf '#!/bin/sh\n' >"$gb/bashcov"
  chmod +x "$gb/bashcov"
  PATH="$b" run "$COV"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bashcov not on PATH, but it is in gem's executable directory: PATH=\"$gb:"* ]]
  rm "$b/gem"
  PATH="$b" run "$COV"
  [ "$status" -eq 2 ]
  [[ "$output" == *"EXECUTABLE DIRECTORY from 'gem environment'"* ]]
}
