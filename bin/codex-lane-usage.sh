#!/usr/bin/env bash
# Compact usage receipt for one codex lane run, built from the usage events the installed codex
# CLI actually wrote to its --json log. Nothing is estimated: a count the log does not carry is
# null (unknown), never inferred from bytes, and no cost is computed.
#
# Usage: codex-lane-usage.sh write --log LOG [--model M] [--effort E] [--tier T] [--exit N]
#                                  [--outcome TEXT] [--started EPOCH] [--finished EPOCH]
#        codex-lane-usage.sh mark --log LOG --status complete|partial|timeout|unavailable|refused
# write  creates LOG.usage.json (schema waaagh.lane-usage/1) and prints its path. The runner calls
#        it when a run ends. Token counts are the sum over `turn.completed` events' `usage`
#        objects (one per turn, so nothing is counted twice); numeric usage keys this script does
#        not know are summed under other_usage. No usage events: usage_source "none", counts null.
# mark   records the lane's verified status (from the wrapper's report) in the receipt, so usage
#        can be read next to delivery. A retried run is a separate run with its own receipt.
set -euo pipefail

sub=${1:-}
if [[ -n $sub ]]; then shift; fi
log='' model='' effort='' tier='' code='' outcome='' started='' finished='' status=''
while (($#)); do
  case "$1" in
    --log) log=${2:-}; shift 2 ;;
    --model) model=${2:-}; shift 2 ;;
    --effort) effort=${2:-}; shift 2 ;;
    --tier) tier=${2:-}; shift 2 ;;
    --exit) code=${2:-}; shift 2 ;;
    --outcome) outcome=${2:-}; shift 2 ;;
    --started) started=${2:-}; shift 2 ;;
    --finished) finished=${2:-}; shift 2 ;;
    --status) status=${2:-}; shift 2 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) sed -n '2,17p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $log ]] || { sed -n '2,17p' "$0" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "codex-lane-usage: jq not found; no receipt" >&2; exit 0; }
receipt="$log.usage.json"

case "$sub" in
  write)
    num_or_null() { if [[ $1 =~ ^[0-9]+$ ]]; then echo "$1"; else echo null; fi; }
    { [[ -f $log ]] && cat "$log" || true; } |
      jq -nR --arg log "$log" --arg model "$model" --arg effort "$effort" --arg tier "$tier" \
        --argjson exit "$(num_or_null "$code")" --arg outcome "$outcome" \
        --argjson started "$(num_or_null "$started")" --argjson finished "$(num_or_null "$finished")" '
        def known: ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"];
        def iso: if . == null then null else todate end;
        [inputs | fromjson? | objects] as $ev
        | [$ev[] | select(.type == "turn.completed") | .usage | objects] as $u
        | def total($k): [$u[] | .[$k] | numbers] | if length == 0 then null else add end;
        {schema: "waaagh.lane-usage/1",
         model: (if $model == "" then null else $model end),
         effort: (if $effort == "" then null else $effort end),
         service_tier: (if $tier == "" then null else $tier end),
         exit: $exit, outcome: (if $outcome == "" then null else $outcome end),
         started_at: ($started | iso), finished_at: ($finished | iso),
         duration_s: (if $started != null and $finished != null then $finished - $started else null end),
         turns: ([$ev[] | select(.type == "turn.completed")] | length),
         failed_turns: ([$ev[] | select(.type == "turn.failed")] | length),
         usage_source: (if ($u | length) > 0 then "codex-jsonl:turn.completed" else "none" end),
         usage: (known | map({key: ., value: total(.)}) | from_entries),
         other_usage: ([$u[] | to_entries[] | select((.key | IN(known[]) | not) and (.value | type) == "number")]
                       | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries),
         lane_status: null,
         evidence: {log: $log, final: ($log + ".final"), spec: ($log + ".spec"), stderr: ($log + ".stderr")}}' \
        >"$receipt.tmp"
    mv "$receipt.tmp" "$receipt"
    echo "$receipt"
    ;;
  mark)
    case "$status" in complete | partial | timeout | unavailable | refused) ;; *) echo "codex-lane-usage: bad --status: $status" >&2; exit 2 ;; esac
    [[ -f $receipt ]] || { echo "codex-lane-usage: no receipt at $receipt" >&2; exit 3; }
    jq --arg s "$status" '.lane_status = $s' "$receipt" >"$receipt.tmp" && mv "$receipt.tmp" "$receipt"
    echo "marked $status $receipt"
    ;;
  *) sed -n '2,17p' "$0" >&2; exit 2 ;;
esac
