#!/usr/bin/env bats
# The spectra JSON contract (#370): skills/orchestrate/spectra-contract.tsv lists every field waaagh
# reads from spectra, and dev/spectra-contract.sh runs each command against a spectra binary and
# fails when a listed path is missing (CI: the pinned release). orch_spectra_require refuses a
# schema major waaagh does not know. Spectra is a stub here. Run: bats spectra-contract.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  CHECK="$ROOT/dev/spectra-contract.sh"
  B="$BATS_TEST_TMPDIR/bin"; mkdir -p "$B"
  # A spectra stub: `spectra SUB ...` prints $B/SUB.json and exits with $B/SUB.rc (default 0). Each
  # call is logged, with whether its --root held wt1 and its --pids process was alive.
  cat >"$B/spectra" <<'STUB'
#!/usr/bin/env bash
d=${BASH_SOURCE[0]%/*}
echo "$*" >>"$d/calls"
prev=""
for a in "$@"; do
  case "$prev" in
    --root) [ -d "$a/wt1" ] && echo "root-ok $a" >>"$d/calls" ;;
    --pids) kill -0 "$a" 2>/dev/null && echo "pid-alive $a" >>"$d/calls" ;;
  esac
  prev=$a
done
cat "$d/$1.json" 2>/dev/null
exit "$(cat "$d/$1.rc" 2>/dev/null || echo 0)"
STUB
  chmod +x "$B/spectra"
  W="$BATS_TEST_TMPDIR/work"; mkdir -p "$W"
  C="$BATS_TEST_TMPDIR/contract.tsv"
  printf '# a comment\n' >"$C"
}

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-x.sh}" "${4:--}" >>"$C"; }
check() { "$CHECK" --spectra "$B/spectra" --root "$W" --contract "$C" "$@"; }

@test "a path that is there passes; a renamed field fails, naming the row" {
  echo '{"load1": 1.5, "cause": {"kind": "roots"}, "top_cpu": [{"pid": 1}, {"pid": 2}]}' >"$B/load.json"
  row "load --json" .load1 host-load.sh
  row "load --json" .cause.kind host-load.sh
  row "load --json" ".top_cpu[].pid" host-load.sh
  run check
  [ "$status" -eq 0 ]
  [ "$output" = "spectra contract: 3 rows, 1 commands, 0 failed" ]
  [ "$(grep -c '^load --json$' "$B/calls")" -eq 1 ]   # one run per command
  # spectra renames cause.kind to cause.type, and pid to process_id in one element.
  echo '{"load1": 1.5, "cause": {"type": "roots"}, "top_cpu": [{"pid": 1}, {"process_id": 2}]}' >"$B/load.json"
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL host-load.sh .cause.kind (load --json): .cause.kind is missing"* ]]
  [[ "$output" == *"FAIL host-load.sh .top_cpu[].pid (load --json): .top_cpu[1].pid is missing"* ]]
  [[ "$output" == *"spectra contract: 3 rows, 1 commands, 2 failed" ]]
}

@test "null passes only on a null-ok row; key? may be absent, []? may be empty, [] may not" {
  echo '{"available_gb": null, "cause": {}, "by_root": [], "top": []}' >"$B/load.json"
  row "load --json" .available_gb h.sh null-ok
  row "load --json" .cause.worktree? h.sh
  row "load --json" ".by_root[]?.root" h.sh
  run check
  [ "$status" -eq 0 ]
  row "load --json" .available_gb strict.sh
  row "load --json" ".top[].pid" strict.sh
  row "load --json" .cause.kind strict.sh
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL strict.sh .available_gb (load --json): .available_gb is null"* ]]
  [[ "$output" == *"FAIL strict.sh .top[].pid (load --json): .top[] is empty, so its elements cannot be checked"* ]]
  [[ "$output" == *"FAIL strict.sh .cause.kind (load --json): .cause.kind is missing"* ]]
  [[ "$output" == *", 3 failed" ]]
  # Where a key? is present, the rest of the path is still checked.
  echo '{"interfaces": [{"name": "version"}, {"name": "load", "result_schema": {"name": "spectra.load"}}]}' >"$B/capabilities.json"
  printf '# c\n' >"$C"; row "capabilities --json" ".interfaces[].result_schema?.version" _lib.sh
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *".interfaces[1].result_schema.version is missing"* ]]
}

@test "a top-level array, a wrong type, a failed command and non-JSON each fail" {
  echo '[{"pid": 7, "main_class": "GradleDaemon"}]' >"$B/jvm.json"
  echo '{"holders": {"pid": 1}}' >"$B/owner.json"
  echo 'spectra: boom' >"$B/idle.json"; echo 9 >"$B/idle.rc"
  echo 'not json' >"$B/orphans.json"; echo 3 >"$B/orphans.rc"
  row "owner --under --json {root}" ".holders[].pid" _lib.sh
  row "idle --pids {pid} --json" ".result.holders[].pid" triage-tick.sh
  row "orphans --json --root {root}" ".groups[].worktree" triage-tick.sh
  run check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL _lib.sh .holders[].pid (owner --under --json {root}): .holders is object, not an array"* ]]
  [[ "$output" == *"FAIL triage-tick.sh .result.holders[].pid (idle --pids {pid} --json): exit 9: "* ]]
  [[ "$output" == *"FAIL triage-tick.sh .groups[].worktree (orphans --json --root {root}): not JSON: not json"* ]]
  # Exit 3 or 4 (found some, incomplete) is a verdict, not a failure. jvm needs java for its JVM.
  echo '{"groups": [{"worktree": "/w"}]}' >"$B/orphans.json"
  printf '# c\n' >"$C"; row "orphans --json --root {root}" ".groups[].worktree" triage-tick.sh
  run check
  [ "$status" -eq 0 ]
  if command -v java >/dev/null 2>&1; then
    row "jvm --json" ".[].pid" heavy-build-slot.sh
    row "jvm --json" ".[].java_home?" heavy-build-slot.sh
    run check
    [ "$status" -eq 0 ]
  fi
}

@test "{root} holds an idle process at wt1 ({pid}); both are gone when the check ends" {
  echo '{"holders": [{"pid": 1, "cwd": "/"}]}' >"$B/owner.json"
  echo '{"result": {"holders": [{"pid": 1}]}}' >"$B/idle.json"
  row "owner --under --json {root}" ".holders[].cwd" _lib.sh
  row "idle --pids {pid} --root {root} --json" ".result.holders[].pid" triage-tick.sh
  run check
  [ "$status" -eq 0 ]
  fx=$(sed -n 's/^owner --under --json //p' "$B/calls")
  pid=$(sed -n 's/^pid-alive //p' "$B/calls")
  [[ "$fx" == "$(cd "$W" && pwd -P)/.spectra-contract."* ]]
  grep -qxF "root-ok $fx" "$B/calls"
  [ -n "$pid" ]
  [ ! -e "$fx" ]
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$W")" ]
}

@test "a malformed row, a missing contract or a missing spectra is a usage error, before anything runs" {
  printf 'load --json\t.load1\n' >>"$C"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"contract.tsv:2: want command<TAB>.jq.path<TAB>script<TAB>-|null-ok"* ]]
  printf '# c\n' >"$C"; row "load --json" "load1"
  run check
  [ "$status" -eq 2 ]
  printf '# c\n' >"$C"; row "load --json" ".load1" x.sh maybe
  run check
  [ "$status" -eq 2 ]
  printf '# only comments\n' >"$C"
  run check
  [ "$status" -eq 2 ]
  [[ "$output" == *"lists no rows"* ]]
  run "$CHECK" --contract "$BATS_TEST_TMPDIR/nope.tsv"
  [ "$status" -eq 2 ]
  run "$CHECK" --spectra "$BATS_TEST_TMPDIR/nope" --contract "$C"
  [ "$status" -eq 2 ]
  run "$CHECK" --root
  [ "$status" -eq 2 ]
  [ ! -e "$B/calls" ]
  [ -z "$(ls -A "$W")" ]
}

# --- bash 3.2 (macOS /bin/bash) ----------------------------------------------------------------------

# A bash before 4.4, where "${a[@]}" of an empty array is unbound under set -u: $BASH32 (CI builds
# bash 3.2.57 and sets it), else /bin/bash when it is one (macOS). BASH32_REQUIRED=1 (CI) makes a
# missing one a failure, so the case cannot pass there by skipping.
old_bash() {
  local b
  for b in "${BASH32:-}" /bin/bash; do
    [[ -n "$b" && -x "$b" ]] || continue
    "$b" -c '((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4)))' && { echo "$b"; return 0; }
  done
  return 1
}

@test "the checker runs clean under bash 3.2: no unbound variable on the first row (#397)" {
  if ! OLD=$(old_bash); then
    [ "${BASH32_REQUIRED:-}" != 1 ] || { echo "BASH32_REQUIRED=1 but BASH32=${BASH32:-} is not a bash before 4.4"; false; }
    skip "no bash before 4.4 (set BASH32 to one)"
  fi
  # The premise: this bash does call an empty array unbound, so a pass below means the fix holds.
  run -127 "$OLD" -uc 'a=(); printf "%s\n" "${a[@]}"'
  [[ "$output" == *"a[@]: unbound variable"* ]]
  echo '{"load1": 1.5, "cause": {"kind": "roots"}}' >"$B/load.json"
  echo '{"version": "0.1.2"}' >"$B/version.json"
  row "load --json" .load1 host-load.sh
  row "version --json" .version _lib.sh
  row "load --json" .cause.kind host-load.sh
  run "$OLD" "$CHECK" --spectra "$B/spectra" --root "$W" --contract "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "spectra contract: 3 rows, 2 commands, 0 failed" ]
  [ "$(grep -c '^load --json$' "$B/calls")" -eq 1 ]   # still one run per command
  # A broken path still fails under it.
  row "load --json" .cause.worktree host-load.sh
  run "$OLD" "$CHECK" --spectra "$B/spectra" --root "$W" --contract "$C"
  [ "$status" -eq 1 ]
  [[ "$output" != *unbound* ]]
  [[ "$output" == *"FAIL host-load.sh .cause.worktree (load --json): .cause.worktree is missing"* ]]
}

@test "CI builds bash 3.2 and requires the bash 3.2 case before the suites run" {
  WF="$ROOT/.github/workflows/test.yml"
  build=$(grep -n 'name: Build bash 3.2' "$WF" | cut -d: -f1)
  suites=$(grep -n 'run: dev/test.sh' "$WF" | cut -d: -f1)
  [ -n "$build" ]
  [ -n "$suites" ]
  [ "$suites" -gt "$build" ]
  grep -q 'BASH32_REQUIRED=1' "$WF"
  grep -q 'BASH32=' "$WF"
}

# --- the contract itself ---------------------------------------------------------------------------

@test "the contract parses, names real scripts, and covers every spectra subcommand the scripts run" {
  T="$ROOT/skills/orchestrate/spectra-contract.tsv"
  bad=""
  while IFS=$'\t' read -r cmd path script null; do
    [[ -z "$cmd" || "$cmd" == \#* ]] && continue
    [ -f "$SCRIPTS/$script" ] || bad+=" no-script:$script"
    [[ "$null" == - || "$null" == null-ok ]] || bad+=" null:$path"
    [[ "$path" =~ ^(\.[a-z_][a-z0-9_]*\??|\.?\[\]\??)+$ ]] || bad+=" path:$path"
    # No command that could start emulators or reach outside the scratch directory.
    [[ "$cmd" != *--start-adb* ]] || bad+=" adb:$cmd"
  done <"$T"
  [ -z "$bad" ] || { echo "$bad"; false; }
  # Every `orch_spectra SUB` call in code (not comments) has rows for SUB from that script.
  calls=$(grep -HoE '^[^#]*orch_spectra [a-z]+' "$SCRIPTS"/*.sh | sed -E 's|^.*/([^/:]+):.*orch_spectra ([a-z]+)$|\1 \2|' | sort -u)
  [ -n "$calls" ]
  while read -r script sub; do
    awk -F'\t' -v s="$script" -v c="$sub" '$3 == s && ($1 == c || index($1, c " ") == 1) { f = 1 } END { exit !f }' "$T" ||
      bad+=" $script:$sub"
  done <<<"$calls"
  [ -z "$bad" ] || { echo "spectra calls with no contract rows:$bad"; false; }
  # The capabilities manifest is read by orch_spectra_require.
  grep -q $'^capabilities --json\t.interfaces\\[\\].name\t_lib.sh' "$T"
}

@test "CI runs the checker against the pinned spectra, after installing it" {
  WF="$ROOT/.github/workflows/test.yml"
  install=$(grep -n 'name: Install and check spectra' "$WF" | cut -d: -f1)
  contract=$(grep -n 'dev/spectra-contract.sh --spectra' "$WF" | cut -d: -f1)
  [ -n "$install" ]
  [ -n "$contract" ]
  [ "$contract" -gt "$install" ]
  grep -q 'SPECTRA_VERSION: v0.1.2' "$WF"
}

# --- schema majors in orch_spectra_require ----------------------------------------------------------

# caps_with NAME=SCHEMA@MAJOR...: the stub's capabilities --json, with those interfaces.
caps_with() {
  jq -n --args '{schema: {name: "spectra.capabilities", version: 1}, spectra_version: "0.1.2",
    interfaces: [$ARGS.positional[] | capture("^(?<n>[^=]+)=(?<s>[^@]+)@(?<v>[0-9]+)$")
      | {name: .n, output: "json", result_schema: {name: .s, version: (.v | tonumber)}}]}' "$@" >"$B/capabilities.json"
}
req() { SPECTRA="$B/spectra" bash -c 'source "$1/_lib.sh"; shift; orch_spectra_require "$@"' _ "$SCRIPTS" "$@"; }

@test "the schema majors waaagh reads are met; another major of a required capability is refused" {
  caps_with load=spectra.load@1 orphans=spectra.orphans@1 owner=spectra.owner@1 owner.under=spectra.owner.under@1 idle=spectra.idle@1 devices=spectra.devices@1
  run req load orphans owner idle devices
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # device-lock.sh reads spectra.devices v1 (#369).
  caps_with devices=spectra.devices@2
  run req devices
  [ "$status" -eq 1 ]
  [[ "$output" == *"spectra.devices v2 (waaagh reads v1)"* ]]
  caps_with load=spectra.load@2 orphans=spectra.orphans@1 owner=spectra.owner@1 owner.under=spectra.owner.under@1
  run req load
  [ "$status" -eq 1 ]
  [[ "$output" == "spectra: $B/spectra speaks a schema waaagh does not know: spectra.load v2 (waaagh reads v1). Update waaagh, or install a spectra it supports; install spectra 0.1.2 or newer:"* ]]
  # A script that needs only orphans is not stopped by the load schema it does not read.
  run req orphans
  [ "$status" -eq 0 ]
  # owner covers owner.under (proc_cwds reads it); spectra.owner (by port or file) waaagh does not read.
  caps_with owner=spectra.owner@3 owner.under=spectra.owner.under@1
  run req owner
  [ "$status" -eq 0 ]
  caps_with owner=spectra.owner@1 owner.under=spectra.owner.under@2
  run req owner
  [ "$status" -eq 1 ]
  [[ "$output" == *"spectra.owner.under v2 (waaagh reads v1)"* ]]
}

@test "a capabilities manifest at another major is refused; an interface with no result schema is not checked" {
  caps_with load=spectra.load@1
  jq '.schema.version = 2' "$B/capabilities.json" >"$B/c.tmp" && mv "$B/c.tmp" "$B/capabilities.json"
  run req load
  [ "$status" -eq 1 ]
  [[ "$output" == *"spectra.capabilities v2 (waaagh reads v1)"* ]]
  jq -n '{schema: {name: "spectra.capabilities", version: 1}, spectra_version: "0.1.2", interfaces: [{name: "load"}, {name: "version", output: "text"}]}' >"$B/capabilities.json"
  run req load version
  [ "$status" -eq 0 ]
}
