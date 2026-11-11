#!/usr/bin/env bats
# dev/coverage.sh keeps bashcov's output outside the repo while it runs and moves it to
# coverage/test.log at the end (#228): a git add -A mid-run, or an interrupted run, finds no stray
# coverage.log at the root. Runs a copy of the script in a git repo of its own (no .gitignore, so
# nothing is hidden) with a bashcov stub that snapshots `git status` while it runs.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  R="$BATS_TEST_TMPDIR/root"
  S="$R/skills/orchestrate/scripts"
  mkdir -p "$R/dev" "$S" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/tmp"
  cp "$ROOT/dev/coverage.sh" "$R/dev/coverage.sh"
  printf '#!/usr/bin/env bash\necho a\n' >"$S/a.sh"
  printf '@test "a" { "$SCRIPTS/a.sh"; }\n' >"$S/a.bats"
  cat >"$BATS_TEST_TMPDIR/fixture.json" <<JSON
{"dev/test.sh": {"coverage": {"$S/a.sh": {"lines": [1,1]}}, "timestamp": 1}}
JSON
  # Prints a marker (the log's content), records untracked files mid-run, writes the resultset;
  # BASHCOV_STUB_KILL=1 then kills dev/coverage.sh as an interrupted run would be.
  cat >"$BATS_TEST_TMPDIR/bin/bashcov" <<STUB
#!/usr/bin/env bash
echo "stub bashcov output"
git status --porcelain --untracked-files=all >"$BATS_TEST_TMPDIR/midrun"
mkdir -p coverage && cp "$BATS_TEST_TMPDIR/fixture.json" coverage/.resultset.json
if [[ "\${BASHCOV_STUB_KILL:-}" == 1 ]]; then kill -KILL "\$PPID"; fi
exit "\${BASHCOV_STUB_RC:-0}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/bashcov"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  unset GITHUB_STEP_SUMMARY
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" commit -qm base
  cd "$BATS_TEST_TMPDIR"
}

# untracked FILE: the untracked paths in a `git status --porcelain` snapshot, outside coverage/.
untracked() { awk '$1 == "??" && $2 !~ /^coverage\// { print $2 }' "$1"; }

@test "a run leaves no untracked file outside coverage/, during or after, and the log lands in coverage/test.log" {
  run "$R/dev/coverage.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f midrun ]
  [ -z "$(untracked midrun)" ] || { cat midrun; false; }
  git -C "$R" status --porcelain --untracked-files=all >after
  [ -z "$(untracked after)" ] || { cat after; false; }
  [ ! -e "$R/coverage.log" ]
  [ "$(cat "$R/coverage/test.log")" = "stub bashcov output" ]
  # The temporary log was moved, not copied: nothing is left in TMPDIR.
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
}

@test "a failing suite still moves the log to coverage/test.log and leaves the root clean" {
  BASHCOV_STUB_RC=1 run "$R/dev/coverage.sh"
  [[ "$output" == *"a suite failed under coverage (see coverage/test.log)"* ]]
  [ "$(cat "$R/coverage/test.log")" = "stub bashcov output" ]
  git -C "$R" status --porcelain --untracked-files=all >after
  [ -z "$(untracked after)" ] || { cat after; false; }
}

@test "an interrupted run leaves no coverage.log at the root" {
  BASHCOV_STUB_KILL=1 run "$R/dev/coverage.sh"
  [ "$status" -ne 0 ]
  git -C "$R" status --porcelain --untracked-files=all >after
  [ -z "$(untracked after)" ] || { cat after; false; }
  [ ! -e "$R/coverage.log" ]
}
