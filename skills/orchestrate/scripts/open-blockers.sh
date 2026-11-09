#!/usr/bin/env bash
# Mechanical blocker check before any lane or cloud dispatch: is an issue blocked by an open issue?
# Reads GitHub's native "blocked by" dependencies and "Blocked by #N" lines in the issue body, and
# looks up each referenced issue's state. Read-only; every read goes through gh-read.sh.
#
# Usage: open-blockers.sh [--repo OWNER/REPO] <issue>...
#   <issue>  an issue number (a leading # is accepted)
# Sources, per issue:
#   GET repos/{o}/{r}/issues/{n}/dependencies/blocked_by   open entries (other repositories too)
#   body lines containing "blocked by" (any case, "Blocked by: #12, #13" too): each #N, or
#   https://github.com/OWNER/REPO/issues/N of this repository, after the phrase on that line;
#   each one's state is looked up (a reference that does not exist is not a blocker)
# Output, one line per issue, in argument order:
#   <n> BLOCKED by #a #b       open blockers (OWNER/REPO#c for another repository)
#   <n> clear                  no open blocker
#   <n> unreadable <what>      the issue, its dependencies or a referenced issue could not be read
# Exit: 0 all clear | 2 usage | 3 at least one blocked (none unreadable) | 4 at least one unreadable
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
# The caller's budget priority when it declared one (issue-candidates.sh sweep runs it at low).
caller_priority=${GH_BUDGET_PRIORITY:-}
orch_gh_priority normal
[[ -z "$caller_priority" ]] || orch_gh_priority "$caller_priority"

repo="" issues=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    -*) echo "open-blockers.sh: unknown argument: $1" >&2; exit 2 ;;
    *) n=${1#\#}
       [[ "$n" =~ ^[0-9]+$ ]] || { echo "open-blockers.sh: not an issue number: $1" >&2; exit 2; }
       issues+=("$n"); shift ;;
  esac
done
((${#issues[@]})) || { orch_usage >&2; exit 2; }
repo=$(orch_repo "$repo")

ghr() { "$here/gh-read.sh" --json -- "$@"; }   # bounded, typed, read-only
work=$(mktemp -d "${TMPDIR:-/tmp}/open-blockers.XXXXXX")
trap 'rm -rf "$work"' EXIT
: >"$work/states"   # cache: "<n> <state>" per issue read in this run

# state_of N -> open | closed | missing (does not exist); exit 1 when it cannot be read.
state_of() {
  local s rc=0
  s=$(awk -v n="$1" '$1 == n { print $2; exit }' "$work/states")
  if [[ -z "$s" ]]; then
    s=$(ghr api "repos/$repo/issues/$1" 2>/dev/null | jq -r '.state // empty') || rc=$?
    if ((rc == 3)); then s=missing; elif ((rc != 0)) || [[ -z "$s" ]]; then return 1; fi
    echo "$1 $s" >>"$work/states"
  fi
  echo "$s"
}

any_blocked=no any_unreadable=no
for n in "${issues[@]}"; do
  if ! issue=$(ghr api "repos/$repo/issues/$n" 2>/dev/null); then
    echo "$n unreadable issue"; any_unreadable=yes; continue
  fi
  echo "$n $(jq -r .state <<<"$issue")" >>"$work/states"
  # Native dependencies; a repository without the feature answers 404, which means none.
  rc=0 deps=$(ghr api "repos/$repo/issues/$n/dependencies/blocked_by?per_page=100" 2>/dev/null) || rc=$?
  if ((rc == 3)); then deps='[]'
  elif ((rc != 0)); then echo "$n unreadable dependencies"; any_unreadable=yes; continue
  fi
  blockers=$(jq -r --arg repo "$repo" '.[] | select(.state == "open")
    | (.repository_url // "" | sub("^.*/repos/"; "")) as $r
    | if $r == "" or ($r | ascii_downcase) == ($repo | ascii_downcase) then "#\(.number)" else "\($r)#\(.number)" end' <<<"$deps")
  known=$(jq -r --arg repo "$repo" '.[] | (.repository_url // "" | sub("^.*/repos/"; "")) as $r
    | select($r == "" or ($r | ascii_downcase) == ($repo | ascii_downcase)) | .number' <<<"$deps")
  # Body references not already answered by the dependency list.
  refs=$(jq -r --arg repo "$repo" --argjson self "$n" '
    ($repo | gsub("\\."; "\\.")) as $re
    | [(.body // "") | split("\n")[] | select(test("\\bblocked\\s+by\\b"; "i"))
       | sub("^.*?\\bblocked\\s+by\\b"; ""; "i") as $rest
       | ([$rest | scan("(?:^|[^\\w/])#(\\d+)\\b") | .[0]]
          + [$rest | scan("github\\.com/" + $re + "/issues/(\\d+)"; "i") | .[0]])[]
       | tonumber | select(. != $self)] | unique | .[]' <<<"$issue")
  unreadable=""
  for m in $refs; do
    grep -qx "$m" <<<"$known" && continue
    if ! s=$(state_of "$m"); then unreadable="#$m"; break; fi
    [[ "$s" != open ]] || blockers+=$'\n'"#$m"
  done
  if [[ -n "$unreadable" ]]; then echo "$n unreadable $unreadable"; any_unreadable=yes; continue; fi
  list=$(awk 'NF && !seen[$0]++' <<<"$blockers" | tr '\n' ' ' | sed 's/ $//')
  if [[ -n "$list" ]]; then echo "$n BLOCKED by $list"; any_blocked=yes; else echo "$n clear"; fi
done
if [[ "$any_unreadable" == yes ]]; then exit 4; fi
if [[ "$any_blocked" == yes ]]; then exit 3; fi
exit 0
