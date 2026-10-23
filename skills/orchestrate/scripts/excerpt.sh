#!/usr/bin/env bash
# Extract failure lines with a small context window from a long log, so the orchestrator and
# costly review models see an excerpt plus a path instead of a full transcript.
#
# Usage: excerpt.sh LOG [CONTEXT_LINES=3] [MAX_LINES=120] [MAX_BYTES=8000]
set -euo pipefail

log=${1:?usage: excerpt.sh LOG [CONTEXT_LINES] [MAX_LINES] [MAX_BYTES]}
context=${2:-3}
max=${3:-120}
maxbytes=${4:-8000}
linebytes=400

[[ -f "$log" ]] || { echo "excerpt.sh: no such file: $log" >&2; exit 2; }

pattern='(^|[^[:alnum:]_])(error|errors|failed|failure|fail|fatal|panic|exception|traceback|timed out|not ok|assertion)([^[:alnum:]_]|$)'
total=$(wc -l <"$log" | tr -d ' ')

# Strip ANSI colour codes and GitHub Actions timestamps before matching. The selection streams
# through awk, which keeps draining its input after the budget is spent so no upstream stage is
# killed by SIGPIPE (grep exit 1 on no match is tolerated). Output is bounded by MAX_LINES,
# MAX_BYTES in total and LINE_BYTES per line.
LC_ALL=C sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' "$log" |
  { grep -n -i -E -C "$context" "$pattern" || true; } |
  LC_ALL=C awk -v max="$max" -v maxbytes="$maxbytes" -v linebytes="$linebytes" '
    {
      if (length($0) > linebytes) $0 = substr($0, 1, linebytes) " ...[line cut]"
      if (shown < max && bytes + length($0) + 1 <= maxbytes) {
        print; shown++; bytes += length($0) + 1
      }
      matched++
    }
    END {
      if (!matched) print "(no failure lines matched)"
      else if (matched > shown)
        printf "... truncated: showing %d of %d excerpt lines (budget %d lines, %d bytes)\n", shown, matched, max, maxbytes
    }'
echo "full log: $log ($total lines)"
