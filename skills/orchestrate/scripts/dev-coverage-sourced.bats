#!/usr/bin/env bats
# dev/coverage.sh --changed (#245): a changed helper that no suite names, but that scripts source
# (`source` or `.`), picks the suites that name those sourcing scripts, transitively. Runs a copy of
# the script in a git repo of its own with a bashcov stub that records its argv: no real bashcov run.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  R="$BATS_TEST_TMPDIR/root"
  S="$R/skills/orchestrate/scripts"
  mkdir -p "$R/dev" "$S" "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/dev/coverage.sh" "$R/dev/coverage.sh"
  # _deep.sh is sourced by _h.sh; _h.sh by top.sh (source) and dot.sh (.); quote.sh only echoes
  # "_h.sh", and comment.sh sources it only in a comment: neither counts. _lone.sh: nothing sources it.
  printf '#!/usr/bin/env bash\ndeep() { :; }\n' >"$S/_deep.sh"
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/_deep.sh"\nh() { deep; }\n' >"$S/_h.sh"
  printf '#!/usr/bin/env bash\nhere=$(dirname "$0")\nsource "$here/_h.sh"\nh\n' >"$S/top.sh"
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")"/_h.sh; h\n' >"$S/dot.sh"
  printf '#!/usr/bin/env bash\necho "see _h.sh"\n' >"$S/quote.sh"
  printf '#!/usr/bin/env bash\n# source "$here/_h.sh"\necho c\n' >"$S/comment.sh"
  printf '#!/usr/bin/env bash\nlone() { :; }\n' >"$S/_lone.sh"
  printf '@test "top" { "$SCRIPTS/top.sh"; }\n' >"$S/top.bats"
  printf '@test "dot" { "$SCRIPTS/dot.sh"; }\n' >"$S/dot.bats"
  printf '@test "quote" { "$SCRIPTS/quote.sh"; }\n' >"$S/quote.bats"
  printf '@test "comment" { "$SCRIPTS/comment.sh"; }\n' >"$S/comment.bats"
  printf '@test "every -h" { :; }\n' >"$S/cli-contract.bats"
  printf 'skills/orchestrate/scripts/_h.sh\t50\nskills/orchestrate/scripts/_deep.sh\t50\n' >"$R/dev/coverage-floor.tsv"
  cat >"$BATS_TEST_TMPDIR/fixture.json" <<JSON
{"dev/test.sh": {"coverage": {
  "$S/_h.sh": {"lines": [1,1]},
  "$S/_deep.sh": {"lines": [1,1]}
}, "timestamp": 1}}
JSON
  cat >"$BATS_TEST_TMPDIR/bin/bashcov" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$BATS_TEST_TMPDIR/argv"
mkdir -p coverage && cp "$BATS_TEST_TMPDIR/fixture.json" coverage/.resultset.json
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

@test "a helper no suite names picks the suites of the scripts that source it (source and .)" {
  echo "# edit" >>"$S/_h.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(ran)" = "$(printf '%s\n' cli-contract.bats dot.bats top.bats)" ]
  [ "$(cat "$R/coverage/changed.txt")" = "skills/orchestrate/scripts/_h.sh" ]
  [ "$(grep -c 'not measured' <<<"$output" || true)" -eq 0 ]
  [[ "$output" == *"coverage floors held"* ]]
}

@test "sourcing is followed transitively: a helper sourced by a sourced helper" {
  echo "# edit" >>"$S/_deep.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(ran)" = "$(printf '%s\n' cli-contract.bats dot.bats top.bats)" ]
}

@test "a helper nothing sources and no suite names is still not measured" {
  echo "# edit" >>"$S/_lone.sh"
  run "$R/dev/coverage.sh" --changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"not measured, no suite names it: skills/orchestrate/scripts/_lone.sh"* ]]
  [ ! -e argv ]
}
