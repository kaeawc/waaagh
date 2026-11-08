#!/usr/bin/env bash
# Run the BATS suites in parallel, one bats process per file, longest files first. Prints one line
# per file (status, seconds, tests) and the full output of every file that failed.
#
# Usage: dev/test.sh [-j N] [--ignore-sigpipe] [--bashcov-shellopts] [FILE.bats...]
#   -j N                 files to run at once (default: the number of CPUs, at most 8)
#   --ignore-sigpipe     run every suite with SIGPIPE ignored, as GitHub's runners do (#77)
#   --bashcov-shellopts  export SHELLOPTS=errexit:errtrace:functrace:nounset:pipefail to every
#                        suite, as bashcov does under dev/coverage.sh (without its xtrace), so every
#                        bash a test starts inherits them: finds coverage-only failures before merge (#153)
#   FILE                 suites to run (default: every skills/orchestrate/scripts/*.bats)
# Env: BATS (default bats)
# Exit: 0 every suite passed | 1 a suite failed | 2 usage
# Suites must not share state: each test works under its own $BATS_TEST_TMPDIR (test_helper.bash).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

jobs="" sigpipe=default shellopts=""
while (($#)); do
  case "$1" in
    -j) jobs=${2:-}; shift 2 ;;
    -j*) jobs=${1#-j}; shift ;;
    --ignore-sigpipe) sigpipe=ignore; shift ;;
    --bashcov-shellopts) shellopts=errexit:errtrace:functrace:nounset:pipefail; shift ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "dev/test.sh: unknown argument: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [[ -z "$jobs" ]]; then
  jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
  ((jobs <= 8)) || jobs=8
fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "dev/test.sh: -j needs a positive number" >&2; exit 2; }
if (($#)); then files=("$@"); else files=("$root"/skills/orchestrate/scripts/*.bats); fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Longest first, by test count, so the slowest files do not start last.
for f in "${files[@]}"; do
  [[ -f "$f" ]] || { echo "dev/test.sh: no such suite: $f" >&2; exit 2; }
  printf '%s\t%s\n' "$(grep -c '^@test ' "$f" || true)" "$f"
done | sort -rn | cut -f2 >"$work/order"

start=$(date +%s)
# Each file: its output to <work>/<n>.out, then one result line "<rc> <secs> <file>".
export work sigpipe shellopts BATS="${BATS:-bats}"
n=0
while IFS= read -r f; do n=$((n + 1)); printf '%s\0%s\0' "$n" "$f"; done <"$work/order" | xargs -0 -n 2 -P "$jobs" bash -c '
  n=$1 f=$2 s=$(date +%s)
  if [[ "$sigpipe" == ignore ]]; then trap "" PIPE; fi   # inherited by bats and the scripts
  if [[ -n "$shellopts" ]]; then set -- env SHELLOPTS="$shellopts" "$BATS"; else set -- "$BATS"; fi
  "$@" "$f" >"$work/$n.out" 2>&1 && rc=0 || rc=$?
  printf "%s %s %s %s\n" "$rc" "$(( $(date +%s) - s ))" "$n" "$f" >>"$work/results"
' _ || true

failed=0 total=0 passed=0
while read -r rc secs n f; do
  ok=$(grep -c '^ok ' "$work/$n.out" || true)
  nok=$(grep -c '^not ok ' "$work/$n.out" || true)
  total=$((total + ok + nok)); passed=$((passed + ok))
  if [[ "$rc" == 0 ]]; then status=ok; else status=FAIL; failed=$((failed + 1)); fi
  printf '%-4s %4ss %4s tests  %s\n' "$status" "$secs" "$((ok + nok))" "${f#"$root"/}"
done < <(sort -k2,2rn "$work/results")

ran=$(wc -l <"$work/results" | tr -d ' ')
if [[ "$ran" != "$(wc -l <"$work/order" | tr -d ' ')" ]]; then
  echo "dev/test.sh: only $ran of $(wc -l <"$work/order" | tr -d ' ') suites reported a result" >&2
  failed=$((failed + 1))
fi
while read -r rc secs n f; do
  [[ "$rc" == 0 ]] && continue
  printf '\n===== %s (exit %s) =====\n' "${f#"$root"/}" "$rc"
  cat "$work/$n.out"
done <"$work/results"

printf '\n%s/%s tests passed in %s files, %ss wall, -j %s%s\n' "$passed" "$total" "$ran" "$(( $(date +%s) - start ))" "$jobs" \
  "$([[ "$sigpipe" == ignore ]] && echo ', SIGPIPE ignored')$([[ -n "$shellopts" ]] && echo ", SHELLOPTS=$shellopts")"
((failed == 0))
