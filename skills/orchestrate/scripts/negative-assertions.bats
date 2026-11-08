#!/usr/bin/env bats
# Lint the suites for negative assertions that assert nothing (#134). Bash's `set -e`, which bats
# uses to fail a test, ignores a command negated with `!`, so `! grep -q x file` mid-test passes
# whether or not x is there. Only the last command of a body is checked that way. Write
# `run ! cmd`, `[ "$(grep -c x file || true)" -eq 0 ]` or `if cmd; then false; fi` instead.
# Run: bats negative-assertions.bats

setup() {
  load test_helper
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

# Print FILE:LINE: text for every `! cmd` (at the start of a command, or after &&, || or ;) inside
# a @test or function body that is not the body's last command. Heredoc bodies are skipped.
lint_negations() {
  awk '
    function flush() { if (pend != "") { print pend; pend = "" } }
    FNR == 1 { inbody = 0; hd = ""; pend = ""; cont = 0 }
    hd != "" { if ($0 ~ "^[ \t]*" hd "[ \t]*$") hd = ""; next }
    !inbody && /^(@test .*|[A-Za-z_][A-Za-z0-9_]*\(\)) *\{ *$/ { inbody = 1; pend = ""; cont = 0; next }
    !inbody { next }
    /^\}/ { inbody = 0; pend = ""; next }
    {
      line = $0
      if (match(line, /<<-?[ \t]*["\047]?[A-Za-z_]+["\047]?/)) {
        tag = substr(line, RSTART, RLENGTH)
        sub(/<<-?[ \t]*["\047]?/, "", tag); sub(/["\047]$/, "", tag); hd = tag
      }
      if (line ~ /^[ \t]*(#|$)/) next
      if (!cont) flush()
      if ((!cont && line ~ /^[ \t]*![ \t]/) || line ~ /(&&|\|\||;)[ \t]*![ \t]/) pend = FILENAME ":" FNR ": " line
      cont = (line ~ /\\$/)
    }
  ' "$@"
}

@test "no suite or helper has a mid-body '! cmd' that set -e would ignore (#134)" {
  run lint_negations "$DIR"/*.bats "$DIR"/*.bash
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "rewrite as 'run ! cmd' or '[ \"\$(grep -c ... || true)\" -eq 0 ]':"; echo "$output"; false; }
}

@test "the lint flags a mid-test '! cmd' and '&& ! cmd', and spares the last command and heredocs" {
  f="$BATS_TEST_TMPDIR/sample.bats"
  cat >"$f.in" <<'SAMPLE'
%test "mid" {
  ! grep -q a /dev/null
  true
}
%test "chained" {
  true && ! false
  true
}
%test "last is fine" {
  true
  ! false
}
%test "continued last is fine" {
  true
  ! grep -q a \
    /dev/null
}
%test "run is fine" {
  run ! false
  [ ! -f /nonexistent ]
  true
}
%test "heredoc is skipped" {
  cat <<EOF
! not a command
EOF
  true
}
helper() {
  ! false
  true
}
SAMPLE
  sed 's/^%test /@test /' "$f.in" >"$f"  # bats rewrites @test lines even inside a heredoc
  run lint_negations "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "$f:2: "* ]]
  [[ "${lines[1]}" == "$f:6: "* ]]
  [[ "${lines[2]}" == "$f:30: "* ]]
}
