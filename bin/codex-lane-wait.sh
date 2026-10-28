#!/usr/bin/env bash
# Wait, for a bounded time, on ONE codex-lane-run.sh run and report only what matters: the run
# finished, its semantic progress changed, or nothing changed. Checks run here every --interval
# seconds without a model turn; call it again with the revision it printed to keep waiting.
#
# Usage: codex-lane-wait.sh --log RUN_LOG [--since REV] [--timeout SECS] [--interval SECS]
#   --log      the run's exact --log path (never a latest.* symlink: those move between runs)
#   --since    the last revision you saw; omit on the first call
#   --timeout  return "no-change" after this many seconds (default 540, under a 10-minute tool cap)
# Output (first line), then a bounded body:
#   done exit=<n>                   the run finished; body: the first 3000 chars of its final message
#   progress rev=<rev>              the state changed since --since; body: the state (bounded)
#   no-change rev=<rev> alive=<yes|no> elapsed=<s>   nothing new before --timeout; no body
# Exit: 0 done | 10 progress | 11 no-change | 2 usage or no such run
set -euo pipefail

usage() { sed -n '2,16p' "$0" >&2; exit 2; }
log='' since='' timeout=540 interval=2
while (($#)); do
  case "$1" in
    --log) log=${2:-}; shift 2 ;;
    --since) since=${2:-}; shift 2 ;;
    --timeout) timeout=${2:-}; shift 2 ;;
    --interval) interval=${2:-}; shift 2 ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) usage ;;
  esac
done
[[ -n $log && $timeout =~ ^[0-9]+$ && $interval =~ ^[0-9]+$ ]] || usage
((interval > 0)) || interval=1
case "$(basename "$log")" in
  latest.*) echo "codex-lane-wait: refusing a latest.* path; pass this run's own --log path" >&2; exit 2 ;;
esac
if [[ -L $log ]]; then echo "codex-lane-wait: refusing a symlink; pass this run's own --log path" >&2; exit 2; fi
[[ -e $log.spec ]] || { echo "codex-lane-wait: no run at $log (no $log.spec)" >&2; exit 2; }

body() { # FILE CHARS: the file, cut to CHARS characters
  local text
  text=$(cat "$1" 2>/dev/null || true)
  if ((${#text} > $2)); then text="${text:0:$2}...[truncated; full text in $1]"; fi
  printf '%s\n' "$text"
}
rev_now() { cat "$log.progress.rev" 2>/dev/null || echo none; }

start=$(date +%s)
while :; do
  if [[ -s $log.exit ]]; then
    echo "done exit=$(head -1 "$log.exit")"
    if [[ -f $log.final ]]; then body "$log.final" 3000; fi
    exit 0
  fi
  rev=$(rev_now)
  if [[ $rev != none && $rev != "$since" ]]; then
    echo "progress rev=$rev"
    body "$log.progress.state" 2500
    exit 10
  fi
  elapsed=$(($(date +%s) - start))
  if ((elapsed >= timeout)); then
    alive=$(sed -n 's/^Codex alive: //p' "$log.progress.state" 2>/dev/null | head -1)
    echo "no-change rev=$rev alive=${alive:-unknown} elapsed=${elapsed}s"
    exit 11
  fi
  sleep "$interval"
done
