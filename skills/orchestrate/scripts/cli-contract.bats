#!/usr/bin/env bats
# The command-line contract every script shares: -h prints exactly its header comment and exits 0,
# and an unknown flag is refused with exit 2 and a message, before any GitHub call or state write.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Any gh call fails the contract: the usage checks must come before network reads.
  printf '#!/bin/sh\necho "gh $*" >>"%s/gh-calls"\nexit 99\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me
}

# Every executable script with a usage header. Sourced libraries, the benchmark (no arguments) and
# the hook (reads a payload on stdin, no arguments) are not command-line tools in this sense.
# The dev/ tools are held to the same contract (#159); they make no GitHub calls, so that part of
# the checks holds for them trivially.
scripts() {
  local f
  for f in "$SCRIPTS"/*.sh "$ROOT"/bin/*.sh "$ROOT"/dev/*.sh; do
    case "${f##*/}" in _*.sh | bench.sh | lane-safety.sh) continue ;; esac
    echo "$f"
  done
}

# The header: the comment block after the shebang, up to the first line that is not a comment.
header() { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$1"; }

@test "-h prints exactly the script's header and exits 0, with no GitHub call" {
  bad=""
  while IFS= read -r f; do
    for flag in -h --help; do
      out=$("$f" "$flag" </dev/null 2>/dev/null) && rc=0 || rc=$?
      if [ "$rc" != 0 ]; then bad+=" ${f##*/}($flag:exit=$rc)"; continue; fi
      [ "$out" = "$(header "$f")" ] || bad+=" ${f##*/}($flag:text)"
    done
  done < <(scripts)
  [ -z "$bad" ] || { echo "contract broken:$bad"; false; }
  [ ! -s "$BATS_TEST_TMPDIR/gh-calls" ] || { cat "$BATS_TEST_TMPDIR/gh-calls"; false; }
}

@test "an unknown flag is refused with exit 2 and a message, before any GitHub call or state write" {
  bad=""
  while IFS= read -r f; do
    err=$("$f" --no-such-flag </dev/null 2>&1 >/dev/null) && rc=0 || rc=$?
    [ "$rc" = 2 ] || { bad+=" ${f##*/}(exit=$rc)"; continue; }
    [ -n "$err" ] || bad+=" ${f##*/}(silent)"
  done < <(scripts)
  [ -z "$bad" ] || { echo "contract broken:$bad"; false; }
  [ ! -s "$BATS_TEST_TMPDIR/gh-calls" ] || { echo "gh called:"; cat "$BATS_TEST_TMPDIR/gh-calls"; false; }
  [ ! -e "$ORCHESTRATE_STATE_DIR" ] || { echo "state written:"; find "$ORCHESTRATE_STATE_DIR"; false; }
}

@test "the contract covers the dev/ tools" {
  run scripts
  [[ "$output" == *"/dev/test.sh"* ]]
  [[ "$output" == *"/dev/coverage.sh"* ]]
}

@test "the hook takes no arguments: any argument exits 1 with a message" {
  run "$SCRIPTS/lane-safety.sh" --no-such-flag </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"no arguments"* ]]
}
