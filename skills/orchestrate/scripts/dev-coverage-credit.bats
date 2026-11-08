#!/usr/bin/env bats
# dev/coverage.sh credits the continuation lines of a multi-line command (#147): bashcov's xtrace
# reports one line (often the last) of a jq program, a `\`-continued call or a heredoc, so the rest of it counted as
# uncovered even when it ran. Fixture scripts and resultsets here; no bashcov, no suite run.
# --check with a floor file of no rows names every script with its credited % ("no floor row").

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  COV="$ROOT/dev/coverage.sh"
  cd "$BATS_TEST_TMPDIR"
  D="$BATS_TEST_TMPDIR/skills/orchestrate/scripts"
  mkdir -p "$D"
  echo '# no rows' >none.tsv
  unset GITHUB_STEP_SUMMARY
  # 12 lines, 10 relevant: a multi-line jq program (2-4), a \-continued call (5-6), a heredoc (7-9)
  # whose body has an apostrophe, a comment with one (10), and a pipe continued on the next line.
  cat >"$D/m.sh" <<'SH'
#!/usr/bin/env bash
x=$(jq -n '
  {a: 1}
  | .a')
echo "$x" \
  done
cat <<'EOF'
it's here
EOF
# it's a comment
echo 'one' |
  tr o O
SH
}

# resultset FILE KEY LINES: a one-script resultset.
resultset() { printf '{"dev/test.sh": {"coverage": {"%s": {"lines": %s}}, "timestamp": 1}}\n' "$2" "$3" >"$1"; }

@test "continuation lines are credited when the command's first line ran, and floors check that" {
  resultset rs.json "$D/m.sh" '[null,1,0,0,1,0,1,0,0,null,1,0]'
  run "$COV" --check none.tsv --resultset rs.json
  [ "$status" -eq 3 ]
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/m.sh at 100%"* ]]
  # The floor is checked against the credited number, which raw (40%) would fail.
  printf 'skills/orchestrate/scripts/m.sh\t95\n' >f.tsv
  run "$COV" --check f.tsv --resultset rs.json
  [ "$status" -eq 0 ]
}

@test "xtrace often reports a multi-line command's last line: the lines above it are credited too" {
  # As bashcov reported main-health.sh's 30-line jq program: every line 0 but the last.
  resultset rs.json "$D/m.sh" '[null,0,0,1,0,1,0,0,1,null,0,1]'
  run "$COV" --check none.tsv --resultset rs.json
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/m.sh at 100%"* ]]
}

@test "continuation lines are not credited when the command did not run" {
  resultset rs.json "$D/m.sh" '[null,0,0,0,1,0,1,0,0,null,1,0]'
  run "$COV" --check none.tsv --resultset rs.json
  [ "$status" -eq 3 ]
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/m.sh at 70%"* ]]
}

@test "splitting a jq program over more lines does not move the credited percentage" {
  printf '#!/usr/bin/env bash\ny=$(jq -n %s)\necho "$y"\n' "'{a: 1} | .a'" >"$D/one.sh"
  printf '#!/usr/bin/env bash\ny=$(jq -n %s\n  {a: 1}\n  | .a%s)\necho "$y"\n' "'" "'" >"$D/split.sh"
  printf '{"dev/test.sh": {"coverage": {"%s": {"lines": [null,1,1]}, "%s": {"lines": [null,1,0,0,1]}}, "timestamp": 1}}\n' \
    "$D/one.sh" "$D/split.sh" >rs.json
  run "$COV" --check none.tsv --resultset rs.json
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/one.sh at 100%"* ]]
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/split.sh at 100%"* ]]
}

@test "an unbalanced quote or a script with no source stays as bashcov reported it" {
  printf "#!/usr/bin/env bash\necho 'open\nstill open\n" >"$D/u.sh"
  resultset rs.json "$D/u.sh" '[null,1,0,0]'
  run "$COV" --check none.tsv --resultset rs.json
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/u.sh at 33.3%"* ]]
  resultset rs.json "/nowhere/skills/orchestrate/scripts/gone.sh" '[1,0,0]'
  run "$COV" --check none.tsv --resultset rs.json
  [[ "$output" == *"no floor row: skills/orchestrate/scripts/gone.sh at 33.3%"* ]]
}

@test "the header says floors check the credited number" {
  run "$COV" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"raw"*"credited"* ]]
  [[ "$output" == *"Floors check credited"* ]]
}
