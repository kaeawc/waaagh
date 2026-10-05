#!/usr/bin/env bash
# Extract failure lines with a small context window from a long log, so the orchestrator and
# costly review models see an excerpt plus a path instead of a full transcript.
#
# Usage: excerpt.sh LOG [CONTEXT_LINES=3] [MAX_LINES=120]
set -euo pipefail

log=${1:?usage: excerpt.sh LOG [CONTEXT_LINES] [MAX_LINES]}
context=${2:-3}
max=${3:-120}

[[ -f "$log" ]] || { echo "excerpt.sh: no such file: $log" >&2; exit 2; }

pattern='(^|[^[:alnum:]_])(error|errors|failed|failure|fail|fatal|panic|exception|traceback|timed out|not ok|assertion)([^[:alnum:]_]|$)'
total=$(wc -l <"$log" | tr -d ' ')

# Strip ANSI colour codes and GitHub Actions timestamps before matching.
matches=$(LC_ALL=C sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' "$log" |
  grep -n -i -E -C "$context" "$pattern" || true)

if [[ -z "$matches" ]]; then
  echo "(no failure lines matched)"
else
  shown=$(printf '%s\n' "$matches" | head -n "$max")
  printf '%s\n' "$shown"
  matched=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
  if ((matched > max)); then
    echo "... truncated: showing $max of $matched excerpt lines"
  fi
fi
echo "full log: $log ($total lines)"
