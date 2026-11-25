#!/usr/bin/env bash
# Check the spectra JSON waaagh reads against a real spectra binary (#370). Runs each command in
# skills/orchestrate/spectra-contract.tsv once and checks every path listed for it, so a field that
# spectra renames or drops fails here (CI runs it against the pinned release) before a script
# reads null.
#
# Usage: dev/spectra-contract.sh [--spectra BIN] [--root DIR] [--contract FILE]
#   --spectra   the binary (default $SPECTRA, else spectra on PATH)
#   --root      where the scratch directory goes (default the checkout). It holds one idle process in
#               {root}/wt1 ({pid}), and a JVM there when a row runs `jvm` (java must be on PATH);
#               both are stopped and the directory removed on exit.
#   --contract  the contract (default skills/orchestrate/spectra-contract.tsv); its header says
#               what the columns and path marks mean.
# Output: one `FAIL <script> <path> (<command>): <why>` line per broken row, then
#   `spectra contract: <rows> rows, <commands> commands, <failed> failed`.
# Exit: 0 every path is there | 1 a path is missing, or a command failed | 2 usage, or a bad row
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=${SPECTRA:-spectra} root="" contract="$here/skills/orchestrate/spectra-contract.tsv"
while (($#)); do
  case "$1" in
    --spectra | --root | --contract)
      (($# > 1)) || { echo "spectra-contract.sh: $1 needs a value" >&2; exit 2; }
      case "$1" in --spectra) bin=$2 ;; --root) root=$2 ;; --contract) contract=$2 ;; esac
      shift 2 ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "spectra-contract.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -f "$contract" ]] || { echo "spectra-contract.sh: no contract at $contract" >&2; exit 2; }
command -v "$bin" >/dev/null 2>&1 || { echo "spectra-contract.sh: spectra not found ($bin)" >&2; exit 2; }
[[ -n "$root" ]] || root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
[[ -d "$root" ]] || { echo "spectra-contract.sh: --root $root is not a directory" >&2; exit 2; }

# Read and check the rows before starting anything.
pathre='^(\.[a-z_][a-z0-9_]*\??|\.?\[\]\??)+$'
rows=() cmds=() n=0
while IFS=$'\t' read -r cmd path script null rest || [[ -n "$cmd" ]]; do
  n=$((n + 1))
  [[ -z "$cmd" || "$cmd" == \#* ]] && continue
  if [[ -z "$script" || -n "$rest" || ! "$path" =~ $pathre || ! "$null" =~ ^(-|null-ok)$ ]]; then
    echo "spectra-contract.sh: $contract:$n: want command<TAB>.jq.path<TAB>script<TAB>-|null-ok" >&2
    exit 2
  fi
  rows+=("$cmd"$'\t'"$path"$'\t'"$script"$'\t'"$null")
  # cmds is empty on the first row: bash before 4.4 calls a bare "${cmds[@]}" unbound under set -u (#397).
  seen=""
  for c in ${cmds[@]+"${cmds[@]}"}; do [[ "$c" == "$cmd" ]] && { seen=1; break; }; done
  [[ -n "$seen" ]] || cmds+=("$cmd")
done <"$contract"
((${#rows[@]})) || { echo "spectra-contract.sh: $contract lists no rows" >&2; exit 2; }

# Fixtures: a scratch directory, an idle process in it, and a JVM when a row needs one.
fx=$(mktemp -d "$root/.spectra-contract.XXXXXX")
fx=$(cd "$fx" && pwd -P)
pids=()
cleanup() {
  local p
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
  rm -rf -- "$fx"
}
trap cleanup EXIT
mkdir "$fx/wt1" "$fx/out"
# Started from a subshell that exits at once, so its parent is pid 1 and `orphans` lists it.
(cd "$fx/wt1" && { nohup sleep 600 >/dev/null 2>&1 3>&- & echo $! >"$fx/pid"; })
pid=$(cat "$fx/pid"); pids+=("$pid")
if printf '%s\n' "${cmds[@]}" | grep -qE '^jvm( |$)'; then
  command -v java >/dev/null 2>&1 || { echo "spectra-contract.sh: a jvm row needs java on PATH to start a JVM to list" >&2; exit 2; }
  printf 'public class Idle { public static void main(String[] a) throws Exception { Thread.sleep(600000); } }\n' >"$fx/Idle.java"
  (cd "$fx/wt1" && { nohup java -Xmx32m -XX:+UseSerialGC "$fx/Idle.java" >/dev/null 2>&1 3>&- & echo $! >"$fx/jvm.pid"; })
  jpid=$(cat "$fx/jvm.pid"); pids+=("$jpid")
  # It is listed once the JVM is up (jps finds it).
  for _ in $(seq 1 30); do
    if ! command -v jps >/dev/null 2>&1 || jps -q 2>/dev/null | grep -qx "$jpid"; then break; fi
    sleep 0.5
  done
fi
sleep 1   # every fixture a little older than zero, for --min-age and CPU windows

# Run each command once. spectra exits 3 or 4 with a verdict (found some, incomplete); its JSON is the output.
to=()
if command -v timeout >/dev/null 2>&1; then to=(timeout 120); fi
failed=0 i=0
declare -a ok_cmd=()
for cmd in "${cmds[@]}"; do
  read -r -a words <<<"$cmd"
  argv=()
  for w in "${words[@]}"; do w=${w//\{root\}/$fx}; argv+=("${w//\{pid\}/$pid}"); done
  rc=0
  ${to[@]+"${to[@]}"} "$bin" "${argv[@]}" >"$fx/out/$i.json" 2>"$fx/out/$i.err" </dev/null || rc=$?
  if [[ ! "$rc" =~ ^[034]$ ]]; then
    ok_cmd[i]="exit $rc: $(head -c 300 "$fx/out/$i.err" | tr '\n' ' ')"
  elif ! jq -e . "$fx/out/$i.json" >/dev/null 2>&1; then
    ok_cmd[i]="not JSON: $(head -c 200 "$fx/out/$i.json" | tr '\n' ' ')"
  else
    ok_cmd[i]=""
  fi
  i=$((i + 1))
done

# check: the reasons a path does not hold in the input, at most three, none when it holds.
# shellcheck disable=SC2016 # jq program
check='
  def walk($s; $i; $at):
    if $i == ($s | length) then
      if . == null and ($nullok | not) then ["\($at) is null"] else [] end
    else $s[$i] as $g
    | if $g.k == "[]" then
        if type == "array" then
          if length == 0 then (if $g.opt then [] else ["\($at)[] is empty, so its elements cannot be checked"] end)
          else [to_entries[] | .key as $n | .value | walk($s; $i + 1; "\($at)[\($n)]")] | add end
        elif . == null and $g.opt then []
        else ["\($at) is \(type), not an array"] end
      elif type != "object" then ["\(if $at == "" then "." else $at end) is \(type), not an object"]
      elif has($g.k) then .[$g.k] | walk($s; $i + 1; "\($at).\($g.k)")
      elif $g.opt then []
      else ["\($at).\($g.k) is missing"] end
    end;
  [$path | scan("(\\[\\]|[a-z_][a-z0-9_]*)(\\?)?") | {k: .[0], opt: (.[1] == "?")}] as $s
  | walk($s; 0; "") | unique | .[:3][]'
for row in "${rows[@]}"; do
  IFS=$'\t' read -r cmd path script null <<<"$row"
  for i in "${!cmds[@]}"; do [[ "${cmds[i]}" == "$cmd" ]] && break; done
  why=${ok_cmd[i]}
  if [[ -z "$why" ]]; then
    why=$(jq -r --arg path "$path" --argjson nullok "$([[ "$null" == null-ok ]] && echo true || echo false)" "$check" "$fx/out/$i.json" | paste -sd ';' - | sed 's/;/; /g')
  fi
  [[ -z "$why" ]] && continue
  echo "FAIL $script $path ($cmd): $why"
  failed=$((failed + 1))
done
echo "spectra contract: ${#rows[@]} rows, ${#cmds[@]} commands, $failed failed"
((failed == 0))
