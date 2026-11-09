#!/usr/bin/env bash
# Rerun first, reproduce second: what to do with a failing PR check before spending a lane on it.
# A check whose domain (the paths it lints, builds or tests) does not intersect the PR's changed
# paths, and that the repository's classifier cannot place, is re-run once; a reproduction lane is
# spent only when the same check fails again on the same head. Doctrine: failure-triage.md.
#
# Usage: failure-triage.sh <decide|rerun|record|match|list> [--repo OWNER/REPO] [options]
#   decide --pr N --head SHA --check NAME [--verdict V] [--log FILE] [--file PATH]...
#             print one line: `<action> <reason> [key=value]...`, action one of
#               rerun      re-run the failed jobs once (`rerun` below): a known flake or infra
#                          verdict, a recorded signature in --log, or a check whose domain is
#                          disjoint from the changed paths with an unknown verdict
#               reproduce  this check was already re-run once on this head and failed again: now
#                          reproduce it (or fix it), and record its signature once the cause is known
#               triage     ordinary triage (read the log, fix if the diff caused it): the classifier
#                          placed it, the domain intersects the diff, or no domain is configured
#             V is the classifier's first word (any case, `_` = `-`); empty, unknown, unclassified
#             and none mean unknown. --file lists the changed paths; without it they are read from
#             GitHub (renames count under both names).
#   rerun --pr N --head SHA --check NAME --run ID [--reason TEXT]
#             re-run run ID's failed jobs (`gh run rerun --failed`) once per PR, head and check, after
#             checking the PR's head is still SHA; logged to pr-reruns.tsv
#   record --check GLOB --pattern ERE --note TEXT [--source TEXT]
#             add a failure signature (an extended regex over the job log) for checks matching GLOB;
#             print its id. A later `decide --log` or `match` that finds it classifies the failure.
#   match --check NAME --log FILE   print `<id>\t<note>` of the first signature found in FILE
#   list      print the signature store
# Domains, one per line in <state dir>/check-domains (`#` comments, blank lines ignored):
#   <check name glob> => <path pattern> [<path pattern>...]
# e.g. `lint* => *.ts *.tsx package.json .oxlintrc.json`. The first line whose glob matches the
# check wins. A pattern ending in `/` is a directory prefix; otherwise a bash glob where `*` also
# matches `/` (as in merge-sensitive). Files in <state dir>: check-domains, failure-signatures.tsv
# (id, check glob, pattern, note, source, ISO time), pr-reruns.tsv (ISO time, pr=, head=, check=,
# run=, outcome).
# Exit: 0 ok (match: found) | 1 match: none | 2 usage | 3 refused (already re-run on this head;
#       signature already recorded) | 4 stale (the PR's head is no longer SHA) | 5 GitHub refused the
#       rerun | 9 unverified (changed paths or head unreadable)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi

usage() { orch_usage; }
cmd=${1:-}
case "$cmd" in
  decide | rerun | record | match | list) shift ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
repo="" pr="" head="" check="" verdict="" log="" run_id="" reason="" pattern="" note="" src=""
files=()
have_files=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --check) check=$2; shift 2 ;;
    --verdict) verdict=$2; shift 2 ;;
    --log) log=$2; shift 2 ;;
    --file) files+=("$2"); have_files=yes; shift 2 ;;
    --run) run_id=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --pattern) pattern=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    --source) src=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "failure-triage.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
bad() { echo "failure-triage.sh: $1" >&2; exit 2; }
case "$cmd" in
  decide | rerun)
    [[ "$pr" =~ ^[0-9]+$ ]] || bad "--pr N is required"
    [[ "$head" =~ ^[0-9a-f]{7,40}$ ]] || bad "--head SHA (7-40 hex) is required"
    [[ -n "$check" ]] || bad "--check NAME is required"
    [[ "$cmd" == decide || "$run_id" =~ ^[0-9]+$ ]] || bad "--run ID is required"
    [[ -z "$log" || -r "$log" ]] || bad "--log $log is not readable" ;;
  record)
    [[ -n "$check" && -n "$pattern" && -n "$note" ]] || bad "--check, --pattern and --note are required"
    [[ "$check$pattern$note$src" != *$'\t'* && "$check$pattern$note$src" != *$'\n'* ]] || bad "no tabs or newlines in fields"
    rc=0; grep -Eq -e "$pattern" </dev/null || rc=$?
    ((rc != 2)) || bad "--pattern is not a valid extended regex" ;;
  match)
    [[ -n "$check" && -r "$log" ]] || bad "--check NAME and a readable --log FILE are required" ;;
esac

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
now=$(orch_now)
sigs="$state/failure-signatures.tsv"
reruns="$state/pr-reruns.tsv"
domains="$state/check-domains"

# path_matches PATTERN FILE (merge-sensitive.sh semantics)
path_matches() {
  local p=$1 f=$2
  if [[ "$p" == */ ]]; then [[ "$f" == "$p"* ]]; else
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ "$f" == $p ]]
  fi
}

# find_sig NAME FILE -> "<id>\t<note>" of the first signature for NAME whose pattern is in FILE.
find_sig() {
  local id glob pat nt _rest
  [[ -f "$sigs" ]] || return 1
  while IFS=$'\t' read -r id glob pat nt _rest; do
    [[ -n "$id" ]] || continue
    # shellcheck disable=SC2053  # the check glob is a glob on purpose
    [[ "$1" == $glob ]] || continue
    if grep -Eq -e "$pat" "$2"; then printf '%s\t%s\n' "$id" "$nt"; return 0; fi
  done <"$sigs"
  return 1
}

# head_eq A B: one SHA is a prefix of the other.
head_eq() { [[ "$1" == "$2"* || "$2" == "$1"* ]]; }

# rerun_of PR HEAD CHECK -> the run id of the latest non-refused rerun of that check on that head.
rerun_of() {
  [[ -f "$reruns" ]] || return 1
  local line="" _t p h c r o
  while IFS=$'\t' read -r _t p h c r o; do
    [[ "$p" == "pr=$1" && "$c" == "check=$3" ]] || continue
    head_eq "${h#head=}" "$2" || continue
    if [[ "$o" == failed* ]]; then line=""; else line=${r#run=}; fi
  done <"$reruns"
  [[ -n "$line" ]] && echo "$line"
}

case "$cmd" in
  list)
    [[ ! -f "$sigs" ]] || cat "$sigs"
    exit 0 ;;
  match)
    find_sig "$check" "$log" || exit 1
    exit 0 ;;
  record)
    if [[ -f "$sigs" ]]; then
      existing=$(awk -F'\t' -v c="$check" -v p="$pattern" '$2 == c && $3 == p { print $1; exit }' "$sigs")
      [[ -z "$existing" ]] || { echo "refused: already recorded as $existing"; exit 3; }
    fi
    n=$( [[ -f "$sigs" ]] && awk -F'\t' '{ sub(/^sig-/, "", $1); if ($1 + 0 > m) m = $1 + 0 } END { print m + 0 }' "$sigs" || echo 0)
    id="sig-$((n + 1))"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$check" "$pattern" "$note" "${src:--}" "$(orch_iso "$now")" >>"$sigs"
    echo "$id"
    exit 0 ;;
  rerun)
    if prev=$(rerun_of "$pr" "$head" "$check"); then
      echo "refused: $check on PR $pr head ${head:0:9} was already re-run (run $prev); a second failure is reproduced, not re-run"
      exit 3
    fi
    live=$("$here/gh-read.sh" --json -- pr view "$pr" --repo "$repo" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty') || live=""
    [[ -n "$live" ]] || { echo "unverified: the head of PR $pr could not be read"; exit 9; }
    head_eq "$live" "$head" || { echo "stale: PR $pr head is ${live:0:9}, not ${head:0:9}; old-head results are void, resnapshot"; exit 4; }
    rec() { printf '%s\tpr=%s\thead=%s\tcheck=%s\trun=%s\t%s\n' "$(orch_iso "$now")" "$pr" "$live" "$check" "$run_id" "$1" >>"$reruns"; }
    rec "intent${reason:+ $reason}"
    if ! out=$(gh run rerun "$run_id" --failed --repo "$repo" 2>&1); then
      rec "failed: ${out//$'\n'/ }"
      echo "failed: gh run rerun $run_id: ${out:0:200}"
      exit 5
    fi
    rec rerun-requested
    echo "rerun requested: run $run_id ($check) on PR $pr head ${live:0:9}; if it fails again, reproduce"
    exit 0 ;;
esac

# ---- decide ------------------------------------------------------------------------------------
v=$(printf '%s' "$verdict" | tr '[:upper:]_' '[:lower:]-')
case "$v" in "" | unknown | unclassified | none) v=unknown ;; esac
prev=$(rerun_of "$pr" "$head" "$check") || prev=""

case "$v" in
  flake | known-flake | infra)
    if [[ -n "$prev" ]]; then echo "reproduce second-failure verdict=$v rerun=$prev"
    else echo "rerun classified verdict=$v"; fi
    exit 0 ;;
  unknown) ;;
  *) echo "triage classified verdict=$v"; exit 0 ;;
esac

if [[ -n "$prev" ]]; then
  echo "reproduce second-failure rerun=$prev"
  exit 0
fi
if [[ -n "$log" ]] && hit=$(find_sig "$check" "$log"); then
  echo "rerun known-signature id=${hit%%$'\t'*}"
  exit 0
fi

# The check's domain: the first check-domains line whose glob matches.
dom=""
if [[ -f "$domains" ]]; then
  dom=$(sed -e 's/#.*//' "$domains" | awk -v c="$check" '
    index($0, "=>") {
      g = substr($0, 1, index($0, "=>") - 1); p = substr($0, index($0, "=>") + 2)
      gsub(/^[ \t]+|[ \t]+$/, "", g); gsub(/^[ \t]+|[ \t]+$/, "", p)
      if (g != "" && p != "") print g "\t" p
    }' | while IFS=$'\t' read -r g p; do
      # shellcheck disable=SC2053  # the check glob is a glob on purpose
      if [[ "$check" == $g ]]; then echo "$p"; break; fi
    done)
fi
if [[ -z "$dom" ]]; then
  echo "triage no-domain"
  exit 0
fi

if [[ "$have_files" == no ]]; then
  list=$(orch_read_retry 3 gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" \
    --jq '.[] | .filename, (.previous_filename // empty)') ||
    { echo "unverified: the files of PR $pr could not be read"; exit 9; }
  while IFS= read -r f; do [[ -z "$f" ]] || files+=("$f"); done <<<"$list"
fi
((${#files[@]})) || { echo "unverified: PR $pr has no changed paths to compare"; exit 9; }

read -r -a pats <<<"$dom"
for f in "${files[@]}"; do
  for p in "${pats[@]}"; do
    if path_matches "$p" "$f"; then echo "triage intersects path=$f pattern=$p"; exit 0; fi
  done
done
echo "rerun disjoint files=${#files[@]} domain=${dom// /,}"
