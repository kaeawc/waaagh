#!/usr/bin/env bats
# waaagh requires spectra (#329): _lib.sh's orch_spectra_require finds it, reads its capabilities
# once per process, and stops with one named error when spectra or a capability is missing. Every
# spectra call in the scripts goes through orch_spectra. The plugin registers spectra-mcp. Spectra
# is a stub here, as gh is: no test reads the real host. Run: bats spectra-lib.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  B="$BATS_TEST_TMPDIR/bin"; mkdir -p "$B"
  # A spectra stub: capabilities from $B/caps.json, `help` from $B/help.txt; every call logged.
  cat >"$B/spectra" <<'STUB'
#!/usr/bin/env bash
d=${BASH_SOURCE[0]%/*}
echo "$*" >>"$d/calls"
case "${1:-}" in
  capabilities) cat "$d/caps.json" ;;
  help) cat "$d/help.txt" 2>/dev/null || true ;;
  load) echo '{"verdict":"admit"}' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$B/spectra"
  caps version capabilities load
  printf 'Spectra\n\nSubcommands:\n  load       Admit, hold or back off\n  orphans    Find leftover processes\n\nExamples:\n  spectra load\n' >"$B/help.txt"
  export SPECTRA="$B/spectra"
}

# caps NAME...: the stub's capabilities --json, listing NAME... as interfaces.
caps() {
  jq -n --args '{schema: {name: "spectra.capabilities", version: 1}, spectra_version: "1.2.3",
    interfaces: [$ARGS.positional[] | {name: ., output: "json"}]}' "$@" >"$B/caps.json"
}
req() { bash -c 'source "$1/_lib.sh"; shift; orch_spectra_require "$@"' _ "$SCRIPTS" "$@"; }

@test "a capability spectra declares is met, and capabilities are read once per process" {
  run req load
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c 'source "$1/_lib.sh"; orch_spectra_require load && orch_spectra_require capabilities && orch_spectra load --json' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"admit"}' ]
  [ "$(grep -c '^capabilities --json$' "$B/calls")" -eq 2 ]   # one per process above
}

@test "until spectra declares its diagnostic commands, a subcommand spectra help lists is met (spectra#612)" {
  run req load orphans
  [ "$status" -eq 0 ]
  [ "$(grep -c '^help$' "$B/calls")" -eq 1 ]
  # An example line below the subcommand list is not a subcommand.
  run req spectra
  [ "$status" -eq 1 ]
}

@test "a missing capability is one named error with the install line" {
  run req load lineage spawns
  [ "$status" -eq 1 ]
  [ "$output" = "spectra: $B/spectra lacks: lineage spawns. Update it; install spectra: brew install kaeawc/tap/spectra, or build it from https://github.com/kaeawc/spectra (make build)" ]
}

@test "no spectra, or one without the capabilities contract, is an error, never a fallback" {
  SPECTRA="$BATS_TEST_TMPDIR/nope" run req load
  [ "$status" -eq 1 ]
  [[ "$output" == "spectra: not found ($BATS_TEST_TMPDIR/nope). waaagh requires it; install spectra:"* ]]
  echo 'not json' >"$B/caps.json"
  run req load
  [ "$status" -eq 1 ]
  [[ "$output" == *"gave no capability list"* ]]
  jq -n '{schema: {name: "something.else", version: 1}, interfaces: [{name: "load"}]}' >"$B/caps.json"
  run req load
  [ "$status" -eq 1 ]
  [[ "$output" == *"gave no capability list"* ]]
}

@test "every spectra call in the scripts goes through orch_spectra" {
  # The word spectra used as a command: at the start of a command, or after a pipe, ;, &, ( or $(.
  hits=$(grep -nE '(^|[|;&(])[[:space:]]*spectra[[:space:]]+[a-z]' "$SCRIPTS"/*.sh | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' |
    grep -v '^[^:]*/_lib\.sh:' || true)
  [ -z "$hits" ] || { echo "call spectra through orch_spectra: $hits"; false; }
  grep -qF 'orch_spectra() { "$(orch_spectra_bin)" "$@"; }' "$SCRIPTS/_lib.sh"
}

@test "the plugin registers spectra-mcp, and the docs name spectra as a requirement" {
  run jq -r '.mcpServers.spectra.command' "$ROOT/.mcp.json"
  [ "$output" = spectra-mcp ]
  grep -qF 'https://github.com/kaeawc/spectra' "$ROOT/README.md"
  grep -qF 'orch_spectra_require' "$ROOT/skills/orchestrate/SKILL.md"
}
