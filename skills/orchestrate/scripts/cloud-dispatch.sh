#!/usr/bin/env bash
# Cloud dispatch bookkeeping: one no-click cloud session per cloud-ready issue, started by a
# run-once routine (RemoteTrigger create) from the main session. This script never calls
# RemoteTrigger, and its one GitHub write is the REPAIR-START marker of record --kind repair
# (repair-writer.sh mark); it keeps the todo queue and the dispatch ledger (both survive
# compaction), renders the short per-issue brief, builds the create payload, and paces creates.
# The standard briefs can instead live in the target repository (.claude/briefs/implement.md and
# repair.md, versioned and changed by PR); the dispatched prompt is then one line (--brief-ref).
#
# Usage: cloud-dispatch.sh queue add|drop N... [--no-blocker-check] [--repo OWNER/REPO]
#        cloud-dispatch.sh queue list [--repo OWNER/REPO]
#        cloud-dispatch.sh next [--count K] [--repo OWNER/REPO]
#        cloud-dispatch.sh fixtures --issue N [--require] [--repo OWNER/REPO]
#        cloud-dispatch.sh brief --issue N [--base B] [--gates TEXT] [--fixtures REFS] [--repo R]
#                          [--brief-ref implement|repair [--pr P]] [--branch B] [--note TEXT]
#        cloud-dispatch.sh payload --issue N --env ENV_ID --source URL [--model M] [--at EPOCH]
#                          [--base B] [--gates TEXT] [--fixtures REFS|none] [--lead S]
#                          [--stagger S] [--brief-ref implement|repair [--pr P]] [--no-blocker-check]
#                          [--branch B] [--note TEXT] [--repo R]
#        cloud-dispatch.sh briefs install [--dir D] [--kind K] [--base B] [--gates TEXT] [--force]
#        cloud-dispatch.sh briefs check [--dir D | --remote] [--kind K] [--base B] [--repo R]
#        cloud-dispatch.sh created [--issue N [--kind repair --pr P]] [--response FILE]
#                          [--run-at ISO]
#        cloud-dispatch.sh pace [--per-minute N] [--repo OWNER/REPO]
#        cloud-dispatch.sh backoff [--seconds S] [--message TEXT] [--repo OWNER/REPO]
#        cloud-dispatch.sh record --issue N --trigger ID --run-at ISO [--kind repair --pr P] [--repo R]
#        cloud-dispatch.sh stale [N...] [--hours H] [--cap K] [--repo OWNER/REPO]
#        cloud-dispatch.sh expire --issue N [--hours H] [--cap K] [--force] [--repo OWNER/REPO]
#        cloud-dispatch.sh stalled --runs FILE [--issue N] [--minutes M] [--repo OWNER/REPO]
#        cloud-dispatch.sh status [--repo OWNER/REPO]
#   queue add   append issues to the todo queue, skipping ones already queued or dispatched;
#               prints "queued N" per issue added. queue list prints the issues still to dispatch;
#               queue drop removes issues (one routed back to a local lane) and prints "dropped N".
#               queue add runs open-blockers.sh on the issues it adds and warns on stderr
#               ("warning: #N BLOCKED by #a #b", or "warning: #N blockers unverified: <what>");
#               it still queues them (payload refuses). --no-blocker-check skips the check.
#   next        the first K (default 1) queued issues not yet in the ledger, one per line.
#   fixtures    the device-to-cloud handoff check (../device-cloud-handoff.md), read-only. An issue
#               needs fixtures with --require, the label needs-fixtures, or when its body or a
#               comment mentions fixtures, captured output or a local evidence path. Then the body
#               or a comment must carry a <details> block, or an open or merged PR whose title
#               names fixtures must cross-reference the issue. Prints one line "fixtures <url>..."
#               (where they are, for --fixtures), or "fixtures none" when none are needed.
#               Refused (exit 5) when fixtures are needed but none travel with the issue.
#   brief       the per-issue brief: <state dir>/cloud-brief.md if present, else
#               roles/cloud-session-brief.md, with {{REPO}} {{ISSUE}} {{BASE}} {{GATES}} filled.
#               --base defaults to the repository's default branch (main if unreadable); --gates
#               to the repository's own test, lint and build commands. --fixtures REFS (other
#               than none) fills {{FIXTURES}} with "commit the fixtures from REFS verbatim" (a
#               template without that placeholder gets it appended). With --brief-ref it prints
#               the one-line prompt instead: "Follow .claude/briefs/implement.md for issue #N
#               (branch work/N-auto)." (repair: "... repair.md for PR #P (issue #N, branch
#               work/N-auto)."), plus " Fixtures: REFS (commit verbatim)." when REFS name any.
#               --branch B names another branch than work/N-auto (a redispatch after a stalled
#               run, #260); --note TEXT appends "Note from an earlier run: TEXT" (what that run
#               learned) to the brief or the one-line prompt.
#   payload     one JSON object for RemoteTrigger create: name, run_once_at, and job_config.ccr
#               {environment_id, session_context {sources [{git_repository {url}}], model}, events
#               [{data {message: <brief>}}]}. --source may instead be a JSON object (one sources
#               entry, used as is). run_once_at is --at, else the later of now+--lead (default 60)
#               and the ledger's latest run_at + --stagger (default 20), so runs are staggered.
#               Refused (exit 3) when the issue is already in the ledger. Without --fixtures it
#               runs the fixtures check first (exits 5 or 7 as that does). Before that it runs
#               open-blockers.sh for the issue: refused (exit 8) when an open issue blocks it,
#               naming the blockers; exit 7 when the blockers could not be read (unverified is
#               not clear). --no-blocker-check skips it. --brief-ref sends the one-line prompt
#               as the message; repair needs --pr, skips the ledger refusal, the blocker check
#               and the fixtures check (the issue was dispatched before; its PR exists), and is
#               refused (exit 3) while a repair is in flight on PR P (review-ledger.sh inflight).
#   briefs      the standard briefs kept in the target repository at .claude/briefs/K.md (K:
#               implement, repair, or all, the default). install renders waaagh's template
#               (<state dir>/briefs/K.md if present, else ../briefs/K.md) with {{REPO}} {{BASE}}
#               {{GATES}} filled into checkout --dir (default .) and prints "installed <path>" or
#               "current <path>"; a different existing file is refused (exit 3) without --force.
#               Commit and merge it by PR. check prints "brief K ok vV", "brief K custom" (no
#               version line; kept), "brief K outdated vV (template vT)" or "brief K missing
#               <path>", reading --dir, or with --remote the base branch on GitHub. Exit 6 when a
#               brief is missing or outdated: dispatch with --brief-ref only after check passes.
#   created     filter a RemoteTrigger create response (stdin or --response FILE): prints only
#               "created <trigger id> <run_once_at>", dropping the echoed prompt; with --issue it
#               also records it, as record does. Exit 7 when no trigger id is found.
#   pace        "wait <seconds>": how long to wait before the next create. Non-zero while a
#               recorded 429 backoff runs, or when the ledger already holds --per-minute (default
#               5) creates in the last 60 s. Sleep that long, then create.
#   backoff     record an HTTP 429: wait --seconds, else the N of "Try again in Ns" in --message,
#               else 20 s. Prints "backoff until <iso>".
#   record      after a create succeeds: append "issue trigger run_at created_at" to
#               cloud-sessions.tsv. Refused (exit 3) when the issue is already recorded.
#               --kind repair adds a fifth column "repair": never refused, never a dispatch. It
#               needs --pr P and marks the repair in flight on P (review-ledger.sh repair
#               --session <trigger>, #212): P neither merges nor takes a ship verdict until the
#               repair ends. Exit 9 when that mark failed (the row is written; mark it by hand).
#               Then it posts the REPAIR-START marker on P once (repair-writer.sh mark, #214): the
#               session that opened P reads it before any push and stops, so P keeps one writer.
#               Exit 10 when the marker could not be posted (row and mark stand; rerun the mark).
#   stale       live dispatches (recorded, not expired; only issues N when given) that never
#               produced a PR (#259): dispatched more than --hours H ago (default
#               ORCHESTRATE_DISPATCH_STALE_HOURS, 6; from run_at), the issue still open, and no open
#               or merged PR cross-references it (the issue and its timeline, REST through
#               gh-read.sh: two reads per dispatch past H). Prints one line per such issue,
#               "stale #N dispatches=K/CAP since=<run_at> age=<h>h" while it may be dispatched
#               again, "capped #N ..." once K reached --cap (default ORCHESTRATE_DISPATCH_CAP, 3
#               dispatches per issue), and "unknown #N <what>" when it could not be read (exit 7).
#   expire      end issue N's live dispatch so it can be dispatched again: refused (exit 3) at the
#               cap, or unless the stale check finds it stale (--force skips that check, not the
#               cap); exit 7 when that check could not read GitHub. Appends an "expired" row to
#               the ledger, puts N back on the queue, and prints "expired #N dispatch K/CAP
#               (trigger T); queued again". The next payload and record then take it as usual.
#   stalled     judge one trigger's runs (#260), read offline from FILE: the JSON the main session
#               saved from RemoteTrigger list_runs (an array of runs, or an object holding one as
#               runs, data, items or results). Per run it reads id (or run_id, session_id),
#               status, worker_status and last_event_at (also under a nested session object;
#               ISO 8601 with or without fractions, or epoch seconds or milliseconds), and
#               trigger_id to name the issue from the ledger (else --issue, else "#?"). Prints:
#               "stalled #N run=R status=S/W last_event=<iso> silent=<m>m": running or active,
#               but silent more than --minutes (default ORCHESTRATE_RUN_STALL_MINUTES, 45);
#               "blocked #N run=R status=S/requires_action": stopped on a permission prompt;
#               "ended #N run=R status=S/W last_event=<iso>": the run ended (idle, completed,
#               failed): a needs-decision candidate, read its final message before anything;
#               "unfired #N trigger=T run_at=<iso> late=<m>m": no run at all (--issue N, its
#               live dispatch) more than ORCHESTRATE_RUN_UNFIRED_MINUTES (15) after run_at;
#               "unknown #N run=R <what>" when a run cannot be judged (exit 7). A run still
#               producing events, or a trigger not yet due, prints nothing. Fetch list_runs
#               only for dispatches with no PR: stalled does not read GitHub.
#   status      queued, dispatched, last dispatch, backoff remaining (and repairs, expired, when
#               any); one "key value" per line.
# Files in <state dir>: cloud-queue.txt (one issue per line), cloud-sessions.tsv (issue, trigger
# id, run_at, created_at[, repair|expired]; ISO times; an expired row repeats the trigger and
# run_at of the dispatch it ends, created_at being when it was expired), cloud-backoff (epoch
# until which creates wait).
# Exit 5 refuses an issue whose fixtures are missing (route it back to its lane); exit 7 means the
# issue, its comments, its timeline, its blockers or (repair) the review ledger could not be read
# (do not dispatch it), or for created that the response holds no trigger id; exit 6 is a missing
# or outdated brief in the repository; exit 8 refuses an issue blocked by an open issue (route the
# blocker first).
# Exit 9: a repair was recorded but its PR could not be marked repairing (review-ledger.sh repair).
# Exit 3 also refuses expire (at the cap, or not stale); exit 7 also covers stale and expire when
# the issue or its timeline could not be read, and stalled when FILE is not runs JSON or a run
# could not be judged.
# Exit 10: a repair was recorded and marked but its REPAIR-START marker was not posted.
# Exit: 0 ok | 2 usage | 3 refused (dispatched, repair in flight) | 4 no template | 5 | 6 | 7 | 8 | 9 | 10
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
sub=""
if [[ "$cmd" == queue || "$cmd" == briefs ]]; then sub=${1:-}; if [[ -n "$sub" ]]; then shift; fi; fi
repo="" issue="" count=1 base="" gates="" env_id="" source_arg="" model="" at="" lead=60 stagger=20
fixtures="" require=no brief_ref="" pr="" dir=. kind="" force=no remote=no response=""
per_minute=5 seconds="" message="" trigger="" run_at="" blocker_check=yes
hours=${ORCHESTRATE_DISPATCH_STALE_HOURS:-6} cap=${ORCHESTRATE_DISPATCH_CAP:-3}
minutes=${ORCHESTRATE_RUN_STALL_MINUTES:-45} unfired=${ORCHESTRATE_RUN_UNFIRED_MINUTES:-15}
runs_file="" branch="" note=""
nums=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --count) count=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --gates) gates=$2; shift 2 ;;
    --fixtures) fixtures=$2; shift 2 ;;
    --require) require=yes; shift ;;
    --brief-ref) brief_ref=$2; shift 2 ;;
    --pr) pr=${2#\#}; shift 2 ;;
    --dir) dir=$2; shift 2 ;;
    --kind) kind=$2; shift 2 ;;
    --force) force=yes; shift ;;
    --remote) remote=yes; shift ;;
    --no-blocker-check) blocker_check=no; shift ;;
    --response) response=$2; shift 2 ;;
    --env) env_id=$2; shift 2 ;;
    --source) source_arg=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --at) at=$2; shift 2 ;;
    --lead) lead=$2; shift 2 ;;
    --stagger) stagger=$2; shift 2 ;;
    --per-minute) per_minute=$2; shift 2 ;;
    --seconds) seconds=$2; shift 2 ;;
    --message) message=$2; shift 2 ;;
    --trigger) trigger=$2; shift 2 ;;
    --run-at) run_at=$2; shift 2 ;;
    --hours) hours=$2; shift 2 ;;
    --cap) cap=$2; shift 2 ;;
    --minutes) minutes=$2; shift 2 ;;
    --runs) runs_file=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    [0-9]*) nums+=("${1#\#}"); shift ;;
    \#[0-9]*) nums+=("${1#\#}"); shift ;;
    *) echo "cloud-dispatch.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  queue) case "$sub" in add | drop | list) ;; *) usage ;; esac ;;
  briefs) case "$sub" in install | check) ;; *) usage ;; esac ;;
  next | fixtures | brief | payload | pace | backoff | record | created | stale | expire | stalled | status) ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }
for v in "$count" "$lead" "$stagger" "$per_minute" "$hours" "$cap" "$minutes" "$unfired"; do is_num "$v" || usage; done
[[ "$branch" != *[[:space:]]* ]] || usage
((cap >= 1)) || usage
[[ -z "$issue" ]] || is_num "$issue" || usage
[[ -z "$at" ]] || is_num "$at" || usage
[[ -z "$seconds" ]] || is_num "$seconds" || usage
[[ -z "$pr" ]] || is_num "$pr" || usage
case "$brief_ref" in "" | implement) ;; repair) [[ -n "$pr" ]] || usage ;; *) usage ;; esac
if [[ "$cmd" == briefs ]]; then
  case "${kind:=all}" in all) kinds="implement repair" ;; implement | repair) kinds=$kind ;; *) usage ;; esac
else
  case "${kind:=implement}" in implement | repair) ;; *) usage ;; esac
  if [[ "$kind" == repair && -n "$issue" && -z "$pr" ]] && [[ "$cmd" == record || "$cmd" == created ]]; then
    echo "cloud-dispatch.sh: $cmd --kind repair needs --pr" >&2; exit 2
  fi
fi

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
queue="$state/cloud-queue.txt" ledger="$state/cloud-sessions.tsv" backoff_file="$state/cloud-backoff"
touch "$queue" "$ledger"
now=$(orch_now)

# Repair rows (fifth column "repair") are creates, but never count as an issue's dispatch. An
# "expired" row ends the issue's dispatch before it (#259): the issue may be dispatched again.
dispatched() {
  awk -F'\t' -v n="$1" '$1 != n || $5 == "repair" { next } { f = ($5 != "expired") } END { exit !f }' "$ledger"
}
pending() { # queued issues not dispatched (or whose dispatch expired), in queue order
  awk -F'\t' 'FILENAME == ARGV[1] { if ($5 == "expired") delete d[$1]; else if ($5 != "repair") d[$1] = 1; next }
    $1 != "" && !($1 in d) && !s[$1]++ { print $1 }' "$ledger" "$queue"
}
# live: "issue trigger run_at dispatches" (tab-separated, ledger order) for each issue whose last
# dispatch has not expired; dispatches counts every dispatch of the issue, expired ones included.
live() {
  awk -F'\t' -v OFS='\t' '$1 == "" || $5 == "repair" { next }
    !($1 in seen) { seen[$1] = 1; ord[++m] = $1 }
    $5 == "expired" { delete t[$1]; next }
    { t[$1] = $2; r[$1] = $3; c[$1]++ }
    END { for (i = 1; i <= m; i++) { k = ord[i]; if (k in t) print k, t[k], r[k], c[k] } }' "$ledger"
}
iso_epoch() { jq -rn --arg t "$1" '$t | fromdateiso8601'; }
need_issue() { [[ -n "$issue" ]] || { echo "cloud-dispatch.sh: $cmd needs --issue" >&2; exit 2; }; }

# stale_of N RUN_AT: whether issue N's dispatch at RUN_AT produced anything (#259). Prints young
# (under --hours), closed, "pr <url>" (an open or merged PR cross-references it), stale, or
# "unknown <what>". Reads (only past --hours) go through gh-read.sh.
stale_of() {
  local n=$1 e iss st tl url
  e=$(iso_epoch "$2" 2>/dev/null) || { echo "unknown run_at"; return; }
  if ((now - e < hours * 3600)); then echo young; return; fi
  iss=$(orch_read_retry 3 gh api "repos/$repo/issues/$n") || iss=""
  st=$(jq -r '.state // empty' <<<"$iss" 2>/dev/null) || st=""
  [[ -n "$st" ]] || { echo "unknown issue"; return; }
  if [[ "$st" != open ]]; then echo closed; return; fi
  tl=$(orch_read_retry 3 gh api --paginate "repos/$repo/issues/$n/timeline?per_page=100") ||
    { echo "unknown timeline"; return; }
  url=$(jq -rs 'if all(.[]; type == "array") then . else error("not a timeline") end
    | [.[][] | select(.event == "cross-referenced") | .source.issue // empty
      | select(.pull_request != null and (.state == "open" or .pull_request.merged_at != null))
      | .html_url] | first // ""' <<<"$tl" 2>/dev/null) || { echo "unknown timeline"; return; }
  if [[ -n "$url" ]]; then echo "pr $url"; else echo stale; fi
}

# check_fixtures: the device-to-cloud handoff check. Prints the fixture URLs (space-separated) or
# "none"; exits 5 (needed, missing) or 7 (unreadable). Reads go through gh-read.sh.
check_fixtures() {
  local iss com tl needs refs localpath
  unreadable() { echo "cloud-dispatch.sh: #$issue: $1 could not be read; do not dispatch it" >&2; exit 7; }
  iss=$(orch_read_retry 3 gh api "repos/$repo/issues/$issue") || unreadable "the issue"
  jq -e 'type == "object" and has("body")' >/dev/null 2>&1 <<<"$iss" || unreadable "the issue"
  com=$(orch_read_retry 3 gh api "repos/$repo/issues/$issue/comments?per_page=100") || unreadable "its comments"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$com" || unreadable "its comments"
  # The issue and its comments travel as files, not arguments: one argument is capped at 128 KiB (#121).
  needs=$(jq -rn --slurpfile i <(printf '%s\n' "$iss") --slurpfile c <(printf '%s\n' "$com") --arg req "$require" '
    def mentions: test("fixture|captured|\\.claude/orchestrate/|evidence-"; "i");
    $i[0] as $i | $c[0] as $c |
    if $req == "yes" or any($i.labels[]?; .name == "needs-fixtures")
       or ((($i.body // "") + " " + ([$c[].body // ""] | join(" "))) | mentions)
    then "yes" else "no" end')
  if [[ "$needs" == no ]]; then echo none; return 0; fi
  refs=$(jq -rn --slurpfile i <(printf '%s\n' "$iss") --slurpfile c <(printf '%s\n' "$com") '
    $i[0] as $i | $c[0] as $c |
    [(if ($i.body // "") | test("<details"; "i") then $i.html_url else empty end),
     ($c[] | select((.body // "") | test("<details"; "i")) | .html_url)] | join(" ")')
  if [[ -z "$refs" ]]; then
    tl=$(orch_read_retry 3 gh api "repos/$repo/issues/$issue/timeline?per_page=100") || unreadable "its timeline"
    refs=$(jq -r '[.[]? | select(.event == "cross-referenced") | .source.issue // empty
      | select(.pull_request != null and (.state == "open" or .pull_request.merged_at != null))
      | select((.title // "") | test("fixture"; "i")) | .html_url] | unique | join(" ")' <<<"$tl" 2>/dev/null) ||
      unreadable "its timeline"
  fi
  if [[ -z "$refs" ]]; then
    localpath=$(jq -rn --slurpfile i <(printf '%s\n' "$iss") --slurpfile c <(printf '%s\n' "$com") '
      $i[0] as $i | $c[0] as $c |
      [($i.body // ""), ($c[].body // "")] | join("\n")
      | [scan("(?:~|/Users/[^/ ]+|/home/[^/ ]+)/[^ `)\n]*")] | first // ""')
    echo "cloud-dispatch.sh: #$issue needs captured fixtures but none travel with it: no <details>" \
      "block in the body or a comment, no linked fixtures PR${localpath:+ (only a local path: $localpath)}." \
      "Route it back to the lane that captured them." >&2
    exit 5
  fi
  echo "$refs"
}

# blockers N...: open-blockers.sh lines (REST through gh-read.sh), one per issue; an outright
# failure of the check reads as "<n> unreadable blocker check (exit RC)" for every issue.
blockers() {
  local out rc=0
  out=$("$here/open-blockers.sh" --repo "$repo" "$@") || rc=$?
  case "$rc" in
    0 | 3 | 4) printf '%s\n' "$out" ;;
    *) printf '%s\n' "$@" | awk -v rc="$rc" '{ print $1 " unreadable blocker check (exit " rc ")" }' ;;
  esac
}
# check_blockers: payload's refusal. Exit 8 when an open issue blocks $issue, 7 when unverified.
check_blockers() {
  local line
  line=$(blockers "$issue" | awk -v n="$issue" '$1 == n' | sed -n 1p)
  case "$line" in
    "$issue clear") ;;
    "$issue BLOCKED "*)
      echo "cloud-dispatch.sh: #$issue ${line#"$issue" }: route the blocker first; do not dispatch it" >&2
      exit 8 ;;
    *) echo "cloud-dispatch.sh: #$issue: blockers unverified (${line#"$issue" unreadable }); do not dispatch it" >&2
       exit 7 ;;
  esac
}

# prompt_line: the one-line prompt for a brief kept in the repository (--brief-ref).
prompt_line() {
  local line b=${branch:-work/$issue-auto}
  if [[ "$brief_ref" == repair ]]; then
    line="Follow .claude/briefs/repair.md for PR #$pr (issue #$issue, branch $b)."
  else
    line="Follow .claude/briefs/implement.md for issue #$issue (branch $b)."
  fi
  if [[ -n "$fixtures" && "$fixtures" != none ]]; then line="$line Fixtures: $fixtures (commit verbatim)."; fi
  if [[ -n "$note" ]]; then line="$line Note from an earlier run: $note"; fi
  printf '%s\n' "$line"
}

resolve_base() {
  if [[ -z "$base" ]]; then base=$(orch_default_branch "$repo" 2>/dev/null || true); fi
  [[ -n "$base" && "$base" != null ]] || base=main
}

# brief_template K: waaagh's standard brief K rendered for this repository; {{REPO}} {{BASE}}
# {{GATES}} filled, the per-issue values left to the one-line prompt.
brief_template() {
  local tpl="$here/../briefs/$1.md"
  [[ -s "$state/briefs/$1.md" ]] && tpl="$state/briefs/$1.md"
  [[ -s "$tpl" ]] || { echo "cloud-dispatch.sh: brief template missing: $tpl" >&2; exit 4; }
  jq -Rrs --arg repo "$repo" --arg base "$base" --arg gates "$gates" '
    gsub("\\{\\{REPO\\}\\}"; $repo) | gsub("\\{\\{BASE\\}\\}"; $base)
    | gsub("\\{\\{GATES\\}\\}"; $gates)' "$tpl"
}
brief_version() { # the V of a first line "<!-- waaagh-brief K vV ...", or nothing
  awk 'NR == 1 && match($0, /waaagh-brief [a-z]+ v[0-9]+/) { s = substr($0, RSTART, RLENGTH); sub(/.* v/, "", s); print s }'
}

render_brief() {
  local tpl="$here/../roles/cloud-session-brief.md"
  [[ -s "$state/cloud-brief.md" ]] && tpl="$state/cloud-brief.md"
  [[ -s "$tpl" ]] || { echo "cloud-dispatch.sh: brief template missing: $tpl" >&2; exit 4; }
  resolve_base
  [[ -n "$gates" ]] || gates="the repository's own test, lint and build commands (README, CI config)"
  local fix=""
  if [[ -n "$fixtures" && "$fixtures" != none ]]; then
    fix=" Commit the captured fixtures from $fixtures verbatim; never hand-write, trim or regenerate them."
  fi
  jq -Rrs --arg repo "$repo" --arg n "$issue" --arg base "$base" --arg gates "$gates" --arg fix "$fix" \
    --arg branch "$branch" --arg note "$note" '
    (if $fix != "" and (test("\\{\\{FIXTURES\\}\\}") | not) then sub("\n*$"; "\n" + ($fix | ltrimstr(" ")) + "\n") else . end)
    | gsub("\\{\\{REPO\\}\\}"; $repo) | gsub("\\{\\{ISSUE\\}\\}"; $n)
    | gsub("\\{\\{BASE\\}\\}"; $base) | gsub("\\{\\{GATES\\}\\}"; $gates)
    | gsub("\\{\\{FIXTURES\\}\\}"; $fix)
    | (if $branch != "" then split("work/" + $n + "-auto") | join($branch) else . end)
    | (if $note != "" then sub("\n*$"; "\nNote from an earlier run: " + $note + "\n") else . end)' "$tpl"
}

do_record() {
  [[ -n "$trigger" && -n "$run_at" ]] || { echo "cloud-dispatch.sh: record needs --trigger and --run-at" >&2; exit 2; }
  iso_epoch "$run_at" >/dev/null 2>&1 || { echo "cloud-dispatch.sh: --run-at must be ISO 8601 (2026-01-02T03:04:05Z)" >&2; exit 2; }
  if [[ "$kind" == repair ]]; then
    [[ -n "$pr" ]] || { echo "cloud-dispatch.sh: record --kind repair needs --pr" >&2; exit 2; }
    printf '%s\t%s\t%s\t%s\trepair\n' "$issue" "$trigger" "$run_at" "$(orch_iso "$now")" >>"$ledger"
    echo "recorded $issue $trigger $run_at repair"
    # The repair is in flight from now: PR P must neither merge nor be shipped mid-repair (#212).
    "$here/review-ledger.sh" repair --repo "$repo" --pr "$pr" --session "$trigger" \
      --note "cloud repair of issue #$issue" >/dev/null ||
      { echo "cloud-dispatch.sh: PR #$pr is not marked repairing; run review-ledger.sh repair --pr $pr --session $trigger" >&2; exit 9; }
    echo "repairing PR #$pr session $trigger: held, and no ship verdict, until the repair ends"
    # One writer (#214): the session that opened P must stop pushing; the marker tells it so.
    "$here/repair-writer.sh" mark --repo "$repo" --pr "$pr" --session "$trigger" --issue "$issue" ||
      { echo "cloud-dispatch.sh: PR #$pr has no REPAIR-START marker; run repair-writer.sh mark --pr $pr --session $trigger --issue $issue" >&2; exit 10; }
    return
  fi
  if dispatched "$issue"; then echo "cloud-dispatch.sh: #$issue already recorded" >&2; exit 3; fi
  printf '%s\t%s\t%s\t%s\n' "$issue" "$trigger" "$run_at" "$(orch_iso "$now")" >>"$ledger"
  echo "recorded $issue $trigger $run_at"
}

case "$cmd" in
  queue)
    if [[ "$sub" == list ]]; then pending; exit 0; fi
    ((${#nums[@]})) || usage
    if [[ "$sub" == drop ]]; then
      for n in "${nums[@]}"; do
        grep -qxF "$n" "$queue" || continue
        awk -v n="$n" '$0 != n' "$queue" >"$queue.tmp.$$" && mv "$queue.tmp.$$" "$queue"
        echo "dropped $n"
      done
      exit 0
    fi
    added=()
    for n in "${nums[@]}"; do
      if dispatched "$n" || grep -qxF "$n" "$queue"; then continue; fi
      printf '%s\n' "$n" >>"$queue"
      echo "queued $n"
      added+=("$n")
    done
    if [[ "$blocker_check" == yes ]] && ((${#added[@]})); then
      blockers "${added[@]}" | awk '
        $2 == "BLOCKED" { $1 = "warning: #" $1; print; next }
        $2 == "unreadable" { n = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); print "warning: #" n " blockers unverified: " $0 }' >&2
    fi
    ;;
  next)
    pending | awk -v k="$count" 'NR <= k'
    ;;
  fixtures)
    need_issue
    refs=$(check_fixtures)
    echo "fixtures $refs"
    ;;
  brief)
    need_issue
    if [[ -n "$brief_ref" ]]; then prompt_line; else render_brief; fi
    ;;
  briefs)
    resolve_base
    [[ -n "$gates" ]] || gates="the repository's own test, lint and build commands (README, CI config)"
    bad=0
    for k in $kinds; do
      rel=".claude/briefs/$k.md" want=$(brief_template "$k")
      if [[ "$sub" == install ]]; then
        f="$dir/$rel"
        if [[ -f "$f" ]] && [[ "$(cat "$f")" == "$want" ]]; then echo "current $f"; continue; fi
        if [[ -f "$f" && "$force" != yes ]]; then
          echo "cloud-dispatch.sh: $f exists and differs from the template; --force replaces it" >&2
          exit 3
        fi
        mkdir -p "$(dirname "$f")"
        printf '%s\n' "$want" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"
        echo "installed $f"
        continue
      fi
      if [[ "$remote" == yes ]]; then
        rc=0
        got=$(orch_read_retry 3 gh api "repos/$repo/contents/$rel?ref=$base") || rc=$?
        if ((rc == 3)); then echo "brief $k missing $rel on $base"; bad=1; continue; fi
        if ((rc != 0)); then echo "cloud-dispatch.sh: $rel on $base could not be read" >&2; exit 7; fi
        got=$(jq -r '.content | gsub("\n"; "") | @base64d' <<<"$got" 2>/dev/null) ||
          { echo "cloud-dispatch.sh: $rel on $base could not be read" >&2; exit 7; }
      else
        if [[ ! -f "$dir/$rel" ]]; then echo "brief $k missing $dir/$rel"; bad=1; continue; fi
        got=$(cat "$dir/$rel")
      fi
      have=$(brief_version <<<"$got") tv=$(brief_version <<<"$want")
      if [[ -z "$have" ]]; then echo "brief $k custom"
      elif [[ -n "$tv" ]] && ((have < tv)); then echo "brief $k outdated v$have (template v$tv)"; bad=1
      else echo "brief $k ok v$have"; fi
    done
    if [[ "$sub" == check ]] && ((bad)); then exit 6; fi
    ;;
  payload)
    need_issue
    [[ -n "$env_id" && -n "$source_arg" ]] || { echo "cloud-dispatch.sh: payload needs --env and --source" >&2; exit 2; }
    if [[ "$brief_ref" == repair ]]; then
      [[ -n "$fixtures" ]] || fixtures=none
      fl=$("$here/review-ledger.sh" inflight --repo "$repo" --pr "$pr") ||
        { echo "cloud-dispatch.sh: the review ledger could not be read; do not dispatch a repair of PR #$pr" >&2; exit 7; }
      if [[ -n "$fl" ]]; then
        echo "cloud-dispatch.sh: a repair is already in flight on PR #$pr (session $(cut -f2 <<<"$fl") since $(cut -f3 <<<"$fl"))" >&2
        exit 3
      fi
    elif dispatched "$issue"; then
      echo "cloud-dispatch.sh: #$issue already dispatched: $(live | awk -F'\t' -v n="$issue" '$1 == n { print $2 " at " $3 }')" >&2
      exit 3
    fi
    if [[ "$brief_ref" != repair && "$blocker_check" == yes ]]; then check_blockers; fi
    if [[ -z "$fixtures" ]]; then fixtures=$(check_fixtures); fi
    if [[ -z "$at" ]]; then
      at=$((now + lead))
      last=$(awk -F'\t' '$3 != "" && $5 != "expired" { print $3 }' "$ledger" | sort | awk 'END { print }')
      if [[ -n "$last" ]]; then
        slot=$(($(iso_epoch "$last") + stagger))
        ((slot <= at)) || at=$slot
      fi
    fi
    if [[ "$source_arg" == \{* ]]; then
      src=$(jq -ce . <<<"$source_arg") || { echo "cloud-dispatch.sh: --source is not valid JSON" >&2; exit 2; }
    else
      src=$(jq -cn --arg u "$source_arg" '{git_repository: {url: $u}}')
    fi
    name="${repo##*/} #$issue cloud lane"
    if [[ -n "$brief_ref" ]]; then msg=$(prompt_line); else msg=$(render_brief); fi
    if [[ "$brief_ref" == repair ]]; then name="${repo##*/} #$issue cloud repair of PR #$pr"; fi
    jq -n --arg name "$name" --arg at "$(orch_iso "$at")" --arg env "$env_id" \
      --argjson src "$src" --arg model "$model" --arg msg "$msg" '
      {name: $name, run_once_at: $at,
       job_config: {ccr: {environment_id: $env,
         session_context: ({sources: [$src]} + (if $model == "" then {} else {model: $model} end)),
         events: [{data: {message: $msg}}]}}}'
    ;;
  pace)
    until_t=0
    if [[ -s "$backoff_file" ]]; then until_t=$(awk 'NR == 1 { print $1 + 0 }' "$backoff_file"); fi
    wait_b=$((until_t > now ? until_t - now : 0))
    # Creates in the last 60 s; the oldest of the last per_minute of them sets when a slot frees.
    recent=$(awk -F'\t' '$4 != "" && $5 != "expired" { print $4 }' "$ledger" | sort | while read -r t; do
      e=$(iso_epoch "$t"); ((e > now - 60)) && echo "$e"; done || true)
    wait_r=0
    n_recent=$(printf '%s' "$recent" | awk 'NF { c++ } END { print c + 0 }')
    if ((per_minute > 0 && n_recent >= per_minute)); then
      oldest=$(printf '%s\n' "$recent" | awk -v k="$((n_recent - per_minute + 1))" 'NF && ++c == k { print }')
      wait_r=$((oldest + 60 - now))
    fi
    echo "wait $((wait_b > wait_r ? wait_b : wait_r))"
    ;;
  backoff)
    if [[ -z "$seconds" ]]; then
      seconds=$(printf '%s' "$message" | sed -n 's/.*[Tt]ry again in \([0-9][0-9]*\) *s.*/\1/p' | awk 'NR == 1')
      [[ -n "$seconds" ]] || seconds=20
    fi
    printf '%s\n' "$((now + seconds))" >"$backoff_file.tmp.$$" && mv "$backoff_file.tmp.$$" "$backoff_file"
    echo "backoff until $(orch_iso "$((now + seconds))")"
    ;;
  record)
    need_issue
    do_record
    ;;
  created)
    if [[ -n "$response" ]]; then body=$(cat "$response"); else body=$(cat); fi
    got=$(jq -r 'def tid: first((.. | objects | .trigger_id? | strings),
        (.. | objects | .id? | strings | select(startswith("trig_"))), (.trigger.id? | strings), (.id? | strings)) // "";
      def rat: first(.. | objects | .run_once_at? | strings) // "";
      "\(tid)\t\(rat)"' <<<"$body" 2>/dev/null) || got=""
    trigger=${got%%$'\t'*}
    [[ -n "$trigger" ]] || { echo "cloud-dispatch.sh: no trigger id in the create response" >&2; exit 7; }
    [[ -n "$run_at" ]] || run_at=${got#*$'\t'}
    echo "created $trigger ${run_at:--}"
    if [[ -n "$issue" ]]; then do_record >/dev/null; fi
    ;;
  stale)
    rows=$(live)
    if ((${#nums[@]})); then
      rows=$(awk -F'\t' -v want=" ${nums[*]} " 'index(want, " " $1 " ")' <<<"$rows")
    fi
    bad=0
    # fd 3: the reads in stale_of must not eat the rows.
    while IFS=$'\t' read -r n _ ra k <&3; do
      [[ -n "$n" ]] || continue
      v=$(stale_of "$n" "$ra")
      case "$v" in
        stale)
          what=stale
          ((k < cap)) || what=capped
          echo "$what #$n dispatches=$k/$cap since=$ra age=$(((now - $(iso_epoch "$ra")) / 3600))h" ;;
        unknown*) echo "unknown #$n ${v#unknown }"; bad=1 ;;
      esac
    done 3<<<"$rows"
    if ((bad)); then exit 7; fi
    ;;
  expire)
    need_issue
    row=$(live | awk -F'\t' -v n="$issue" '$1 == n')
    [[ -n "$row" ]] || { echo "cloud-dispatch.sh: #$issue has no live dispatch in the ledger" >&2; exit 3; }
    IFS=$'\t' read -r _ trig ra k <<<"$row"
    if ((k >= cap)); then
      echo "cloud-dispatch.sh: #$issue reached the dispatch cap ($k/$cap): route it to a local lane, or read why its sessions ended" >&2
      exit 3
    fi
    if [[ "$force" != yes ]]; then
      v=$(stale_of "$issue" "$ra")
      case "$v" in
        stale) ;;
        young) echo "cloud-dispatch.sh: #$issue was dispatched at $ra, under ${hours}h ago; not stale yet" >&2; exit 3 ;;
        closed) echo "cloud-dispatch.sh: #$issue is closed; nothing to dispatch again" >&2; exit 3 ;;
        pr\ *) echo "cloud-dispatch.sh: #$issue has a PR (${v#pr }); repair that instead" >&2; exit 3 ;;
        *) echo "cloud-dispatch.sh: #$issue: the stale check could not read the ${v#unknown }; do not expire it" >&2; exit 7 ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\texpired\n' "$issue" "$trig" "$ra" "$(orch_iso "$now")" >>"$ledger"
    grep -qxF "$issue" "$queue" || printf '%s\n' "$issue" >>"$queue"
    echo "expired #$issue dispatch $k/$cap (trigger $trig); queued again"
    ;;
  stalled)
    [[ -n "$runs_file" ]] || { echo "cloud-dispatch.sh: stalled needs --runs FILE (saved from RemoteTrigger list_runs)" >&2; exit 2; }
    # One row per run, unit-separated so empty fields do not collapse: kind id status worker
    # last_iso silent_min trigger_id what. Missing fields read as empty; kind is stalled,
    # blocked, ended, running or unknown.
    rows=$(jq -r --argjson now "$now" --argjson lim "$((minutes * 60))" '
      def g($k): [.[$k]?, (.session? | objects | .[$k]?)] | map(select(. != null and . != "")) | .[0];
      def ts: if type == "number" then (if . > 1e12 then . / 1000 else . end | floor)
        elif type == "string" then (sub("\\.[0-9]+"; "") | sub("[+-]00:?00$"; "Z")
          | try fromdateiso8601 catch null) else null end;
      def low: if . == null then "" else tostring | ascii_downcase end;
      (if type == "array" then .
       elif type == "object" then (.runs // .data // .items // .results
         // (if has("id") or has("status") or has("worker_status") then [.] else null end))
       else null end) as $runs
      | if ($runs | type) != "array" then error("no runs") else $runs[] end
      | select(type == "object")
      | ((g("id") // g("run_id") // g("session_id") // "?") | tostring) as $id
      | (g("status") | low) as $st | (g("worker_status") | low) as $w
      | (g("last_event_at") | ts) as $last
      | ((g("trigger_id") // g("routine_id") // "") | tostring) as $trig
      | (if $last == null then "" else ($last | todate) end) as $iso
      | (if $last == null then "" else ((($now - $last) / 60) | floor | tostring) end) as $silent
      | (if $w == "requires_action" or $st == "requires_action" then ["blocked", ""]
         elif ($w | IN("idle", "stopped", "ended", "terminated", "exited"))
           or ($st | IN("idle", "completed", "complete", "succeeded", "success", "failed", "error",
                        "errored", "ended", "archived", "terminated", "cancelled", "canceled", "expired"))
           then ["ended", ""]
         elif $w == "running" or ($st | IN("running", "active", "in_progress", "started")) then
           (if $last == null then ["unknown", "no last_event_at"]
            elif $now - $last > $lim then ["stalled", ""] else ["running", ""] end)
         else ["unknown", "status \(if $st == "" then "-" else $st end)/\(if $w == "" then "-" else $w end)"] end) as $k
      | [$k[0], $id, $st, $w, $iso, $silent, $trig, $k[1]] | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' "$runs_file" 2>/dev/null) ||
      { echo "cloud-dispatch.sh: $runs_file is not list_runs JSON (an array of runs, or an object holding one)" >&2; exit 7; }
    bad=0
    while IFS=$'\x1f' read -r k id st w iso silent trig what; do
      [[ -n "$k" ]] || continue
      n=$issue
      if [[ -z "$n" && -n "$trig" ]]; then
        n=$(awk -F'\t' -v t="$trig" '$2 == t && $5 != "expired" { n = $1 } END { print n }' "$ledger")
      fi
      sw="${st:--}/${w:--}"
      case "$k" in
        stalled) echo "stalled #${n:-?} run=$id status=$sw last_event=$iso silent=${silent}m" ;;
        blocked) echo "blocked #${n:-?} run=$id status=${st:--}/requires_action" ;;
        ended) echo "ended #${n:-?} run=$id status=$sw last_event=${iso:--}" ;;
        unknown) echo "unknown #${n:-?} run=$id $what"; bad=1 ;;
      esac
    done <<<"$rows"
    if [[ -z "$rows" ]]; then
      # No run at all: a run-once trigger that never fired (#260). Judge it from the ledger.
      row=""
      if [[ -n "$issue" ]]; then row=$(live | awk -F'\t' -v n="$issue" '$1 == n'); fi
      if [[ -z "$row" ]]; then
        echo "unknown #${issue:-?} no runs, and no live dispatch to judge them by (pass --issue N)"; bad=1
      else
        IFS=$'\t' read -r _ trig ra _ <<<"$row"
        if e=$(iso_epoch "$ra" 2>/dev/null) && ((now - e > unfired * 60)); then
          echo "unfired #$issue trigger=$trig run_at=$ra late=$(((now - e) / 60))m"
        elif [[ -z "${e:-}" ]]; then
          echo "unknown #$issue no runs, unreadable run_at $ra"; bad=1
        fi
      fi
    fi
    if ((bad)); then exit 7; fi
    ;;
  status)
    until_t=0
    if [[ -s "$backoff_file" ]]; then until_t=$(awk 'NR == 1 { print $1 + 0 }' "$backoff_file"); fi
    echo "queued $(pending | awk 'END { print NR }')"
    echo "dispatched $(awk -F'\t' '$1 != "" && $5 != "repair" && $5 != "expired" { c++ } END { print c + 0 }' "$ledger")"
    repairs=$(awk -F'\t' '$5 == "repair" { c++ } END { print c + 0 }' "$ledger")
    if ((repairs)); then echo "repairs $repairs"; fi
    expired=$(awk -F'\t' '$5 == "expired" { c++ } END { print c + 0 }' "$ledger")
    if ((expired)); then echo "expired $expired"; fi
    echo "last $(awk -F'\t' '$1 != "" && $5 != "expired" { l = "#" $1 " " $2 " " $3 } END { print (l == "" ? "-" : l) }' "$ledger")"
    echo "backoff $((until_t > now ? until_t - now : 0))"
    ;;
esac
