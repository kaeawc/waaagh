#!/usr/bin/env bats
# dev/coverage.sh --changed [BASE] (#194): measure only the suites that name the scripts a branch
# changed, and judge only those scripts' floors. Runs a copy of the script in a git repo of its own
# with a bashcov stub that records its argv and writes a fixture resultset: no real bashcov run.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  R="$BATS_TEST_TMPDIR/root"
  S="$R/skills/orchestrate/scripts"
  mkdir -p "$R/dev" "$R/bin" "$S/gh-shim" "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/dev/coverage.sh" "$R/dev/coverage.sh"
  for f in a.sh b.sh c.sh pa.sh lone.sh; do printf '#!/usr/bin/env bash\necho %s\n' "$f" >"$S/$f"; done
  printf '#!/usr/bin/env bash\necho w\n' >"$R/bin/w.sh"
  printf '#!/bin/sh\nexec gh "$@"\n' >"$S/gh-shim/gh"
  # a.bats runs a.sh; b.bats names a.sh only in a comment; pa.bats runs pa.sh (not a.sh);
  # uses.bats loads a helper that runs c.sh; shim.bats names gh-shim; w.bats runs bin/w.sh.
  printf '@test "a" { "$SCRIPTS/a.sh"; }\n' >"$S/a.bats"
  printf '# like a.sh, but\n@test "b" { "$SCRIPTS/b.sh"; }\n' >"$S/b.bats"
  printf '@test "pa" { "$SCRIPTS/pa.sh"; }\n' >"$S/pa.bats"
  printf '# c.sh, see c_helper\nrun_c() { "$SCRIPTS/c.sh"; }\n' >"$S/c_helper.bash"
  printf 'setup() { load c_helper; }\n@test "c" { run_c; }\n' >"$S/uses.bats"
  printf '@test "shim" { PATH="$SCRIPTS/gh-shim:$PATH"; }\n' >"$S/shim.bats"
  printf '@test "w" { "$ROOT/bin/w.sh"; }\n' >"$S/w.bats"
  printf '@test "every -h" { :; }\n' >"$S/cli-contract.bats"
  printf 'skills/orchestrate/scripts/a.sh\t89\nskills/orchestrate/scripts/b.sh\t95\nskills/orchestrate/scripts/c.sh\t40\n' >"$R/dev/coverage-floor.tsv"
  printf 'skills/orchestrate/scripts/gh-shim/gh\t50\nbin/w.sh\t50\n' >>"$R/dev/coverage-floor.tsv"
  # a.sh 90%, b.sh 10% (below its floor, but judged only when b.sh changed), c.sh 50%, gh 50%, w.sh 100%.
  cat >"$BATS_TEST_TMPDIR/fixture.json" <<JSON
{"dev/test.sh": {"coverage": {
  "$S/a.sh": {"lines": [1,1,1,1,1,1,1,1,1,0]},
  "$S/b.sh": {"lines": [1,0,0,0,0,0,0,0,0,0]},
  "$S/c.sh": {"lines": [1,0]},
  "$S/gh-shim/gh": {"lines": [1,0]},
  "$R/bin/w.sh": {"lines": [1]}
}, "timestamp": 1}}
JSON
  cat >"$BATS_TEST_TMPDIR/bin/bashcov" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$BATS_TEST_TMPDIR/argv"
mkdir -p coverage && cp "$BATS_TEST_TMPDIR/fixture.json" coverage/.resultset.json
exit "\${BASHCOV_STUB_RC:-0}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/bashcov"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset GITHUB_STEP_SUMMARY
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  cd "$BATS_TEST_TMPDIR"
}

# The suites bashcov was asked to run, repo-relative, one per line.
ran() { awk 'f { sub(".*/skills/orchestrate/scripts/", ""); print } $0 == "dev/test.sh" { f = 1 }' argv | awk '$0 !~ /^-j$|^[0-9]+$/'; }

@test "no changed script: nothing runs and it exits 0, without bashcov" {
  echo "# docs" >"$R/README.md"
  echo "# a suite" >>"$S/a.bats"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changed scripts against origin/main"* ]]
  [ ! -e argv ]
}

@test "a changed script runs the suites that name it outside a comment, plus cli-contract" {
  echo "# edit" >>"$S/a.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(ran)" = "$(printf '%s\n' a.bats cli-contract.bats)" ]
  [[ "$output" == *"--changed against origin/main: 1 script(s), 2 suite(s)"* ]]
  [ "$(cat "$R/coverage/changed.txt")" = "skills/orchestrate/scripts/a.sh" ]
  [ -f "$R/coverage/subset.txt" ]
  [[ "$output" == *"partial resultset"* ]]
  [[ "$output" == *"coverage floors held"* ]]
  # b.sh is measured below its floor, but it did not change: not judged.
  [ "$(grep -c 'below floor' <<<"$output" || true)" -eq 0 ]
}

@test "a changed script below its floor fails with exit 3 and names it" {
  echo "# edit" >>"$S/b.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 3 ]
  [ "$(ran)" = "$(printf '%s\n' b.bats cli-contract.bats)" ]
  [[ "$output" == *"below floor: skills/orchestrate/scripts/b.sh at 10% (floor 95%)"* ]]
  [ "$(grep -c 'a.sh' <<<"$(grep 'floor' <<<"$output")" || true)" -eq 0 ]
}

@test "a changed script with no floor row fails with exit 3" {
  echo "# edit" >>"$S/a.sh"
  grep -v '/a.sh' "$R/dev/coverage-floor.tsv" >f && mv f "$R/dev/coverage-floor.tsv"
  git -C "$R" commit -qam "drop a row"
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  echo "# again" >>"$S/a.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 3 ]
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/a.sh"* ]]
}

@test "committed, staged and helper-loaded: a helper that names a script picks the suites loading it" {
  git -C "$R" checkout -qb lane
  echo "# edit" >>"$S/c.sh"
  git -C "$R" commit -qam "lane change"
  echo "# staged" >>"$R/bin/w.sh"
  git -C "$R" add bin/w.sh
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(ran)" = "$(printf '%s\n' cli-contract.bats uses.bats w.bats)" ]
  [ "$(cat "$R/coverage/changed.txt")" = "$(printf '%s\n' bin/w.sh skills/orchestrate/scripts/c.sh)" ]
}

@test "gh-shim/gh maps to the suites that name gh-shim" {
  echo "# edit" >>"$S/gh-shim/gh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(ran)" = "$(printf '%s\n' cli-contract.bats shim.bats)" ]
}

@test "an untracked script no suite names is reported and not judged" {
  printf '#!/usr/bin/env bash\n' >"$S/new.sh"
  echo "# edit" >>"$S/a.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"not measured, no suite names it: skills/orchestrate/scripts/new.sh"* ]]
  [ "$(cat "$R/coverage/changed.txt")" = "skills/orchestrate/scripts/a.sh" ]
  [ "$(grep -c 'no floor row' <<<"$output" || true)" -eq 0 ]
}

@test "only unnamed scripts changed: nothing runs, exit 0, bashcov not called" {
  echo "# edit" >>"$S/lone.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"not measured, no suite names it: skills/orchestrate/scripts/lone.sh"* ]]
  [[ "$output" == *"no suite to run"* ]]
  [ ! -e argv ]
}

@test "a deleted script is not measured" {
  git -C "$R" rm -q skills/orchestrate/scripts/a.sh
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changed scripts"* ]]
  [ ! -e argv ]
}

@test "an explicit BASE is diffed against instead of origin/main, and -j passes through" {
  echo "# edit" >>"$S/a.sh"
  git -C "$R" commit -qam "a"
  echo "# edit" >>"$S/b.sh"
  git -C "$R" commit -qam "b"
  run "$R/dev/coverage.sh" --changed HEAD~1 -j 2
  [ "$status" -eq 3 ]
  [ "$(ran)" = "$(printf '%s\n' b.bats cli-contract.bats)" ]
  [[ "$(cat argv)" == *$'dev/test.sh\n-j\n2\n'* ]]
  [[ "$output" == *"--changed against HEAD~1"* ]]
}

@test "a suite that fails under coverage exits 1 before the floors are judged" {
  echo "# edit" >>"$S/b.sh"
  BASHCOV_STUB_RC=1 run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 1 ]
  [[ "$output" == *"a suite failed under coverage"* ]]
  [ "$(grep -c 'below floor' <<<"$output" || true)" -eq 0 ]
}

@test "usage errors exit 2: unknown BASE, with --check, with suite files" {
  echo "# edit" >>"$S/a.sh"
  run "$R/dev/coverage.sh" --changed no-such-ref
  [ "$status" -eq 2 ]
  [[ "$output" == *"no merge base with no-such-ref"* ]]
  run "$R/dev/coverage.sh" --changed --check "$R/dev/coverage-floor.tsv"
  [ "$status" -eq 2 ]
  run "$R/dev/coverage.sh" --changed a.bats
  [ "$status" -eq 2 ]
  [[ "$output" == *"--changed picks the suites itself"* ]]
  [ ! -e argv ]
}

@test "-h documents --changed and the full run's cost" {
  run "$ROOT/dev/coverage.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--changed [BASE]"* ]]
  [[ "$output" == *"Runtime"*"20 minutes"*"over an hour"* ]]
  [ "$output" = "$(awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$ROOT/dev/coverage.sh")" ]
}
