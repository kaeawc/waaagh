#!/usr/bin/env bats
# dev/coverage.sh --changed (#248): a *.bash helper that names a script counts for every suite that
# loads it, and every suite loads test_helper. So test_helper.bash must name no script, or a change
# to that script (or to a helper it sources) picks the whole tree. Runs a copy of this repo's real
# scripts and suites with a bashcov stub that records its argv: no real bashcov run.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  R="$BATS_TEST_TMPDIR/root"
  mkdir -p "$R/dev" "$R/skills/orchestrate" "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/dev/coverage.sh" "$ROOT/dev/coverage-floor.tsv" "$R/dev/"
  cp -R "$SCRIPTS" "$R/skills/orchestrate/scripts"
  [ ! -d "$ROOT/bin" ] || cp -R "$ROOT/bin" "$R/bin"
  printf '{"dev/test.sh": {"coverage": {}, "timestamp": 1}}\n' >"$BATS_TEST_TMPDIR/fixture.json"
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

# The suites bashcov was asked to run, by file name, one per line.
ran() { awk 'f { sub(".*/", ""); print } $0 == "dev/test.sh" { f = 1 }' argv | awk '$0 !~ /^-j$|^[0-9]+$/'; }
suites_total() { find "$R/skills/orchestrate/scripts" -maxdepth 1 -name '*.bats' | awk 'END { print NR }'; }

@test "test_helper.bash names no script of this directory outside a comment" {
  local names
  names=$(cd "$SCRIPTS" && printf '%s ' *.sh)
  run awk -v names="$names" '
    BEGIN { n = split(names, w, " ") }
    /^[[:space:]]*#/ { next }
    { for (i = 1; i <= n; i++) { p = w[i]; gsub(/[.]/, "[.]", p)
        if ($0 ~ "(^|[^A-Za-z0-9_.-])" p "([^A-Za-z0-9_-]|$)") print FILENAME ":" FNR ": " w[i] } }' \
    "$SCRIPTS/test_helper.bash"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "a triage-tick.sh change picks its suites and cli-contract.bats, not every suite" {
  echo "# edit" >>"$R/skills/orchestrate/scripts/triage-tick.sh"
  run "$R/dev/coverage.sh" --changed
  [ -f argv ] || { echo "$output"; false; }
  run ran
  [[ $'\n'"$output"$'\n' == *$'\n'triage-tick.bats$'\n'* ]]
  [[ $'\n'"$output"$'\n' == *$'\n'cli-contract.bats$'\n'* ]]
  [[ $'\n'"$output"$'\n' != *$'\n'gh-read.bats$'\n'* ]]
  # every other picked suite names triage-tick.sh itself outside a comment
  local s
  for s in "${lines[@]}"; do
    if [ "$s" = cli-contract.bats ]; then continue; fi
    run awk '!/^[[:space:]]*#/ && /triage-tick[.]sh/ { hit = 1 } END { exit !hit }' "$R/skills/orchestrate/scripts/$s"
    [ "$status" -eq 0 ] || { echo "$s picked but names no triage-tick.sh"; false; }
  done
  [ "${#lines[@]}" -lt "$(($(suites_total) / 2))" ]
}

@test "a _slots.sh change picks a short list, host-budget.bats among it" {
  echo "# edit" >>"$R/skills/orchestrate/scripts/_slots.sh"
  run "$R/dev/coverage.sh" --changed
  [ -f argv ] || { echo "$output"; false; }
  run ran
  [[ $'\n'"$output"$'\n' == *$'\n'host-budget.bats$'\n'* ]]
  [[ $'\n'"$output"$'\n' == *$'\n'cli-contract.bats$'\n'* ]]
  [[ $'\n'"$output"$'\n' != *$'\n'gh-read.bats$'\n'* ]]
  [ "${#lines[@]}" -lt "$(($(suites_total) / 2))" ]
}
