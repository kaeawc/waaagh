#!/usr/bin/env bats
# -h is read from the header block, not from a hard-coded line range (#184): a header that grows by
# a line needs no other edit, and no script prints a fixed `sed -n 'A,Bp' "$0"` range.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 99\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me
}

# The rule cli-contract.bats checks: the comment block after the shebang.
header() { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$1"; }

@test "a header that grows by a line is printed whole by -h, with no other edit" {
  copy="$BATS_TEST_TMPDIR/root"
  mkdir -p "$copy/skills/orchestrate"
  cp -R "$SCRIPTS" "$copy/skills/orchestrate/scripts"
  cp -R "$ROOT/dev" "$copy/"
  bad="" n=0
  for f in "$copy"/skills/orchestrate/scripts/*.sh "$copy"/dev/*.sh; do
    [[ "$(header "$f")" == *"Source, do not execute"* ]] && continue
    # One more line at the end of the header, and one in the middle.
    awk 'NR == 2 { print "# Added in the middle (#184)." } { print }' "$f" >"$f.new"
    awk -v h="$(header "$f.new" | wc -l)" '{ print } NR == h + 1 { print "# Added at the end (#184)." }' "$f.new" >"$f"
    rm "$f.new"
    out=$("$f" -h </dev/null 2>/dev/null) || { bad+=" ${f##*/}(exit)"; continue; }
    [ "$out" = "$(header "$f")" ] || bad+=" ${f##*/}(text)"
    [[ "$out" == *"Added in the middle"*"Added at the end (#184)." ]] || bad+=" ${f##*/}(missing line)"
    n=$((n + 1))
  done
  [ -z "$bad" ] || { echo "-h lost the grown header:$bad"; false; }
  [ "$n" -gt 40 ]
}

@test "no script prints its usage from a hard-coded line range of itself" {
  run grep -nE "sed -n ['\"][0-9]+,([0-9]+|\\$\\{?[a-z_]+\\}?)p['\"] \"\\\$0\"" \
    "$SCRIPTS"/*.sh "$ROOT"/dev/*.sh
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "orch_usage prints the caller's header and stops at the first non-comment line" {
  f="$BATS_TEST_TMPDIR/demo.sh"
  printf '#!/usr/bin/env bash\n# Usage: demo.sh\n#   a second line\nsource "%s/_lib.sh"\norch_usage\n# not header\n' \
    "$SCRIPTS" >"$f"
  chmod +x "$f"
  run "$f"
  [ "$status" -eq 0 ]
  [ "$output" = $'# Usage: demo.sh\n#   a second line' ]
}
