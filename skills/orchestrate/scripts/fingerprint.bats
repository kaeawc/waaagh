#!/usr/bin/env bats
# fingerprint.sh --fingerprint-only (#290): just the identity, no summary line to parse.
# Run: bats scripts/fingerprint.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  R="$BATS_TEST_TMPDIR/repo"; mkdir -p "$R"
  git -C "$R" init -q; echo a >"$R/a"; git -C "$R" add a; git -C "$R" commit -qm init
}

@test "--fingerprint-only prints exactly the fingerprint of the summary line" {
  run "$SCRIPTS/fingerprint.sh" --dir "$R"
  [ "$status" -eq 0 ]
  want=${output##* fingerprint=}
  run "$SCRIPTS/fingerprint.sh" --dir "$R" --fingerprint-only
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [[ "$output" =~ ^[0-9a-f]{12}-clean$ ]]
}

@test "--fingerprint-only follows a dirty tree" {
  clean=$("$SCRIPTS/fingerprint.sh" --dir "$R" --fingerprint-only)
  echo b >>"$R/a"
  run "$SCRIPTS/fingerprint.sh" --dir "$R" --fingerprint-only
  [ "$status" -eq 0 ]
  [ "$output" != "$clean" ]
  [[ "$output" =~ ^[0-9a-f]{12}-[0-9a-f]{12}$ ]]
}

@test "--fingerprint-only outside a checkout exits non-zero with nothing on stdout" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" "$SCRIPTS/fingerprint.sh" --dir "$BATS_TEST_TMPDIR/plain" --fingerprint-only
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "--fingerprint-only cannot combine with --key or --show-env" {
  run --separate-stderr "$SCRIPTS/fingerprint.sh" --dir "$R" --fingerprint-only --key x
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"cannot combine"* ]]
  run --separate-stderr "$SCRIPTS/fingerprint.sh" --dir "$R" --show-env --fingerprint-only
  [ "$status" -eq 2 ]
}

@test "no script parses fingerprint= out of fingerprint.sh output" {
  cd "$SCRIPTS"
  [ "$(grep -n "fingerprint=//\|\* fingerprint=" -- *.sh *.bats | grep -v '^fingerprint.bats' | grep -c . || true)" -eq 0 ]
}
