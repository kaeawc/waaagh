#!/usr/bin/env bats
# fingerprint.sh paths the other suites do not reach: a jj checkout (stubbed jj) and --show-env on
# its own (tool and input lines, then the signature; no cache key).
# Run: bats scripts/fingerprint-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  R="$BATS_TEST_TMPDIR/repo"; mkdir -p "$R"
  git -C "$R" init -q; echo a >"$R/a"; git -C "$R" add a; git -C "$R" commit -qm init
}

@test "a jj checkout is identified by @- and the diff of @, untracked files not listed separately" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/jj" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  root) echo "$PWD" ;;
  "log -r @- --no-graph -T commit_id") echo 1234567890abcdef1234567890abcdef12345678 ;;
  "diff --git -r @") cat "${JJ_DIFF:-/nonexistent}" 2>/dev/null || true ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/jj"
  echo untracked >"$R/new"   # git would count it; jj has already snapshotted it into the diff
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$SCRIPTS/fingerprint.sh" --dir "$R"
  [ "$status" -eq 0 ]
  [ "$output" = "vcs=jj base=1234567890abcdef1234567890abcdef12345678 tree=clean fingerprint=1234567890ab-clean" ]
  echo "diff --git a/a b/a" >"$BATS_TEST_TMPDIR/diff"
  run env JJ_DIFF="$BATS_TEST_TMPDIR/diff" PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$SCRIPTS/fingerprint.sh" --dir "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == "vcs=jj base=1234567890abcdef1234567890abcdef12345678 tree="[0-9a-f]*" fingerprint=1234567890ab-"* ]]
  [[ "$output" != *"tree=clean"* ]]
}

@test "--show-env alone lists tool and input lines, then the signature, and no cache key" {
  echo lock >"$R/marker"
  run "$SCRIPTS/fingerprint.sh" --dir "$R" --show-env --tool "echo v1.2" --input marker --input gone --env FP_GAPS_UNSET
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "tool echo v1.2: v1.2" ]
  [ "${lines[1]}" = "input marker present" ]
  [ "${lines[2]}" = "input gone missing" ]
  [ "${lines[3]}" = "env FP_GAPS_UNSET unset" ]
  [[ "${lines[4]}" =~ ^envsig=[0-9a-f]{12}$ ]]
  [ "${#lines[@]}" -eq 5 ]
  sig=${lines[4]}
  # The signature follows the input's content.
  echo other >"$R/marker"
  run "$SCRIPTS/fingerprint.sh" --dir "$R" --show-env --tool "echo v1.2" --input marker --input gone --env FP_GAPS_UNSET
  [ "${lines[4]}" != "$sig" ]
}
