#!/usr/bin/env bash
# Cumulative campaign counters in the ledger (<state dir>/campaign.json, key .counters), so a tick
# report reads its numbers from disk instead of recalling them after a compaction. Which counters a
# report uses, and when to bump them: reporting.md.
#
# Usage: counters.sh bump NAME [--by N] [--repo OWNER/REPO]
#        counters.sh show [NAME] [--repo OWNER/REPO]
#   bump  add N (default 1) to NAME for today (UTC) and for the whole campaign; prints
#         NAME_today=N and NAME_total=M
#   show  day=YYYY-MM-DD, then NAME_today=N and NAME_total=M for every counter, sorted by name
#         (or for NAME alone, 0 and 0 when it was never bumped)
# NAME is lower case letters, digits and underscores (merged, dispatched, closed, owner_blockers).
# Today's counts restart at 0 on the first bump or show of a new UTC day; totals never reset.
# Exit: 0 ok | 2 usage
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

usage() { sed -n '2,14p' "$0" >&2; exit 2; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" by=1 name=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --by) by=$2; shift 2 ;;
    -h | --help) usage ;;
    -*) echo "counters.sh: unknown argument: $1" >&2; exit 2 ;;
    *) [[ -z "$name" ]] || { echo "counters.sh: one NAME only" >&2; exit 2; }; name=$1; shift ;;
  esac
done
case "$cmd" in
  bump) [[ -n "$name" ]] || { echo "counters.sh: bump needs a NAME" >&2; exit 2; } ;;
  show) ;;
  *) usage ;;
esac
if [[ -n "$name" && ! "$name" =~ ^[a-z0-9_]+$ ]]; then
  echo "counters.sh: NAME is lower case letters, digits and underscores: $name" >&2; exit 2
fi
[[ "$by" =~ ^[0-9]+$ ]] || { echo "counters.sh: --by is a non-negative integer" >&2; exit 2; }

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
ledger="$state/campaign.json"
# campaign.sh owns the ledger's creation (it starts the campaign clock).
[[ -f "$ledger" ]] || "$here/campaign.sh" path --repo "$repo" >/dev/null
day=$(orch_iso "$(orch_now)")
day=${day%%T*}

# Roll today's counts over to a new day, then (bump) add to NAME.
roll='.counters //= {} | if .counters.day != $day then .counters.day = $day | .counters.today = {} else . end
  | .counters.today //= {} | .counters.total //= {}'
if [[ "$cmd" == bump ]]; then
  filter="$roll"' | .counters.today[$n] = ((.counters.today[$n] // 0) + $by)
    | .counters.total[$n] = ((.counters.total[$n] // 0) + $by)'
else
  filter="$roll"
fi
tmp=$(mktemp "$ledger.XXXXXX")
jq --arg day "$day" --arg n "$name" --argjson by "$by" "$filter" "$ledger" >"$tmp" && mv "$tmp" "$ledger"

if [[ "$cmd" == show ]]; then echo "day=$day"; fi
jq -r --arg n "$name" '.counters as $c
  | (if $n == "" then (($c.total | keys) + ($c.today | keys) | unique) else [$n] end)[]
  | "\(.)_today=\($c.today[.] // 0)\n\(.)_total=\($c.total[.] // 0)"' "$ledger"
