#!/usr/bin/env bats
# dev/coverage.sh --shard, --merge and --weights (#295): CI splits the coverage run into shards that
# each run bashcov on their own runner, then merges their resultsets and checks the floors on the
# merged one. A copy of the script runs in a repo root of its own against a bashcov stub that
# records the suites it was asked to run, and the merge reads small synthetic resultsets: no real
# bashcov run here.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  R="$BATS_TEST_TMPDIR/root"
  COV="$R/dev/coverage.sh"
  mkdir -p "$R/dev" "$R/skills/orchestrate/scripts" "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/dev/coverage.sh" "$COV"
  # Weights: four suites with a row, and e.bats with none, so it weighs its 3 @test lines.
  for s in a b c d; do printf '@test "x" { :; }\n' >"$R/skills/orchestrate/scripts/$s.bats"; done
  printf '@test "1" { :; }\n@test "2" { :; }\n@test "3" { :; }\n' >"$R/skills/orchestrate/scripts/e.bats"
  printf '# suite\tseconds\na.bats\t10\nb.bats\t7\nc.bats\t5\nd.bats\t4\ngone.bats\t99\n' >"$R/dev/coverage-weights.tsv"
  printf '{"x": {"coverage": {"%s/skills/orchestrate/scripts/a.sh": {"lines": [1,null]}}, "timestamp": 1}}\n' "$R" \
    >"$BATS_TEST_TMPDIR/fixture.json"
  cat >"$BATS_TEST_TMPDIR/bin/bashcov" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$BATS_TEST_TMPDIR/argv"
mkdir -p coverage && cp "$BATS_TEST_TMPDIR/fixture.json" coverage/.resultset.json
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/bashcov"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset GITHUB_STEP_SUMMARY
  cd "$BATS_TEST_TMPDIR"
}

# The suites bashcov was asked to run, by file name, one per line, in the order given.
ran() { awk 'f && $0 !~ /^-j$|^[0-9]+$/ { sub(".*/", ""); print } $0 == "dev/test.sh" { f = 1 }' argv; }

@test "--shard deals the suites heaviest first to the lightest shard, by weights row or @test count" {
  # a10 b7 c5 d4 e3 into 2: a->1 (10), b->2 (7), c->2 (12), d->1 (14), e->2 (15).
  run "$COV" --shard 1/2
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(ran | sort | tr '\n' ' ')" = "a.bats d.bats " ]
  [[ "$output" == *"--shard 1/2: 2 suite(s)"* ]]
  [ "$(sort "$R/coverage/subset.txt" | tr '\n' ' ')" = "skills/orchestrate/scripts/a.bats skills/orchestrate/scripts/d.bats " ]
  run "$COV" --shard 2/2 -j 1
  [ "$status" -eq 0 ]
  [ "$(ran | sort | tr '\n' ' ')" = "b.bats c.bats e.bats " ]
}

@test "--shard: every suite lands in exactly one shard, a new one included, the same way each time" {
  printf '@test "x" { :; }\n' >"$R/skills/orchestrate/scripts/new.bats"
  for k in 1 2 3; do
    run "$COV" --shard "$k/3"
    [ "$status" -eq 0 ]
    ran >>all.txt
    ran >"once-$k.txt"
    run "$COV" --shard "$k/3"
    [ "$(ran)" = "$(cat "once-$k.txt")" ] || { echo "shard $k changed between runs"; false; }
  done
  [ "$(sort all.txt | tr '\n' ' ')" = "a.bats b.bats c.bats d.bats e.bats new.bats " ]
}

@test "--shard: without a weights file every suite weighs its @test count" {
  rm "$R/dev/coverage-weights.tsv"
  # e3 a1 b1 c1 d1 into 2: e->1 (3), a->2 (1), b->2 (2), c->2 (3), d->1 (a tie at 3: the lower shard).
  run "$COV" --shard 1/2
  [ "$status" -eq 0 ]
  [ "$(ran | sort | tr '\n' ' ')" = "d.bats e.bats " ]
}

@test "--shard: a shard with no suite runs nothing and exits 0" {
  run "$COV" --shard 6/6
  [ "$status" -eq 0 ]
  [[ "$output" == *"shard 6/6 has no suite; nothing to run"* ]]
  [ ! -e argv ]
}

@test "--shard usage errors exit 2 before any run" {
  for bad in 0/4 5/4 x 4 /4 04/4; do
    run "$COV" --shard "$bad"
    [ "$status" -eq 2 ] || { echo "accepted: $bad"; false; }
  done
  run "$COV" --shard
  [ "$status" -eq 2 ]
  run "$COV" --shard 1/2 a.bats
  [ "$status" -eq 2 ]
  [[ "$output" == *"--shard picks the suites itself"* ]]
  run "$COV" --shard 1/2 --changed
  [ "$status" -eq 2 ]
  [ ! -e argv ]
}

# shards: two shard directories as CI downloads them, written under other roots. a.sh: lines 1-3
# relevant, each shard hits some; gh: shard 2 only, with a line past shard 1's end.
shards() {
  mkdir -p s1 s2
  cat >s1/.resultset.json <<'JSON'
{"/bin/bash dev/test.sh -j 1 x": {"coverage": {
  "/ci/one/skills/orchestrate/scripts/a.sh": {"lines": [1,0,0,null]},
  "/ci/one/skills/orchestrate/scripts/a.bats": {"lines": [1]}
}, "timestamp": 1}}
JSON
  cat >s2/.resultset.json <<'JSON'
{"/bin/bash dev/test.sh -j 1 y": {"coverage": {
  "/ci/two/skills/orchestrate/scripts/a.sh": {"lines": [0,2,0,null]},
  "/ci/two/skills/orchestrate/scripts/gh-shim/gh": {"lines": [null,0,4]}
}, "timestamp": 2}}
JSON
  printf 'skills/orchestrate/scripts/a.bats\nskills/orchestrate/scripts/b.bats\n' >s1/subset.txt
  printf 'skills/orchestrate/scripts/c.bats\nskills/orchestrate/scripts/d.bats\nskills/orchestrate/scripts/e.bats\n' >s2/subset.txt
  echo "ok      1s    1 tests  skills/orchestrate/scripts/a.bats" >s1/test.log
  echo "ok      2s    1 tests  skills/orchestrate/scripts/c.bats" >s2/test.log
}

@test "--merge adds the shards' line counts under this root, and a whole merge has no subset.txt" {
  shards
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run "$COV" --merge s1 s2
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e argv ]
  m="$R/coverage/.resultset.json"
  [ "$(jq -c '[.[] | .coverage] | length' "$m")" = 1 ]
  [ "$(jq -c --arg k "$R/skills/orchestrate/scripts/a.sh" '.[] | .coverage[$k].lines' "$m")" = "[1,2,0,null]" ]
  [ "$(jq -c --arg k "$R/skills/orchestrate/scripts/gh-shim/gh" '.[] | .coverage[$k].lines' "$m")" = "[null,0,4]" ]
  [ "$(jq -c '.[] | .coverage["/ci/one/skills/orchestrate/scripts/a.bats"].lines' "$m")" = "[1]" ]
  [ ! -e "$R/coverage/subset.txt" ]
  [[ "$output" == *"66.6%"*"2/3"*"skills/orchestrate/scripts/a.sh"* ]]
  [[ "$output" == *"total	3/5"* ]]
  [[ "$output" != *"subset"* ]]
  [ "$(grep -c . "$R/coverage/test.log")" -eq 2 ]
  grep -q 'Line coverage (bashcov)' summary.md
}

@test "--check on a merged resultset holds a kept floor and fails a dropped one" {
  shards
  run "$COV" --merge s1 s2
  [ "$status" -eq 0 ]
  printf 'skills/orchestrate/scripts/a.sh\t66\nskills/orchestrate/scripts/gh-shim/gh\t50\n' >floor.tsv
  run "$COV" --check floor.tsv --resultset "$R/coverage/.resultset.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"partial"* ]]
  printf 'skills/orchestrate/scripts/a.sh\t70\nskills/orchestrate/scripts/gh-shim/gh\t50\n' >floor.tsv
  run "$COV" --check floor.tsv --resultset "$R/coverage/.resultset.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"below floor: skills/orchestrate/scripts/a.sh at 66.6% (floor 70%)"* ]]
}

@test "--merge with a shard missing: subset.txt lists what ran, and the missing suites are named" {
  shards
  rm s2/.resultset.json
  run "$COV" --merge s1 s2
  [ "$status" -eq 0 ]
  [[ "$output" == *"no resultset in s2; skipped"* ]]
  [[ "$output" == *"no shard ran skills/orchestrate/scripts/c.bats"* ]]
  [[ "$output" == *"subset: 2 of 5 suites ran"* ]]
  [ "$(cat "$R/coverage/subset.txt" | tr '\n' ' ')" = "skills/orchestrate/scripts/a.bats skills/orchestrate/scripts/b.bats " ]
  # A shard with no subset.txt was a full run: the merge is whole.
  rm s1/subset.txt
  run "$COV" --merge s1 s2
  [ "$status" -eq 0 ]
  [ ! -e "$R/coverage/subset.txt" ]
}

@test "--merge exits 4 with no readable resultset, and 2 on usage errors" {
  mkdir -p e1 bad
  run "$COV" --merge e1
  [ "$status" -eq 4 ]
  [[ "$output" == *"no resultset in any DIR"* ]]
  echo '{"x": {"coverage": ' >bad/.resultset.json
  run "$COV" --merge bad
  [ "$status" -eq 4 ]
  run "$COV" --merge
  [ "$status" -eq 2 ]
  run "$COV" --merge e1 --check f.tsv
  [ "$status" -eq 2 ]
  run "$COV" --merge e1 --weights x
  [ "$status" -eq 2 ]
}

@test "--weights prints suite<TAB>seconds from test.log lines, the last line for a suite winning" {
  printf 'noise\nok     74s    6 tests  skills/orchestrate/scripts/b.bats\nFAIL    9s    2 tests  /x/skills/orchestrate/scripts/a.bats\n' >l1.log
  printf 'ok     70s    6 tests  skills/orchestrate/scripts/b.bats\n904/904 tests passed in 111 files, 994s wall, -j 1\n' >l2.log
  run "$COV" --weights l1.log l2.log
  [ "$status" -eq 0 ]
  [ "$(grep -v '^#' <<<"$output")" = "$(printf 'a.bats\t9\nb.bats\t70')" ]
  run "$COV" --weights nope.log
  [ "$status" -eq 2 ]
}

@test "the repo's weights file is well formed" {
  f="$ROOT/dev/coverage-weights.tsv"
  [ -f "$f" ]
  bad=$(awk -F'\t' '/^[[:space:]]*(#|$)/ { next } NF != 2 || $1 !~ /\.bats$/ || $2 !~ /^[0-9]+(\.[0-9]+)?$/ { print }' "$f")
  [ -z "$bad" ] || { echo "$bad"; false; }
}

# The workflow: shard jobs, each with its own artifact, and a merge job that keeps the `coverage`
# check name and judges the floors on the merged resultset.
@test "coverage.yml runs one job per shard and merges them in the coverage job" {
  wf="$ROOT/.github/workflows/coverage.yml"
  y=$(cat "$wf")
  n=$(sed -n 's/.*dev\/coverage.sh --shard \${{ matrix.shard }}\/\([0-9][0-9]*\).*/\1/p' "$wf")
  [ -n "$n" ]
  [[ "$y" == *"shard: [$(seq -s ', ' 1 "$n")]"* ]] || { echo "matrix does not list shards 1..$n"; false; }
  [[ "$y" == *"name: coverage-shard-\${{ matrix.shard }}"* ]]
  [[ "$y" == *"pattern: coverage-shard-*"* ]]
  [[ "$y" == *"dev/coverage.sh --merge shards/*"* ]]
  [[ "$y" == *"dev/coverage.sh --check dev/coverage-floor.tsv"* ]]
  [[ "$y" == *$'\n  coverage:\n'* ]]
  [[ "$y" == *"needs: shard"* ]]
  [ "$(grep -c 'include-hidden-files: true' "$wf" || true)" -ge 2 ]
  [ "$(grep -c 'timeout-minutes:' "$wf" || true)" -ge 2 ]
}
