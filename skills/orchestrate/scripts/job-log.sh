#!/usr/bin/env bash
# Fetch ONE GitHub Actions job's log through the job-scoped REST endpoint, which works while the
# parent workflow is still running (gh run view --log refuses until the whole run completes). Saves
# it under a run/attempt/job path and prints an excerpt. Read-only on GitHub.
#
# Usage: job-log.sh [--repo OWNER/REPO] --job ID
#        job-log.sh [--repo OWNER/REPO] --run ID [--attempt N] --name JOB_NAME
#        job-log.sh [--repo OWNER/REPO] --pr N --check CHECK_NAME
#                   [--out DIR] [--context N] [--max-lines N] [--fresh-minutes N]
#   --run/--name  pages through every job of that run attempt (default: the latest attempt)
#   --pr/--check  takes the job from the check's details URL in the PR's status roll-up
#   --out         default <state dir>/logs; the log lands at <out>/<run>/<attempt>/<job>.log
# First line, then a body:
#   available <path> <bytes>      body: excerpt.sh output (exit 0)
#   running <status>              the job has not finished; body: its steps and URL (exit 10)
#   not-yet-available             completed, but GitHub has no log yet (404 or an empty body within
#                                 --fresh-minutes of completion, default 10); retry later (exit 11)
#   expired                       the log is gone (410, or 404 long after completion) (exit 12)
#   forbidden                     403 from GitHub; the token cannot read it (exit 13)
#   transient                     5xx, network or signed-URL failure after one retry (exit 14)
#   unresolved <why>              no such job, check or run (exit 15)
# Error details go to <out>/<run>/<attempt>/<job>.diag, never into the .log; an error or empty
# response is never saved as a log. Live output of a running job is not available over REST: open
# the job's URL in an authenticated browser.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" job="" run="" attempt="" name="" pr="" check="" out="" context=3 max=120 fresh=10
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --job) job=$2; shift 2 ;;
    --run) run=$2; shift 2 ;;
    --attempt) attempt=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --check) check=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --context) context=$2; shift 2 ;;
    --max-lines) max=$2; shift 2 ;;
    --fresh-minutes) fresh=$2; shift 2 ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "job-log.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$job" && -z "$run$name" && -z "$pr$check" ]] || { [[ -n "$run$name" ]] && [[ -z "$run" || -z "$name" ]]; } ||
  { [[ -n "$pr$check" ]] && [[ -z "$pr" || -z "$check" ]]; }; then
  sed -n '2,24p' "$0" >&2; exit 2
fi
repo=$(orch_repo "$repo")
[[ -n "$out" ]] || out="$(orch_state_dir "$repo")/logs"
unresolved() { echo "unresolved $*"; exit 15; }

# --- resolve the job id ------------------------------------------------------------------------
if [[ -z "$job" && -n "$pr" ]]; then
  rollup=$("$here/gh-read.sh" --json -- pr view "$pr" --repo "$repo" --json statusCheckRollup 2>/dev/null) || unresolved "PR $pr not readable"
  job=$(jq -r --arg c "$check" '[.statusCheckRollup[]? | select((.name // .context) == $c)
          | (.detailsUrl // .targetUrl // "") | (capture("/actions/runs/[0-9]+/job/(?<j>[0-9]+)") | .j)?]
        | last // empty' <<<"$rollup")
  [[ -n "$job" ]] || unresolved "no Actions job for check '$check' on PR $pr"
elif [[ -z "$job" ]]; then
  if [[ -z "$attempt" ]]; then
    attempt=$("$here/gh-read.sh" -- api "repos/$repo/actions/runs/$run" --jq .run_attempt 2>/dev/null) || unresolved "run $run not readable"
  fi
  # Every page of the attempt's jobs; a name that ran more than once resolves to the newest job.
  job=$("$here/gh-read.sh" -- api --paginate "repos/$repo/actions/runs/$run/attempts/$attempt/jobs?per_page=100" --jq '.jobs[]' 2>/dev/null |
    jq -rs --arg n "$name" '[.[] | select(.name == $n)] | max_by(.id) | .id // empty') || unresolved "jobs of run $run not readable"
  [[ -n "$job" ]] || unresolved "no job named '$name' in run $run attempt $attempt"
fi

meta=$("$here/gh-read.sh" --json -- api "repos/$repo/actions/jobs/$job" 2>/dev/null) || unresolved "job $job not readable"
run=$(jq -r .run_id <<<"$meta")
attempt=$(jq -r '.run_attempt // 1' <<<"$meta")
dir="$out/$run/$attempt"
mkdir -p "$dir"
log="$dir/$job.log" diag="$dir/$job.diag"

status=$(jq -r .status <<<"$meta")
if [[ "$status" != completed ]]; then
  echo "running $status"
  jq -r '"job \(.name) (\(.id)) run \(.run_id) attempt \(.run_attempt // 1): \(.html_url)",
         (.steps // [] | .[:40][] | "  \(.number). \(.name): \(.status)\(if .conclusion then " / " + .conclusion else "" end)")' <<<"$meta"
  echo "Live output is not available over REST; open the URL above in an authenticated browser."
  exit 10
fi

# --- fetch the log (gh follows the short-lived redirect itself; the signed URL is never kept) --
age_min=$(jq -r --argjson now "$(orch_now)" '((.completed_at // "") | fromdateiso8601? // null) as $t
  | if $t == null then 0 else (($now - $t) / 60 | floor) end' <<<"$meta")
fetch() { gh api "repos/$repo/actions/jobs/$job/logs" >"$log.tmp" 2>"$diag.tmp"; }
classify() { # -> available | not-yet-available | expired | forbidden | transient
  local code
  code=$(grep -oE 'HTTP [0-9]{3}' "$diag.tmp" | tail -1 | cut -c6-)
  case "$code" in
    403) if grep -qiE 'signature|expired|AuthenticationFailed' "$diag.tmp"; then echo transient; else echo forbidden; fi ;;
    404) if ((age_min < fresh)); then echo not-yet-available; else echo expired; fi ;;
    410) echo expired ;;
    5??) echo transient ;;
    *) echo transient ;;
  esac
}
verdict=""
for try in 1 2; do
  if fetch; then
    if [[ -s "$log.tmp" ]]; then verdict=available; break; fi
    echo "empty response body" >>"$diag.tmp"
    verdict=$( ((age_min < fresh)) && echo not-yet-available || echo expired)
    break
  fi
  verdict=$(classify)
  [[ "$verdict" == transient && "$try" == 1 ]] || break
  sleep "${JOB_LOG_RETRY_SECONDS:-2}"
done

if [[ "$verdict" != available ]]; then
  rm -f "$log.tmp"
  { echo "job $job run $run attempt $attempt: $verdict at $(orch_iso "$(orch_now)")"; cat "$diag.tmp"; } >>"$diag"
  rm -f "$diag.tmp"
  echo "$verdict"
  echo "diagnostics: $diag"
  case "$verdict" in not-yet-available) exit 11 ;; expired) exit 12 ;; forbidden) exit 13 ;; *) exit 14 ;; esac
fi
rm -f "$diag.tmp"
mv "$log.tmp" "$log"
echo "available $log $(wc -c <"$log" | tr -d ' ')"
"$here/excerpt.sh" "$log" "$context" "$max"
