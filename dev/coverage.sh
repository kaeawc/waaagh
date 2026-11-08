#!/usr/bin/env bash
# Line coverage of the scripts under the BATS suites, measured with bashcov (Bash xtrace).
# Writes coverage/.resultset.json and prints one line per script, least covered first, then the total.
#
# Usage: dev/coverage.sh [-j N]
#        dev/coverage.sh --check FLOOR [--resultset FILE]
#   -j N         suites to run at once (passed to dev/test.sh; default 1: bashcov reads every trace
#                line through one pipe, so parallel suites only contend for it and run slower)
#   --check F    run no suites: compare an existing resultset to the floors in F (script<TAB>min%,
#                # comments and blank lines allowed). Fails when a script is below its floor or a
#                measured script has no row, and names each one. A row for a script that was not
#                measured is reported as stale but does not fail.
#   --resultset  the resultset --check reads (default coverage/.resultset.json)
# Env: GITHUB_STEP_SUMMARY  when set, the table (or the check's findings) is appended to it as Markdown.
# Needs: bashcov (gem install bashcov; not for --check), jq.
# Reading the numbers: xtrace reports only the first line of a command, so the continuation lines
# of a multi-line command (a jq program, a `\`-continued call) count as uncovered even when the
# command ran. The real figure is a few points above the total printed here.
# Exit: 0 report printed, or every floor held | 1 a suite failed (report still printed) | 2 usage or
#       bashcov missing | 3 --check: a script below its floor or with no floor row | 4 --check: the
#       resultset or floor file is missing or malformed
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

jobs=(-j 1)
floor="" resultset=""
while (($#)); do
  case "$1" in
    -j) jobs=(-j "${2:-}"); shift 2 ;;
    --check) [[ -n "${2:-}" ]] || { echo "dev/coverage.sh: --check needs a floor file" >&2; exit 2; }
      floor=$2; shift 2 ;;
    --resultset) [[ -n "${2:-}" ]] || { echo "dev/coverage.sh: --resultset needs a file" >&2; exit 2; }
      resultset=$2; shift 2 ;;
    -h | --help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "dev/coverage.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$resultset" || -n "$floor" ]] || { echo "dev/coverage.sh: --resultset needs --check" >&2; exit 2; }

# The measured scripts as [{f, rel, hit}], paths relative to the repo root whatever root the
# resultset was written under (so a resultset from CI or a fixture checks the same way).
ROWS='def rows($root):
  [.[] | .coverage | to_entries[]
   | {f: (.key | ltrimstr($root) | capture("(?:^|/)(?<f>skills/orchestrate/scripts/gh-shim/gh|skills/orchestrate/scripts/.*\\.sh|bin/[^/]*\\.sh)$").f),
      l: (.value.lines // .value)}
   | {f, rel: ([.l[] | select(. != null)] | length), hit: ([.l[] | select(. != null and . > 0)] | length)}];
def pct: if .rel == 0 then null else (.hit * 1000 / .rel | floor) / 10 end;'

# Reads its input to the end either way: a producer piped into it must never see a closed pipe.
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >/dev/null; fi; }

if [[ -n "$floor" ]]; then
  resultset=${resultset:-$root/coverage/.resultset.json}
  [[ -f "$resultset" ]] || { echo "dev/coverage.sh: no resultset at $resultset (run dev/coverage.sh first)" >&2; exit 4; }
  [[ -f "$floor" ]] || { echo "dev/coverage.sh: no floor file at $floor" >&2; exit 4; }
  # Floor rows: script<TAB>number, nothing else.
  bad=$(awk -F'\t' '/^[[:space:]]*(#|$)/ { next }
    NF != 2 || $2 !~ /^[0-9]+(\.[0-9]+)?$/ || $2 > 100 { print FILENAME ":" NR ": " $0 }' "$floor")
  [[ -z "$bad" ]] || { printf 'dev/coverage.sh: malformed floor row (want script<TAB>min%%):\n%s\n' "$bad" >&2; exit 4; }
  # One finding per line: "below\tpath\tpct\tfloor" | "missing\tpath\tpct" | "stale\tpath".
  findings=$(jq -r --arg root "$root/" --rawfile floors "$floor" "$ROWS"'
    (rows($root) | map({key: .f, value: pct}) | from_entries) as $got
    | ([$floors | split("\n")[] | select(test("^\\s*(#|$)") | not) | split("\t") | {key: .[0], value: (.[1] | tonumber)}]
       | from_entries) as $min
    | if ($got | length) == 0 then error("no measured scripts in the resultset") else . end
    | ($got | to_entries[] | select($min[.key] == null) | "missing\t\(.key)\t\(.value // "n/a")"),
      ($got | to_entries[] | select($min[.key] != null and .value != null and .value < $min[.key])
       | "below\t\(.key)\t\(.value)\t\($min[.key])"),
      ($min | keys[] | select(. as $k | $got | has($k) | not) | "stale\t\(.)")' "$resultset" 2>/dev/null) \
    || { echo "dev/coverage.sh: cannot read $resultset as a bashcov resultset" >&2; exit 4; }
  report=$(awk -F'\t' '
    $1 == "below"   { print "below floor: " $2 " at " $3 "% (floor " $4 "%)" }
    $1 == "missing" { print "no floor row: " $2 " at " $3 "% (add a row to the floor file)" }
    $1 == "stale"   { print "stale floor row: " $2 " was not measured" }' <<<"$findings")
  fails=$(grep -c -E '^(below|missing)' <<<"$findings" || true)
  if ((fails > 0)); then
    printf '%s\n' "$report" >&2
    echo "dev/coverage.sh: $fails coverage floor failure(s) against $floor" >&2
    { echo "### Coverage floor: $fails failure(s)"; echo; sed 's/^/- /' <<<"$report"; } | summary
    exit 3
  fi
  [[ -z "$report" ]] || printf '%s\n' "$report" >&2
  echo "coverage floors held ($floor)"
  { echo "### Coverage floor: every script at or above its floor"; [[ -z "$report" ]] || { echo; sed 's/^/- /' <<<"$report"; }; } | summary
  exit 0
fi

command -v bashcov >/dev/null || { echo "dev/coverage.sh: bashcov not found (gem install bashcov)" >&2; exit 2; }

cd "$root"
rm -rf coverage
rc=0
bashcov --root "$root" -- dev/test.sh ${jobs[@]+"${jobs[@]}"} >coverage.log 2>&1 || rc=$?
mkdir -p coverage && mv coverage.log coverage/test.log
[[ -f coverage/.resultset.json ]] || { echo "dev/coverage.sh: bashcov wrote no results (see coverage/test.log)" >&2; exit 1; }
((rc == 0)) || echo "dev/coverage.sh: a suite failed under coverage (see coverage/test.log)" >&2

table=$(jq -r --arg root "$root/" "$ROWS"'
  rows($root) | (map(.rel) | add) as $r | (map(.hit) | add) as $h
  | (sort_by(if .rel == 0 then 1 else .hit / .rel end)[]
     | "\(if .rel == 0 then "  n/a" else (pct | tostring) + "%" end)\t\(.hit)/\(.rel)\t\(.f)"),
    "total\t\($h)/\($r)\t\(($h * 1000 / $r | floor) / 10)%"' coverage/.resultset.json)
printf '%s\n' "$table"
{
  echo "### Line coverage (bashcov)"
  echo
  awk -F'\t' '$1 == "total" { print "**Total: " $3 "** (" $2 " lines)\n\n| Coverage | Lines | Script |\n|---:|---:|---|"; exit }' <<<"$table"
  awk -F'\t' '$1 != "total" { print "| " $1 " | " $2 " | `" $3 "` |" }' <<<"$table"
} | summary
exit $((rc == 0 ? 0 : 1))
