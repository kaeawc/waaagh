#!/usr/bin/env bash
# Owner decisions: record one on its issue, ask the open ones as one batched question, and list the
# steps only the owner can take. Format and rules: owner-decisions.md.
#
# Usage: decision.sh record --issue N --text TEXT [--step TEXT]... [--date YYYY-MM-DD]
#                           [--label L] [--repo OWNER/REPO] [--dry-run]
#        decision.sh batch [--file PATH] [--repo OWNER/REPO]
#        decision.sh steps --issues N[,M] [--repo OWNER/REPO]
#   record  posts "Owner decision (DATE): TEXT" on issue N (DATE defaults to today, UTC), with an
#           "Owner steps:" checklist when --step is given, then removes label L (default
#           needs-decision) and ticks the "- [ ] #N ..." line in <state dir>/decisions.md. The
#           comment carries a hidden marker, so a rerun after a partial failure never posts it twice.
#           Appends one line to <state dir>/decisions.log.
#   batch   prints ONE question for every open "- [ ]" line of decisions.md (default <state
#           dir>/decisions.md): option 1 applies every recommendation and lists each, option 2 goes
#           one at a time, option 3 leaves them. A line names its recommendation in a
#           "— recommend: X —" field; lines without one are listed apart, for one at a time.
#   steps   prints one "- [ ] #N STEP" line per unchecked owner step in the decisions recorded on
#           the issues, or "no owner steps".
# Exit: 0 ok | 2 usage | 4 an issue could not be read (steps: the others are still printed)
#       | 5 a write failed (rerun finishes it) | 9 outcome unknown (record: no readback; rerun)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { sed -n '2,21p' "$0" >&2; exit 2; }
case "${1:-}" in -h | --help) sed -n '2,21p' "$0"; exit 0 ;; -*) echo "decision.sh: unknown argument: $1" >&2; exit 2 ;; esac
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" issue="" issues="" text="" date="" label=needs-decision file="" dry=no
steps=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --issues) issues=$2; shift 2 ;;
    --text) text=$2; shift 2 ;;
    --step) steps+=("$2"); shift 2 ;;
    --date) date=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --file) file=$2; shift 2 ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "decision.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  record) [[ "$issue" =~ ^[0-9]+$ && -n "$text" ]] || usage
    [[ -z "$date" || "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage ;;
  batch) ;;
  steps) [[ -n "$issues" ]] || usage ;;
  *) usage ;;
esac
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")

record() {
  local body key marker info after rc=0 s
  [[ -n "$date" ]] || date=$(orch_iso "$(orch_now)" | cut -c1-10)
  body="Owner decision ($date): $text"
  if ((${#steps[@]})); then
    body+=$'\n\nOwner steps:'
    for s in "${steps[@]}"; do body+=$'\n'"- [ ] $s"; done
  fi
  key=$(printf '%s' "$body" | cksum | cut -d' ' -f1)
  marker="<!-- waaagh:decision issue=$issue key=$key -->"
  if [[ "$dry" == yes ]]; then
    printf 'would record on %s (and remove %s):\n%s\n' "$issue" "$label" "$body"
    return 0
  fi
  info=$(orch_read_retry 3 gh issue view "$issue" --repo "$repo" --json labels,comments) ||
    { echo "unverified: issue $issue could not be read"; exit 9; }
  if ! jq -e --arg m "$marker" '[.comments[]?.body | select(contains($m))] | length > 0' <<<"$info" >/dev/null; then
    gh issue comment "$issue" --repo "$repo" --body "$body

$marker" >/dev/null 2>&1 || rc=$?
    after=$(orch_read_retry 3 gh issue view "$issue" --repo "$repo" --json labels,comments) ||
      { echo "unverified: decision comment on $issue sent (exit $rc) but not read back; rerun to reconcile"; exit 9; }
    jq -e --arg m "$marker" '[.comments[]?.body | select(contains($m))] | length > 0' <<<"$after" >/dev/null ||
      { echo "decision comment on $issue failed (exit $rc)"; exit 5; }
    info=$after
  fi
  if jq -e --arg l "$label" '[.labels[]?.name] | index($l)' <<<"$info" >/dev/null; then
    gh issue edit "$issue" --repo "$repo" --remove-label "$label" >/dev/null 2>&1 ||
      { echo "decision recorded on $issue but removing $label failed; rerun to finish"; exit 5; }
  fi
  if [[ -f "$state/decisions.md" ]]; then
    awk -v n="#$issue" 'index($0, "- [ ] " n " ") == 1 { $0 = "- [x] " substr($0, 7) } { print }' \
      "$state/decisions.md" >"$state/decisions.md.tmp" && mv "$state/decisions.md.tmp" "$state/decisions.md"
  fi
  printf '%s\tdecision\tissue=%s\tsteps=%s\t%s\n' "$(orch_iso "$(orch_now)")" "$issue" "${#steps[@]}" "$text" >>"$state/decisions.log"
  echo "recorded decision on $issue"
}

batch() {
  local f=${file:-$state/decisions.md}
  [[ -f "$f" ]] || { echo "no open decisions"; return 0; }
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    index($0, "- [ ] ") == 1 {
      line = substr($0, 7); n = split(line, part, " — "); rec = ""; q = trim(part[1])
      for (i = 2; i <= n; i++) if (tolower(trim(part[i])) ~ /^recommend(ed|ation)?:/) { rec = trim(part[i]); sub(/^[^:]*:[ \t]*/, "", rec) }
      if (rec != "") { r[++nr] = q " → " rec } else { u[++nu] = q }
    }
    END {
      total = nr + nu
      if (total == 0) { print "no open decisions"; exit }
      printf "%d decision%s pending. How should I settle %s?\n", total, (total == 1 ? " is" : "s are"), (total == 1 ? "it" : "them")
      if (nr > 0) {
        printf "1. Apply all my recommendations (recommended)%s:\n", (nu > 0 ? ", for the " nr " that have one" : "")
        for (i = 1; i <= nr; i++) print "   - " r[i]
        print "2. One at a time"
        print "3. Leave them for now"
      } else {
        print "1. One at a time (no recommendation to apply)"
        print "2. Leave them for now"
      }
      if (nu > 0) {
        print "Without a recommendation (asked one at a time either way):"
        for (i = 1; i <= nu; i++) print "   - " u[i]
      }
    }' "$f"
}

owner_steps() {
  local i info out="" rc=0
  for i in ${issues//,/ }; do
    if ! info=$(orch_read_retry 3 gh issue view "$i" --repo "$repo" --json comments); then
      echo "unverified: issue $i could not be read" >&2; rc=4; continue
    fi
    out+=$(jq -r --arg n "$i" '.comments[]?.body | select(test("^Owner decision \\([0-9]{4}-[0-9]{2}-[0-9]{2}\\): "))
      | split("\n") | map(sub("\r$"; "")) | (index("Owner steps:") // empty) as $at | .[$at + 1:]
      | (map(test("^- \\[[ x]\\] ") | not) | index(true) // length) as $end | .[:$end][]
      | select(startswith("- [ ] ")) | "- [ ] #\($n) " + .[6:]' <<<"$info")$'\n'
  done
  out=$(printf '%s' "$out" | awk 'NF && !seen[$0]++')
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; else echo "no owner steps"; fi
  return "$rc"
}

case "$cmd" in
  record) record ;;
  batch) batch ;;
  steps) owner_steps ;;
esac
