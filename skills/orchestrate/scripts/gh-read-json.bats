#!/usr/bin/env bats
# gh-read.sh --json: one jq both checks and prints the body (#177). The body comes out byte for byte
# as gh wrote it, it is JSON exactly when `jq -e .` says so, and a closed reader is not a retry.
# Run: bats gh-read-json.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_FAKE_SLEEP=1 GH_READ_JITTER=0
  # gh prints $FX/body as is (after response headers when asked for them) and logs each call.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
for a in "$@"; do [ "$a" != --include ] || printf 'HTTP/2.0 200 OK\r\nX-GitHub-Request-Id: AB:1\r\n\r\n'; done
cat "$FX/body"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

calls() { wc -l <"$FX/calls" | tr -d ' '; }
# same_bytes ARGS...: gh-read.sh's stdout equals $FX/body byte for byte, in one call
same_bytes() {
  : >"$FX/calls"
  "$SCRIPTS/gh-read.sh" --json "$@" >"$FX/out" 2>"$FX/err"
  cmp "$FX/body" "$FX/out"
  [ ! -s "$FX/err" ]
  [ "$(calls)" -eq 1 ]
}

@test "--json prints the body byte for byte: newlines, CRLF, BOM, big numbers, several values" {
  for b in '{"a":1}' '{"a":1}\n' '{"a":1}\r\n\n\n' '\xef\xbb\xbf{"a":1}' '{"n":100000000000000000000000001}' \
           '1e1000' '[1][2]\n' '[1]\n[2]\n' '"x" "y"' 'true' '0' '""' '{"a":"caf\xc3\xa9 \xf0\x9f\x98\x80"}\n'; do
    printf "$b" >"$FX/body"
    same_bytes -- pr list --repo o/r
    same_bytes -- api repos/o/r/pulls   # with or without a final newline (#186)
  done
}

@test "--json keeps invalid UTF-8 and a literal U+FFFD byte for byte (the cat fallback)" {
  printf '{"a":"\xff\xfe"}\n' >"$FX/body"
  same_bytes -- pr list --repo o/r
  same_bytes -- api repos/o/r/pulls
  printf '{"a":"\xef\xbf\xbd"}' >"$FX/body"
  same_bytes -- pr list --repo o/r
}

@test "--json still calls empty, null-last, false-last, truncated and trailing-garbage output malformed" {
  for b in '' '\n' 'null' 'false' '[1] null' '[1] false\n' '[1,2' '[1] x' '<html>x</html>' '{"a":1}\x00'; do
    printf "$b" >"$FX/body"
    : >"$FX/calls"
    run "$SCRIPTS/gh-read.sh" --json --tries 2 -- pr list --repo o/r
    [ "$status" -eq 8 ]
    [[ "$output" == *"gh-read: malformed status=200"* ]]
    [ "$(calls)" -eq 2 ]
  done
  printf 'null [1]' >"$FX/body"   # the last value decides, as with jq -e .
  same_bytes -- pr list --repo o/r
}

@test "--json: a reader that closes early is not taken for malformed output (no retry)" {
  awk 'BEGIN { printf "["; for (i = 0; i < 50000; i++) printf "%s{\"n\":%d}", (i ? "," : ""), i; print "]" }' >"$FX/body"
  : >"$FX/calls"
  run bash -c '"$1" --json -- pr list --repo o/r 2>"$2" | { IFS= read -r -n 1 _; }; echo "rc=${PIPESTATUS[0]}"' _ "$SCRIPTS/gh-read.sh" "$FX/err"
  [[ "$output" == rc=* && "$output" != "rc=0" ]]   # 141, or an EPIPE error where SIGPIPE was ignored on entry
  [ "$(calls)" -eq 1 ]
  [ "$(grep -c malformed "$FX/err" || true)" -eq 0 ]
  : >"$FX/calls"
  run bash -c 'trap "" PIPE; "$1" --json -- pr list --repo o/r 2>"$2" | { IFS= read -r -n 1 _; }; echo "rc=${PIPESTATUS[0]}"' _ "$SCRIPTS/gh-read.sh" "$FX/err"
  [ "$output" != "rc=0" ]
  [ "$(calls)" -eq 1 ]
  [ "$(grep -c malformed "$FX/err" || true)" -eq 0 ]
}
