#!/usr/bin/env bats
# Lint the suites for pipes into a reader that can exit before its input ends (#140): `| grep -q`,
# `| grep -l`, `| grep -m N`, `| head`. The reader quits at its first match; a slow producer (as
# under bashcov) then writes into a closed pipe and dies of SIGPIPE, and under pipefail the test
# fails on timing alone. Write `[[ "$(cmd)" == *x* ]]`, `run cmd` and match "$output",
# `grep -c x >/dev/null` (reads to the end), `sed -n 1,7p` or "${out%%$'\n'*}" instead.
# The companion lint for `! cmd` mid-test is negative-assertions.bats (#134).
# Run: bats early-exit-pipes.bats

setup() {
  load test_helper
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
}

# Print FILE:LINE: text for every early-exit reader on a pipe, whether on the same line as the `|`
# or at the start of the line after one that ends in `|`. Comments and heredoc bodies are skipped.
lint_pipes() {
  awk '
    function reader(s) {
      # an early-exit flag among the options that follow grep (before its pattern)
      return s ~ /^[ \t]*(e|f)?grep([ \t]+-[^ \t]+)*[ \t]+(-[A-Za-z]*[qlLm]|--quiet|--silent|--max-count|--files-with)/ \
        || s ~ /^[ \t]*head([ \t]|$)/
    }
    FNR == 1 { hd = ""; piped = 0 }
    hd != "" { if ($0 ~ "^[ \t]*" hd "[ \t]*$") hd = ""; next }
    {
      line = $0
      if (match(line, /(^|[^<])<<-?[ \t]*["\047]?[A-Za-z_]+["\047]?/)) {
        tag = substr(line, RSTART, RLENGTH)
        sub(/^[^<]*<<-?[ \t]*["\047]?/, "", tag); sub(/["\047]$/, "", tag); hd = tag
      }
      if (line ~ /^[ \t]*(#|$)/) next
      bad = piped && reader(line)
      rest = line
      while (!bad && (i = index(rest, "|")) > 0) {
        nxt = substr(rest, i + 1, 1)
        if (nxt == "|") { rest = substr(rest, i + 2); continue }
        rest = substr(rest, i + 1)
        if (reader(rest)) bad = 1
      }
      if (bad) print FILENAME ":" FNR ": " line
      piped = (line ~ /[^|]\|[ \t]*\\?[ \t]*$/)
    }
  ' "$@"
}

@test "no suite or helper pipes into grep -q, grep -l, grep -m or head (#140)" {
  run lint_pipes "$DIR"/*.bats "$DIR"/*.bash
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "rewrite so the reader consumes all its input (see this file's header):"; echo "$output"; false; }
}

@test "the lint flags each early-exit reader on a pipe, and spares readers that read to the end" {
  f="$BATS_TEST_TMPDIR/sample.bats"
  cat >"$f.in" <<'SAMPLE'
%test "flagged" {
  cmd -h | grep -q x
  cmd | grep -qE 'a|b'
  cmd | grep -E -m1 x
  cmd | grep -l x
  cmd|head -1
  cmd | egrep --quiet x
  cmd |
    grep -q x
}
%test "spared" {
  cmd | grep -c x >/dev/null
  grep -q x file
  cmd || grep -q x file
  [ "$(cmd | sed -n 1p)" = a ]
  cmd | grep -v x | wc -l
  echo "a|b" >f
  # cmd | grep -q x
  cat <<EOF
cmd | grep -q x
EOF
  cat <<<"$x"
  true
}
SAMPLE
  sed 's/^%test /@test /' "$f.in" >"$f"  # bats rewrites @test lines even inside a heredoc
  run lint_pipes "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
  for n in 2 3 4 5 6 7 9; do [[ "$output" == *"$f:$n: "* ]]; done
}
