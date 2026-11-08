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

# Every executable script: no script is exempt by name (#179). Only sourced libraries are left out,
# and they are recognised by their header ("Source, do not execute"), not listed. A script either
# holds the full contract below, or takes no arguments at all: then -h, --help and an unknown flag
# are each refused with exit 2 and a usage line on stderr. contract() says which, and anything else
# breaks the contract, so a script that gains or loses arguments cannot fall outside it unnoticed.
# The dev/ tools are held to the same contract (#159); they make no GitHub calls, so that part of
# the checks holds for them trivially.
scripts() {
  local f
  for f in "$SCRIPTS"/*.sh "$ROOT"/bin/*.sh "$ROOT"/dev/*.sh; do
    [[ "$(header "$f")" == *"Source, do not execute"* ]] && continue
    echo "$f"
  done
}

# The header: the comment block after the shebang, up to the first line that is not a comment.
header() { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$1"; }

# Which contract a script keeps: "flags" (-h prints its header) or "none" (refuses every argument).
contract() {
  local rc=0
  "$1" -h </dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then echo none; else echo flags; fi
}

# A script that takes no arguments refuses each of these with exit 2, a usage line on stderr and
# nothing on stdout.
refuses_all() {
  local f=$1 arg out err rc bad=""
  for arg in -h --help --no-such-flag; do
    out=$("$f" "$arg" </dev/null 2>"$BATS_TEST_TMPDIR/err") && rc=0 || rc=$?
    err=$(cat "$BATS_TEST_TMPDIR/err")
    [ "$rc" = 2 ] || { bad+=" ${f##*/}($arg:exit=$rc)"; continue; }
    [ -z "$out" ] || bad+=" ${f##*/}($arg:stdout)"
    [[ "$err" == *[Uu]sage:* ]] || bad+=" ${f##*/}($arg:no usage line)"
  done
  printf '%s' "$bad"
}

@test "-h prints exactly the script's header and exits 0, with no GitHub call" {
  bad=""
  while IFS= read -r f; do
    [ "$(contract "$f")" = flags ] || continue
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
    [ "$(contract "$f")" = flags ] || continue
    err=$("$f" --no-such-flag </dev/null 2>&1 >/dev/null) && rc=0 || rc=$?
    [ "$rc" = 2 ] || { bad+=" ${f##*/}(exit=$rc)"; continue; }
    [ -n "$err" ] || bad+=" ${f##*/}(silent)"
  done < <(scripts)
  [ -z "$bad" ] || { echo "contract broken:$bad"; false; }
  [ ! -s "$BATS_TEST_TMPDIR/gh-calls" ] || { echo "gh called:"; cat "$BATS_TEST_TMPDIR/gh-calls"; false; }
  [ ! -e "$ORCHESTRATE_STATE_DIR" ] || { echo "state written:"; find "$ORCHESTRATE_STATE_DIR"; false; }
}

@test "a script that takes no arguments refuses every argument with exit 2 and a usage line" {
  bad=""
  while IFS= read -r f; do
    [ "$(contract "$f")" = none ] || continue
    bad+=$(refuses_all "$f")
  done < <(scripts)
  [ -z "$bad" ] || { echo "contract broken:$bad"; false; }
  [ ! -s "$BATS_TEST_TMPDIR/gh-calls" ] || { echo "gh called:"; cat "$BATS_TEST_TMPDIR/gh-calls"; false; }
  [ ! -e "$ORCHESTRATE_STATE_DIR" ] || { echo "state written:"; find "$ORCHESTRATE_STATE_DIR"; false; }
}

@test "no script is exempt by name: only sourced libraries are left out" {
  run scripts
  [[ "$output" == *"/dev/test.sh"* ]]
  [[ "$output" == *"/dev/coverage.sh"* ]]
  [[ "$output" == *"/bench.sh"* ]]
  [[ "$output" == *"/lane-safety.sh"* ]]
  [[ "$output" != *"/_lib.sh"* ]]
  [[ "$output" != *"/_slots.sh"* ]]
}

@test "the checker tells the two contracts apart and catches a script that keeps neither" {
  d="$BATS_TEST_TMPDIR/fx"; mkdir -p "$d"
  printf '#!/bin/sh
# Usage: none.sh
[ $# -eq 0 ] || { echo "Usage: none.sh" >&2; exit 2; }
' >"$d/none.sh"
  printf '#!/bin/sh
# Usage: quiet.sh
[ $# -eq 0 ] || exit 2
' >"$d/quiet.sh"
  printf '#!/bin/sh
# Usage: ignores.sh
echo ran
' >"$d/ignores.sh"
  chmod +x "$d"/*.sh
  [ "$(contract "$d/none.sh")" = none ]
  [ -z "$(refuses_all "$d/none.sh")" ]
  [ "$(contract "$d/quiet.sh")" = none ]
  [[ "$(refuses_all "$d/quiet.sh")" == *"no usage line"* ]]
  # Ignoring arguments is not refusing them: it is held to the flags contract, and -h fails it.
  [ "$(contract "$d/ignores.sh")" = flags ]
  [ "$("$d/ignores.sh" -h)" != "$(header "$d/ignores.sh")" ]
}

@test "the hook takes no arguments: any argument but -h exits 2 with a usage line" {
  run "$SCRIPTS/lane-safety.sh" --no-such-flag </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"no arguments"* ]]
  [[ "$output" == *"Usage: lane-safety.sh"* ]]
}
