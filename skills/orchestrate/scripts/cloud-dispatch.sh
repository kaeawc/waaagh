#!/usr/bin/env bash
# Cloud dispatch bookkeeping: one no-click cloud session per cloud-ready issue, started by a
# run-once routine (RemoteTrigger create) from the main session. This script never calls
# RemoteTrigger or writes to GitHub; it keeps the todo queue and the dispatch ledger (both survive
# compaction), renders the short per-issue brief, builds the create payload, and paces creates.
# The standard briefs can instead live in the target repository (.claude/briefs/implement.md and
# repair.md, versioned and changed by PR); the dispatched prompt is then one line (--brief-ref).
#
# Usage: cloud-dispatch.sh queue add|drop N... [--no-blocker-check] [--repo OWNER/REPO]
#        cloud-dispatch.sh queue list [--repo OWNER/REPO]
#        cloud-dispatch.sh next [--count K] [--repo OWNER/REPO]
#        cloud-dispatch.sh fixtures --issue N [--require] [--repo OWNER/REPO]
#        cloud-dispatch.sh brief --issue N [--base B] [--gates TEXT] [--fixtures REFS] [--repo R]
#                          [--brief-ref implement|repair [--pr P]]
#        cloud-dispatch.sh payload --issue N --env ENV_ID --source URL [--model M] [--at EPOCH]
#                          [--base B] [--gates TEXT] [--fixtures REFS|none] [--lead S]
#                          [--stagger S] [--brief-ref implement|repair [--pr P]] [--no-blocker-check]
#                          [--repo R]
#        cloud-dispatch.sh briefs install [--dir D] [--kind K] [--base B] [--gates TEXT] [--force]
#        cloud-dispatch.sh briefs check [--dir D | --remote] [--kind K] [--base B] [--repo R]
#        cloud-dispatch.sh created [--issue N [--kind repair]] [--response FILE] [--run-at ISO]
#        cloud-dispatch.sh pace [--per-minute N] [--repo OWNER/REPO]
#        cloud-dispatch.sh backoff [--seconds S] [--message TEXT] [--repo OWNER/REPO]
#        cloud-dispatch.sh record --issue N --trigger ID --run-at ISO [--kind repair] [--repo R]
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
#               and the fixtures check (the issue was dispatched before; its PR exists).
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
#               --kind repair adds a fifth column "repair": never refused, never a dispatch.
#   status      queued, dispatched, last dispatch, backoff remaining (and repairs, when any); one
#               "key value" per line.
# Files in <state dir>: cloud-queue.txt (one issue per line), cloud-sessions.tsv (issue, trigger
# id, run_at, created_at[, repair]; ISO times), cloud-backoff (epoch until which creates wait).
# Exit 5 refuses an issue whose fixtures are missing (route it back to its lane); exit 7 means the
# issue, its comments, its timeline or its blockers could not be read (do not dispatch it), or for
# created that the response holds no trigger id; exit 6 is a missing or outdated brief in the
# repository; exit 8 refuses an issue blocked by an open issue (route the blocker first).
# Exit: 0 ok | 2 usage | 3 refused (already dispatched) | 4 brief template missing | 5 | 6 | 7 | 8
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
    -h | --help) orch_usage; exit 0 ;;
    [0-9]*) nums+=("${1#\#}"); shift ;;
    \#[0-9]*) nums+=("${1#\#}"); shift ;;
    *) echo "cloud-dispatch.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  queue) case "$sub" in add | drop | list) ;; *) usage ;; esac ;;
  briefs) case "$sub" in install | check) ;; *) usage ;; esac ;;
  next | fixtures | brief | payload | pace | backoff | record | created | status) ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }
for v in "$count" "$lead" "$stagger" "$per_minute"; do is_num "$v" || usage; done
[[ -z "$issue" ]] || is_num "$issue" || usage
[[ -z "$at" ]] || is_num "$at" || usage
[[ -z "$seconds" ]] || is_num "$seconds" || usage
[[ -z "$pr" ]] || is_num "$pr" || usage
case "$brief_ref" in "" | implement) ;; repair) [[ -n "$pr" ]] || usage ;; *) usage ;; esac
if [[ "$cmd" == briefs ]]; then
  case "${kind:=all}" in all) kinds="implement repair" ;; implement | repair) kinds=$kind ;; *) usage ;; esac
else
  case "${kind:=implement}" in implement | repair) ;; *) usage ;; esac
fi

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
queue="$state/cloud-queue.txt" ledger="$state/cloud-sessions.tsv" backoff_file="$state/cloud-backoff"
touch "$queue" "$ledger"
now=$(orch_now)

# Repair rows (fifth column "repair") are creates, but never count as an issue's dispatch.
dispatched() { awk -F'\t' -v n="$1" '$1 == n && $5 != "repair" { f = 1 } END { exit !f }' "$ledger"; }
pending() { # queued issues not yet in the ledger, in queue order
  awk -F'\t' 'FILENAME == ARGV[1] { if ($5 != "repair") d[$1] = 1; next }
    $1 != "" && !($1 in d) && !s[$1]++ { print $1 }' "$ledger" "$queue"
}
iso_epoch() { jq -rn --arg t "$1" '$t | fromdateiso8601'; }
need_issue() { [[ -n "$issue" ]] || { echo "cloud-dispatch.sh: $cmd needs --issue" >&2; exit 2; }; }

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
  local line
  if [[ "$brief_ref" == repair ]]; then
    line="Follow .claude/briefs/repair.md for PR #$pr (issue #$issue, branch work/$issue-auto)."
  else
    line="Follow .claude/briefs/implement.md for issue #$issue (branch work/$issue-auto)."
  fi
  if [[ -n "$fixtures" && "$fixtures" != none ]]; then line="$line Fixtures: $fixtures (commit verbatim)."; fi
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
  jq -Rrs --arg repo "$repo" --arg n "$issue" --arg base "$base" --arg gates "$gates" --arg fix "$fix" '
    (if $fix != "" and (test("\\{\\{FIXTURES\\}\\}") | not) then sub("\n*$"; "\n" + ($fix | ltrimstr(" ")) + "\n") else . end)
    | gsub("\\{\\{REPO\\}\\}"; $repo) | gsub("\\{\\{ISSUE\\}\\}"; $n)
    | gsub("\\{\\{BASE\\}\\}"; $base) | gsub("\\{\\{GATES\\}\\}"; $gates)
    | gsub("\\{\\{FIXTURES\\}\\}"; $fix)' "$tpl"
}

do_record() {
  [[ -n "$trigger" && -n "$run_at" ]] || { echo "cloud-dispatch.sh: record needs --trigger and --run-at" >&2; exit 2; }
  iso_epoch "$run_at" >/dev/null 2>&1 || { echo "cloud-dispatch.sh: --run-at must be ISO 8601 (2026-01-02T03:04:05Z)" >&2; exit 2; }
  if [[ "$kind" == repair ]]; then
    printf '%s\t%s\t%s\t%s\trepair\n' "$issue" "$trigger" "$run_at" "$(orch_iso "$now")" >>"$ledger"
    echo "recorded $issue $trigger $run_at repair"
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
    elif dispatched "$issue"; then
      echo "cloud-dispatch.sh: #$issue already dispatched: $(awk -F'\t' -v n="$issue" '$1 == n && $5 != "repair" { print $2 " at " $3 }' "$ledger")" >&2
      exit 3
    fi
    if [[ "$brief_ref" != repair && "$blocker_check" == yes ]]; then check_blockers; fi
    if [[ -z "$fixtures" ]]; then fixtures=$(check_fixtures); fi
    if [[ -z "$at" ]]; then
      at=$((now + lead))
      last=$(awk -F'\t' '$3 != "" { print $3 }' "$ledger" | sort | awk 'END { print }')
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
    recent=$(awk -F'\t' '$4 != "" { print $4 }' "$ledger" | sort | while read -r t; do
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
  status)
    until_t=0
    if [[ -s "$backoff_file" ]]; then until_t=$(awk 'NR == 1 { print $1 + 0 }' "$backoff_file"); fi
    echo "queued $(pending | awk 'END { print NR }')"
    echo "dispatched $(awk -F'\t' '$1 != "" && $5 != "repair" { c++ } END { print c + 0 }' "$ledger")"
    repairs=$(awk -F'\t' '$5 == "repair" { c++ } END { print c + 0 }' "$ledger")
    if ((repairs)); then echo "repairs $repairs"; fi
    echo "last $(awk -F'\t' '$1 != "" { l = "#" $1 " " $2 " " $3 } END { print (l == "" ? "-" : l) }' "$ledger")"
    echo "backoff $((until_t > now ? until_t - now : 0))"
    ;;
esac
