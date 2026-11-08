#!/usr/bin/env bash
# Duplicate-work guard: before a lane starts, refuse it when another active lane or an open PR
# already covers the same issue or overlapping files. Keeps <state dir>/lanes.tsv.
#
# Usage: lane-claim.sh check --issues N[,M] --files PATH[,PATH] [--repo OWNER/REPO]
#        lane-claim.sh add   --worktree DIR --branch B --issues N[,M] --files PATH[,PATH]
#                            [--agent NAME] [--repo OWNER/REPO]
#        lane-claim.sh set   --worktree DIR --status STATUS [--repo OWNER/REPO]
#        lane-claim.sh on-issue --issues N[,M] [--repo OWNER/REPO]
#        lane-claim.sh closed [--repo OWNER/REPO]
#   check  reads the active rows of lanes.tsv and every open PR (its closing issues, "#N" in its
#          title or body, and its changed files) and prints "ok" or one "conflict: ..." line per
#          overlap. A path ending in "/" covers everything under it.
#   add    the same check, then appends the lane as `active` (under a lock, so two launches cannot
#          both pass). Refused when the check finds a conflict.
#          Lane branches are named work/<first issue>-<slug>; add notes any other name on stderr
#          (not refused: the merge loop selects PRs by author and readiness, never by branch name).
#   set    sets a lane's status (last column), e.g. merged, closed, done, abandoned: those end it.
#   on-issue  prints one "stop: lane WT branch B agent A issue N" line per active lane on one of
#          the issues (nothing when none); issue-close.sh runs it after every close.
#   closed prints the same stop lines for every active lane any of whose issues is now closed on
#          GitHub, however it closed (merged PR, owner, sweep). Send each lane a stop message, then
#          `set --status closed` once it has stopped.
# lanes.tsv columns: worktree  branch  issues  files  agent  status
# GraphQL refused (Claude Code cloud sessions answer `gh pr list` with HTTP 403):
# ORCHESTRATE_GH_API=auto (default) then reads the open PRs over REST (gh-rest-pr.sh): the list,
# plus each PR's files only when --files is given. Closing issues come from the PR body there
# ("Fixes #N"), not from issues linked by hand in the sidebar. =rest skips the GraphQL attempt,
# =graphql never falls back. A refusal is remembered 12 hours (<state root>/gh-no-graphql).
# Exit: 0 ok | 3 conflict | 4 the open PRs (check, add) or an issue (closed: the others are still
#       printed) could not be read; no verdict, see gh-read.sh | 2 usage
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

case "${1:-}" in -h | --help) sed -n '2,31p' "$0"; exit 0 ;; -*) echo "lane-claim.sh: unknown argument: $1" >&2; exit 2 ;; esac
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" issues="" files="" worktree="" branch="" agent="-" status=""
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --issues) issues=$2; shift 2 ;;
    --files) files=$2; shift 2 ;;
    --worktree) worktree=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --agent) agent=$2; shift 2 ;;
    --status) status=$2; shift 2 ;;
    -h | --help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "lane-claim.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  check) [[ -n "$issues$files" ]] || { sed -n '2,31p' "$0" >&2; exit 2; } ;;
  add) [[ -n "$worktree" && -n "$branch" && -n "$issues$files" ]] || { sed -n '2,31p' "$0" >&2; exit 2; } ;;
  set) [[ -n "$worktree" && -n "$status" ]] || { sed -n '2,31p' "$0" >&2; exit 2; } ;;
  on-issue) [[ -n "$issues" ]] || { sed -n '2,31p' "$0" >&2; exit 2; } ;;
  closed) ;;
  *) sed -n '2,31p' "$0" >&2; exit 2 ;;
esac
api=$(orch_gh_api lane-claim.sh) || exit 2
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
lanes="$state/lanes.tsv"
touch "$lanes"
lock="$state/.lanes.lock"

with_lock() { # serialize writers; a lock older than 5 minutes is a leftover
  local i
  for ((i = 0; i < 300; i++)); do
    if mkdir "$lock" 2>/dev/null; then
      trap 'rmdir "$lock" 2>/dev/null || true' EXIT
      "$@"
      return
    fi
    [[ -z "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]] || rmdir "$lock" 2>/dev/null || true
    sleep 0.1
  done
  echo "lane-claim.sh: lanes.tsv is locked" >&2; exit 4
}

# conflicts: prints one line per overlap with an active lane or an open PR.
conflicts() {
  local prs rc=0 err n f
  if [[ "$api" != rest ]]; then
    err=$(mktemp)
    prs=$("$here/gh-read.sh" --json -- pr list --repo "$repo" --state open --limit 200 \
      --json number,title,body,closingIssuesReferences,files 2>"$err") || rc=$?
    if orch_gh_refused "$rc" "$(cat "$err")"; then api=rest
    elif ((rc != 0)); then rm -f "$err"; echo "unreadable"; return; fi
    rm -f "$err"
  fi
  if [[ "$api" == rest ]]; then
    prs=$("$here/gh-rest-pr.sh" list --repo "$repo" --limit 200 2>/dev/null) || { echo "unreadable"; return; }
    if [[ -n "$files" ]]; then
      for n in $(jq -r '.[].number' <<<"$prs"); do
        f=$("$here/gh-rest-pr.sh" files --repo "$repo" --pr "$n" 2>/dev/null) || { echo "unreadable"; return; }
        prs=$(jq -c --argjson n "$n" --slurpfile f <(printf '%s\n' "$f") 'map(if .number == $n then .files = $f[0] else . end)' <<<"$prs")
      done
    fi
  fi
  # The PR list travels as a file, not an argument: one argument is capped at 128 KiB (#121).
  jq -rn --arg issues "$issues" --arg files "$files" --rawfile lanes "$lanes" --slurpfile prs <(printf '%s\n' "$prs") '
    def list: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));
    def overlaps($a; $b): $a == $b or ($a | endswith("/") and ($b | startswith($a))) or ($b | endswith("/") and ($a | startswith($b)));
    ($issues | list) as $want_i | ($files | list) as $want_f
    | ([$lanes | split("\n")[] | select(length > 0 and (startswith("#") | not)) | split("\t")
        | select(length >= 6 and (.[5] | IN("done", "merged", "closed", "abandoned") | not))
        | {wt: .[0], issues: (.[2] | list), files: (.[3] | list)}]) as $active
    | ($active[] as $l
       | ($want_i[] | select(. as $i | $l.issues | index($i)) | "conflict: lane \($l.wt) has issue \(.)"),
         ([$want_f[] as $f | $l.files[] | select(overlaps(.; $f)) | $f] | unique[] | "conflict: lane \($l.wt) owns \(.)")),
      ($prs[0][] as $p
       | ($want_i[] | select(. as $i | (($p.closingIssuesReferences // []) | map(.number | tostring) | index($i))
                     or ((($p.title // "") + " " + ($p.body // "")) | test("#" + $i + "\\b")))
          | "conflict: PR \($p.number) covers issue \(.)"),
         ([$want_f[] as $f | ($p.files // [])[] | .path | select(overlaps(.; $f) or overlaps($f; .)) | $f] | unique[]
          | "conflict: PR \($p.number) touches \(.)"))'
}

check_and() {
  local c
  c=$(conflicts)
  if [[ "$c" == unreadable ]]; then echo "unverified: open PRs could not be read; not starting"; exit 4; fi
  if [[ -n "$c" ]]; then printf '%s\n' "$c"; exit 3; fi
  "$@"
}

append() {
  printf '%s\t%s\t%s\t%s\t%s\tactive\n' "$worktree" "$branch" "$issues" "$files" "$agent" >>"$lanes"
  echo "ok: lane $worktree claimed issues ${issues:--} files ${files:--}"
  [[ -z "$issues" || "$branch" == "work/${issues%%,*}-"?* ]] ||
    echo "note: branch $branch is not named work/${issues%%,*}-<slug> (the lane branch standard)" >&2
}
set_status() {
  awk -F'\t' -v OFS='\t' -v wt="$worktree" -v st="$status" '$1 == wt { $NF = st; hit = 1 } { print }
    END { if (!hit) exit 3 }' "$lanes" >"$lanes.tmp" || { rm -f "$lanes.tmp"; echo "no lane $worktree"; exit 3; }
  mv "$lanes.tmp" "$lanes"
  echo "lane $worktree: $status"
}

# active_rows: the lanes that have not ended, as worktree<TAB>branch<TAB>issues<TAB>agent.
active_rows() {
  awk -F'\t' -v OFS='\t' '!/^#/ && NF >= 6 && $NF !~ /^(done|merged|closed|abandoned)$/ { print $1, $2, $3, $5 }' "$lanes"
}
# stop_lines ISSUES: one stop line per active lane on any of the comma-separated issues.
stop_lines() {
  local wt br iss ag i
  while IFS=$'\t' read -r wt br iss ag; do
    for i in ${iss//,/ }; do
      if [[ ",$1," == *",$i,"* ]]; then echo "stop: lane $wt branch $br agent $ag issue $i"; fi
    done
  done < <(active_rows)
}
closed_lanes() {
  local all i st rc=0 shut=""
  all=$(active_rows | cut -f3 | tr ',' '\n' | awk 'NF && !seen[$0]++')
  for i in $all; do
    if ! st=$(orch_read_retry 3 gh issue view "$i" --repo "$repo" --json state); then
      echo "unverified: issue $i could not be read" >&2; rc=4; continue
    fi
    [[ "$(jq -r .state <<<"$st")" != CLOSED ]] || shut+="$i,"
  done
  [[ -z "$shut" ]] || stop_lines "${shut%,}"
  return "$rc"
}

case "$cmd" in
  check) check_and echo ok ;;
  on-issue) stop_lines "$issues" ;;
  closed) closed_lanes ;;
  add) with_lock check_and append ;;
  set) with_lock set_status ;;
esac
