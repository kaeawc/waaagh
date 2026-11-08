#!/usr/bin/env bash
# Line coverage of the scripts under the BATS suites, measured with bashcov (Bash xtrace).
# Writes coverage/.resultset.json and prints one line per script, least covered first, then the total.
#
# Usage: dev/coverage.sh [-j N]
#   -j N   suites to run at once (passed to dev/test.sh; default 1: bashcov reads every trace line
#          through one pipe, so parallel suites only contend for it and run slower)
# Needs: bashcov (gem install bashcov), jq.
# Reading the numbers: xtrace reports only the first line of a command, so the continuation lines
# of a multi-line command (a jq program, a `\`-continued call) count as uncovered even when the
# command ran. The real figure is a few points above the total printed here.
# Exit: 0 report printed | 1 a suite failed (report still printed) | 2 usage or bashcov missing
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

jobs=(-j 1)
while (($#)); do
  case "$1" in
    -j) jobs=(-j "${2:-}"); shift 2 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "dev/coverage.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v bashcov >/dev/null || { echo "dev/coverage.sh: bashcov not found (gem install bashcov)" >&2; exit 2; }

cd "$root"
rm -rf coverage
rc=0
bashcov --root "$root" -- dev/test.sh ${jobs[@]+"${jobs[@]}"} >coverage.log 2>&1 || rc=$?
mkdir -p coverage && mv coverage.log coverage/test.log
[[ -f coverage/.resultset.json ]] || { echo "dev/coverage.sh: bashcov wrote no results (see coverage/test.log)" >&2; exit 1; }
((rc == 0)) || echo "dev/coverage.sh: a suite failed under coverage (see coverage/test.log)" >&2

jq -r --arg root "$root/" '
  [.[] | .coverage | to_entries[]
   | {f: (.key | ltrimstr($root)), l: (.value.lines // .value)}
   | select(.f | test("^(skills/orchestrate/scripts/.*\\.sh|skills/orchestrate/scripts/gh-shim/gh|bin/.*\\.sh)$"))
   | {f, rel: ([.l[] | select(. != null)] | length), hit: ([.l[] | select(. != null and . > 0)] | length)}]
  | (map(.rel) | add) as $r | (map(.hit) | add) as $h
  | (sort_by(if .rel == 0 then 1 else .hit / .rel end)[]
     | "\(if .rel == 0 then "  n/a" else ((.hit * 1000 / .rel | floor) / 10 | tostring | . + "%") end)\t\(.hit)/\(.rel)\t\(.f)"),
    "total\t\($h)/\($r)\t\(($h * 1000 / $r | floor) / 10)%"' coverage/.resultset.json
exit $((rc == 0 ? 0 : 1))
