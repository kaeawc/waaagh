#!/usr/bin/env bats
# Lint the suites for assertions that assert nothing. Bash's `set -e`, which bats uses to fail a
# test, ignores a command negated with `!` (#134) and every command of an `a && b` list but the
# last (#140), so `! grep -q x file` or `[ "$status" -eq 0 ] && [ "$output" = ok ]` mid-test
# passes whether or not x is there or the status is 0. Only the last command of a body is checked
# that way. Write `run ! cmd`, `[ "$(grep -c x file || true)" -eq 0 ]` or
# `if cmd; then false; fi` instead of `! cmd`, and one assertion per line instead of `a && b`.
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

# Print FILE:LINE: text for every `a && b` list made only of assertions ([, [[, grep, test) inside
# a @test or function body that is not the body's last command and has no `||` to catch a failure
# (#140): set -e ignores every command of an && list but the last, so a failing `a` passes.
# `&&` inside [[ ]], $( ), quotes or a comment does not count. Heredoc bodies are skipped.
lint_chains() {
  awk '
    function analyze(s,   i, c, c2, q, dq, br, pd, n, seg, cur) {
      q = 0; dq = 0; br = 0; pd = 0; n = 0; cur = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); c2 = substr(s, i, 2)
        if (q) { cur = cur c; if (c == "\047") q = 0; continue }
        if (dq) { cur = cur c; if (c == "\\") { cur = cur substr(s, i + 1, 1); i++ } else if (c == "\"") dq = 0; continue }
        if (c == "\047") { q = 1; cur = cur c; continue }
        if (c == "\"") { dq = 1; cur = cur c; continue }
        if (c == "\\") { cur = cur c2; i++; continue }
        if (c2 == "[[") { br++; cur = cur c2; i++; continue }
        if (c2 == "]]" && br > 0) { br--; cur = cur c2; i++; continue }
        if (c == "(") pd++
        if (c == ")" && pd > 0) pd--
        if (br == 0 && pd == 0) {
          if (c2 == "||" || c == ";" || (c == "#" && substr(s, i - 1, 1) ~ /[ \t]/)) return 0
          if (c2 == "&&") { seg[++n] = cur; cur = ""; i++; continue }
        }
        cur = cur c
      }
      seg[++n] = cur
      if (n < 2) return 0
      for (i = 1; i <= n; i++) if (seg[i] !~ /^[ \t]*(\[|\[\[|grep|test)[ \t]/) return 0
      return 1
    }
    function flush() { if (pend != "") { print pend; pend = "" } }
    FNR == 1 { inbody = 0; hd = ""; pend = ""; cont = 0 }
    hd != "" { if ($0 ~ "^[ \t]*" hd "[ \t]*$") hd = ""; next }
    !inbody && /^(@test .*|[A-Za-z_][A-Za-z0-9_]*\(\)) *\{ *$/ { inbody = 1; pend = ""; cont = 0; next }
    !inbody { next }
    /^\}/ { inbody = 0; pend = ""; next }
    {
      line = $0
      if (match(line, /(^|[^<])<<-?[ \t]*["\047]?[A-Za-z_]+["\047]?/)) {
        tag = substr(line, RSTART, RLENGTH)
        sub(/^[^<]*<<-?[ \t]*["\047]?/, "", tag); sub(/["\047]$/, "", tag); hd = tag
      }
      if (line ~ /^[ \t]*(#|$)/) next
      if (!cont) { flush(); cmd = ""; first = FILENAME ":" FNR ": " line }
      part = line; sub(/\\$/, "", part)
      cmd = cmd " " part
      cont = (line ~ /(\\|&&|\|\||\|)[ \t]*$/)
      if (!cont && analyze(cmd)) pend = first
    }
  ' "$@"
}

@test "no suite or helper has a mid-body '! cmd' that set -e would ignore (#134)" {
  run lint_negations "$DIR"/*.bats "$DIR"/*.bash
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "rewrite as 'run ! cmd' or '[ \"\$(grep -c ... || true)\" -eq 0 ]':"; echo "$output"; false; }
}

@test "no suite or helper has a mid-body 'a && b' assertion list that set -e would ignore (#140)" {
  run lint_chains "$DIR"/*.bats "$DIR"/*.bash
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "put each assertion on its own line, or end the list with '|| { echo ...; false; }':"; echo "$output"; false; }
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

@test "the lint flags a mid-test assertion list 'a && b', and spares the last command, || and actions" {
  f="$BATS_TEST_TMPDIR/sample.bats"
  cat >"$f.in" <<'SAMPLE'
%test "flagged" {
  [ "$status" -eq 0 ] && [ "$output" = ok ]
  grep -q a f && grep -q b f
  [ -n "$x" ] &&
    [[ "$x" == y ]]
  true
}
%test "spared" {
  [[ "$a" == x && "$b" == y ]]
  [ -f x ] && rm x
  [ "$s" -eq 0 ] && [ "$o" = ok ] || { echo "got $o"; false; }
  [ "$s" -eq 0 ] && [ "$o" = ok ] ||
    { echo "got $o"; false; }
  [ "$(a && b)" = "x && y" ]
  [ a ] # && [ b ]
  cat <<EOF
[ a ] && [ b ]
EOF
  [ "$status" -eq 0 ] && [ "$output" = last ]
}
SAMPLE
  sed 's/^%test /@test /' "$f.in" >"$f"  # bats rewrites @test lines even inside a heredoc
  run lint_chains "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "$f:2: "* ]]
  [[ "${lines[1]}" == "$f:3: "* ]]
  [[ "${lines[2]}" == "$f:4: "* ]]
}
