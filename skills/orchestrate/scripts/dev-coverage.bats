#!/usr/bin/env bats
# dev/coverage.sh --check: the coverage floor check reads an existing resultset (a small synthetic
# fixture here), so it runs without bashcov and without running any suite. A run of chosen suites
# (#168) runs a copy of the script against a stub bashcov in a repo root of its own.

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

# fake_root: a copy of dev/coverage.sh in a repo root of its own with three suites, and a bashcov
# stub that records its argv and writes the fixture resultset (keyed under that root), so a run
# touches neither the real repo's coverage/ nor any suite (#168).
fake_root() {
  R="$BATS_TEST_TMPDIR/root"
  mkdir -p "$R/dev" "$R/skills/orchestrate/scripts" "$BATS_TEST_TMPDIR/bin"
  cp "$COV" "$R/dev/coverage.sh"
  for s in one two three; do printf '@test "x" { :; }\n' >"$R/skills/orchestrate/scripts/$s.bats"; done
  sed "s#/ci/work/waaagh#$R#" rs.json >"$BATS_TEST_TMPDIR/fixture.json"
  cat >"$BATS_TEST_TMPDIR/bin/bashcov" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$BATS_TEST_TMPDIR/argv"
mkdir -p coverage && cp "$BATS_TEST_TMPDIR/fixture.json" coverage/.resultset.json
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/bashcov"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "suite files pass through to dev/test.sh, and the table says the run was a subset (#168)" {
  fake_root
  run "$R/dev/coverage.sh" -j 2 "$R/skills/orchestrate/scripts/two.bats"
  [ "$status" -eq 0 ]
  [ "$(cat argv)" = "$(printf '%s\n' --root "$R" -- dev/test.sh -j 2 "$R/skills/orchestrate/scripts/two.bats")" ]
  [[ "$output" == *"90%"*"skills/orchestrate/scripts/a.sh"* ]]
  [[ "$output" == *"subset: 1 of 3 suites ran (coverage/subset.txt)"* ]]
  [ "$(cat "$R/coverage/subset.txt")" = "skills/orchestrate/scripts/two.bats" ]
  grep -q '_subset: 1 of 3 suites ran' summary.md
}

@test "a relative suite path is resolved before the run moves to the repo root (#168)" {
  fake_root
  cd "$R/skills/orchestrate"
  run "$R/dev/coverage.sh" scripts/one.bats scripts/three.bats
  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/argv")" == *"$R/skills/orchestrate/scripts/one.bats"$'\n'"$R/skills/orchestrate/scripts/three.bats" ]]
  [[ "$output" == *"subset: 2 of 3 suites ran"* ]]
}

@test "a full run passes no suite files, writes no subset.txt and adds no subset note (#168)" {
  fake_root
  mkdir -p "$R/coverage"
  echo stale >"$R/coverage/subset.txt"
  run "$R/dev/coverage.sh"
  [ "$status" -eq 0 ]
  [ "$(cat argv)" = "$(printf '%s\n' --root "$R" -- dev/test.sh -j 1)" ]
  [ ! -e "$R/coverage/subset.txt" ]
  [[ "$output" != *"subset"* ]]
  [ "$(grep -c subset summary.md || true)" -eq 0 ]
}

@test "--check on a subset resultset gives the same verdicts and says the numbers are partial (#168)" {
  mkdir -p cov
  cp rs.json cov/.resultset.json
  printf 'skills/orchestrate/scripts/two.bats\n' >cov/subset.txt
  run "$COV" --check floor.tsv --resultset cov/.resultset.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"partial resultset: only 1 suite(s) ran (cov/subset.txt)"* ]]
  grep -q '_partial resultset' summary.md
  printf 'skills/orchestrate/scripts/a.sh\t95\nskills/orchestrate/scripts/gh-shim/gh\t50\n' >f2.tsv
  run "$COV" --check f2.tsv --resultset cov/.resultset.json
  [ "$status" -eq 3 ]
  [[ "$output" == *"partial resultset"*"below floor: skills/orchestrate/scripts/a.sh"* ]]
  rm cov/subset.txt
  run "$COV" --check floor.tsv --resultset cov/.resultset.json
  [ "$status" -eq 0 ]
  [[ "$output" != *"partial"* ]]
}

@test "suite file usage errors exit 2: a missing suite, or suites with --check (#168)" {
  run "$COV" nope.bats
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such suite: nope.bats"* ]]
  touch s.bats
  run "$COV" --check floor.tsv --resultset rs.json s.bats
  [ "$status" -eq 2 ]
  [[ "$output" == *"--check runs no suites"* ]]
}
