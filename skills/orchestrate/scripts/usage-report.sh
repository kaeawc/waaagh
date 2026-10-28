#!/usr/bin/env bash
# Aggregate codex lane usage receipts (*.usage.json, written by bin/codex-lane-usage.sh) into a
# compact table, with usage next to how the lanes ended, so lower usage never reads as better when
# the work was not delivered. Read-only. Counts come only from the receipts; unknown stays unknown.
#
# Usage: usage-report.sh [--dir DIR]... [--since ISO8601]
#   --dir    where to look (default ~/.claude/codex-lanes; repeatable)
#   --since  only runs that finished at or after this time
# Output (TSV, with a header): model  status  runs  unknown_usage  input  cached_input  output
#   reasoning_output  duration_s
#   status is the wrapper's verified lane status (complete, partial, ...) or "unmarked"; one row per
#   model and status, then a "total" row. Token columns sum only runs whose receipt has the count;
#   unknown_usage is how many runs had no usage events. A receipt with another schema is skipped
#   and counted on stderr.
set -euo pipefail

dirs=() since=""
while (($#)); do
  case "$1" in
    --dir) dirs+=("$2"); shift 2 ;;
    --since) since=$2; shift 2 ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "usage-report.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
((${#dirs[@]})) || dirs=("$HOME/.claude/codex-lanes")

files=()
for d in "${dirs[@]}"; do
  [[ -d $d ]] || continue
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$d" -name '*.usage.json' -type f -print0)
done

printf 'model\tstatus\truns\tunknown_usage\tinput\tcached_input\toutput\treasoning_output\tduration_s\n'
((${#files[@]})) || exit 0
# One receipt per run file, so a run is never counted twice even if two --dir values overlap.
printf '%s\n' "${files[@]}" | sort -u | while IFS= read -r f; do jq -c --arg f "$f" '. + {_file: $f}' "$f" 2>/dev/null || true; done |
  jq -rs --arg since "$since" '
    (map(select(.schema != "waaagh.lane-usage/1")) | length) as $skipped
    | (if $skipped > 0 then ("skipped \($skipped) receipts with another schema\n" | stderr) else null end) as $_
    | map(select(.schema == "waaagh.lane-usage/1"))
    | map(select($since == "" or ((.finished_at // "") >= $since)))
    | unique_by(._file)
    | def sum($k): [.[] | .usage[$k] | numbers] | if length == 0 then "-" else add end;
      def row($m; $s): [$m, $s, length, (map(select(.usage_source == "none")) | length),
        sum("input_tokens"), sum("cached_input_tokens"), sum("output_tokens"),
        sum("reasoning_output_tokens"), ([.[] | .duration_s | numbers] | add // 0)];
    (group_by([.model // "?", .lane_status // "unmarked"])[]
      | row(.[0].model // "?"; .[0].lane_status // "unmarked")),
    row("total"; "-")
    | @tsv'
