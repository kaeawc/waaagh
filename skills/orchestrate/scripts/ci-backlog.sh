#!/usr/bin/env bash
# Size the GitHub Actions backlog from jobs in recent runs, never from a run listing (#315).
# A `status=queued` run listing returns ghosts: runs created weeks ago that completed long since
# (70 of them once, back seven weeks; cancelling one answers "run is completed"). And a run whose
# own status is still queued or pending can already have jobs on runners. So this reads the runs
# created inside a window, whatever their status, and counts the queued and in-progress JOBS of
# every run not completed, grouped by the runner labels the job asked for.
#
# Usage: ci-backlog.sh [--repo OWNER/REPO] [--window MINUTES] [--max-runs N]
#   --window    count only runs created in the last MINUTES (default 360); older listings are ghosts
#               or stuck, and are not sized
#   --max-runs  read the jobs of at most N runs that are not completed, newest first (default 30:
#               one request each); the rest are reported as unread=<n>
# Output: one TSV row per label set, most queued first: `jobs<TAB><labels><TAB><queued><TAB><in_progress>`
#   (labels joined with `,`; `-` when a job names none), then one summary row:
#   `total<TAB>queued=<n><TAB>in_progress=<n><TAB>runs=<n><TAB>ghost=<n><TAB>unread=<n><TAB>truncated=yes|no`
#   runs: runs with a queued or in-progress job. ghost: runs listed as not completed whose jobs are
#   all done (or that have none yet). truncated=yes: the window held a full page of 100 runs, so
#   older runs inside it were not seen: narrow --window.
# Cancelling from such a listing: filter by created time the same way, and treat "run is completed"
# (HTTP 409) as done, not as a failure to retry.
# Exit: 0 sized | 3 the run list or a run's jobs could not be read | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority low

repo="" window=360 max_runs=30
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --window) window=${2:-}; shift 2 ;;
    --max-runs) max_runs=${2:-}; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "ci-backlog.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$window" =~ ^[1-9][0-9]*$ && "$max_runs" =~ ^[1-9][0-9]*$ ]] || { echo "ci-backlog.sh: --window and --max-runs need a positive number" >&2; exit 2; }
repo=$(orch_repo "$repo")

since=$(orch_iso $(($(orch_now) - window * 60)))
# actions/runs directly (not `gh run list`, which makes hidden extra requests), one page, filtered
# by created time on the server: the window is what keeps the ghosts out.
if ! raw=$("$here/gh-read.sh" --json -- api "repos/$repo/actions/runs?created=%3E%3D$since&per_page=100" 2>&1) ||
  ! runs=$(jq -ce '.workflow_runs | select(type == "array")' <<<"$raw" 2>/dev/null); then
  echo "unreadable run list: ${raw:0:200}" >&2
  exit 3
fi
truncated=no
[[ "$(jq 'length' <<<"$runs")" -lt 100 ]] || truncated=yes
# The server filter is trusted for the request size only: created_at is checked again here.
active=$(jq -r --arg since "$since" '[.[] | select(.status != "completed" and (.created_at // "") >= $since)]
  | sort_by(.created_at, .id) | reverse | .[].id' <<<"$runs")

jobs='[]' live=0 ghost=0 unread=0 n=0
for id in $active; do
  n=$((n + 1))
  if ((n > max_runs)); then unread=$((unread + 1)); continue; fi
  if ! out=$("$here/gh-read.sh" --json -- api "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100" 2>&1) ||
    ! mine=$(jq -ce '(.jobs | if type == "array" then . else error("no jobs array") end)
        | [.[] | select(.status == "queued" or .status == "in_progress")
        | {status, labels: ((.labels // []) | if length == 0 then "-" else join(",") end)}]' <<<"$out" 2>/dev/null); then
    echo "unreadable jobs of run $id: ${out:0:200}" >&2
    exit 3
  fi
  if [[ "$mine" == '[]' ]]; then ghost=$((ghost + 1)); continue; fi
  live=$((live + 1))
  jobs=$(jq -c --argjson add "$mine" '. + $add' <<<"$jobs")
done

jq -r '
  group_by(.labels)
  | map({labels: .[0].labels, queued: (map(select(.status == "queued")) | length),
      running: (map(select(.status == "in_progress")) | length)})
  | sort_by(-.queued, -.running, .labels)
  | .[] | "jobs\t\(.labels)\t\(.queued)\t\(.running)"' <<<"$jobs"
jq -r --arg live "$live" --arg ghost "$ghost" --arg unread "$unread" --arg trunc "$truncated" '
  "total\tqueued=\(map(select(.status == "queued")) | length)\tin_progress=\(map(select(.status == "in_progress")) | length)"
  + "\truns=\($live)\tghost=\($ghost)\tunread=\($unread)\ttruncated=\($trunc)"' <<<"$jobs"
