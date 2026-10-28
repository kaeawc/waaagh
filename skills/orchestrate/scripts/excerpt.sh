#!/usr/bin/env bash
# Extract failure lines with a small context window from a long log, so the orchestrator and
# costly review models see an excerpt plus a path instead of a full transcript.
#
# Usage: excerpt.sh LOG [CONTEXT_LINES=3] [MAX_LINES=120] [MAX_BYTES=16384]
#   Output lines look like grep -n: "N:matched line", "N-context line", "--" between groups.
#   Every line is clipped to EXCERPT_LINE_BYTES (default 400) and the whole excerpt to MAX_BYTES.
#   Roughly the first two thirds of the budget go to the first failures and the rest to the
#   last ones, which usually hold the final summary. An exact repeat of an already shown
#   failure line is folded (counted, not shown). The full log path is always printed last.
set -euo pipefail

log=${1:?usage: excerpt.sh LOG [CONTEXT_LINES] [MAX_LINES] [MAX_BYTES]}
context=${2:-3}
max=${3:-120}
max_bytes=${4:-16384}
line_bytes=${EXCERPT_LINE_BYTES:-400}

[[ -f "$log" ]] || { echo "excerpt.sh: no such file: $log" >&2; exit 2; }
for n in "$context" "$max" "$max_bytes" "$line_bytes"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "excerpt.sh: not a number: $n" >&2; exit 2; }
done

total=$(wc -l <"$log" | tr -d ' ')

# Strip ANSI colour codes and GitHub Actions timestamps, then select in one streaming pass.
# awk reads the whole input, so no writer upstream is cut off with SIGPIPE.
LC_ALL=C sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' "$log" |
  LC_ALL=C awk -v ctx="$context" -v max="$max" -v max_bytes="$max_bytes" -v line_bytes="$line_bytes" '
    BEGIN {
      pat = "(^|[^[:alnum:]_])(error|errors|failed|failure|fail|fatal|panic|exception|traceback|timed out|not ok|assertion)([^[:alnum:]_]|$)"
      tail_n = (max >= 3) ? int(max / 3) : 0
      head_n = max - tail_n
      head_budget = (tail_n > 0) ? int(max_bytes * 2 / 3) : max_bytes
      last = 0; after = 0; n_out = 0; nhead = 0; head_bytes = 0; head_open = 1; folded = 0
    }
    function clip(s,   extra) {
      if (length(s) <= line_bytes) return s
      extra = length(s) - line_bytes
      return substr(s, 1, line_bytes) "...[+" extra " bytes]"
    }
    function emit(n, sep, s,   row) {
      if (last > 0 && n > last + 1) push("--")
      row = n sep clip(s)
      push(row)
      last = n
    }
    function push(row) {
      n_out++
      if (head_open && nhead < head_n && head_bytes + length(row) + 1 <= head_budget) {
        head[++nhead] = row; head_bytes += length(row) + 1
        return
      }
      head_open = 0
      if (tail_n > 0) ring[n_out % tail_n] = row
    }
    {
      line = $0
      if (tolower(line) ~ pat) {
        key = substr(line, 1, line_bytes)
        if (key in seen) { folded++ }
        else {
          seen[key] = 1
          start = NR - ctx; if (start <= last) start = last + 1; if (start < 1) start = 1
          for (i = start; i < NR; i++) emit(i, "-", before[i % (ctx + 1)])
          emit(NR, ":", line)
          after = ctx
        }
      } else if (after > 0) {
        emit(NR, "-", line); after--
      }
      if (ctx > 0) before[NR % (ctx + 1)] = line
    }
    END {
      if (n_out == 0) {
        print (folded > 0) ? "(only repeated failure lines matched)" : "(no failure lines matched)"
        exit
      }
      for (i = 1; i <= nhead; i++) print head[i]
      # Fill the rest of the line and byte budget with the newest rows, oldest of them first.
      bytes = head_bytes; ntail = 0
      first_tail = nhead + 1
      if (n_out - tail_n + 1 > first_tail) first_tail = n_out - tail_n + 1
      for (i = n_out; i >= first_tail; i--) {
        row = ring[i % tail_n]
        if (bytes + length(row) + 1 > max_bytes) break
        bytes += length(row) + 1; ntail++
      }
      omitted = n_out - nhead - ntail
      if (omitted > 0) print "... " omitted " excerpt lines omitted ..."
      for (i = n_out - ntail + 1; i <= n_out; i++) print ring[i % tail_n]
      if (omitted > 0) print "... truncated: showing " (nhead + ntail) " of " n_out " excerpt lines"
      if (folded > 0) print "... folded " folded " repeated failure lines"
    }'
echo "full log: $log ($total lines)"
