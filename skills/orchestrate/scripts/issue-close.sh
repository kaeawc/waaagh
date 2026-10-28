#!/usr/bin/env bash
# Close ONE issue as already fixed or as a duplicate, with the evidence in the closing comment.
# Standardizes what the hygiene bot may do to the tracker and records every action.
#
# Usage: issue-close.sh --issue N --as fixed --pr P --evidence TEXT [--repo OWNER/REPO] [--dry-run]
#        issue-close.sh --issue N --as duplicate --of M --evidence TEXT [--repo OWNER/REPO] [--dry-run]
#   fixed      P must be a MERGED pull request; evidence = file:line on the default branch showing
#              the defect is gone
#   duplicate  M must be a different, OPEN issue; evidence = the sentence in each issue that shows
#              the same defect, and anything N adds that M lacks
# Refuses an issue carrying a --keep-label (default: pinned, epic, needs-human; repeatable).
# Each close is journaled (<state dir>/ops/close-issue<N>.json) and its comment carries a hidden
# marker, so a retry after a partial failure (comment posted, close lost, or no readback) finishes
# the close without posting the comment again, and an already-finished close is reported once.
# Exit: 0 closed (or would close) | 3 refused | 5 close failed (rerun finishes it) | 9 outcome
#       unknown (the issue could not be read back; rerun to reconcile).
# Appends one line per completed close to <state dir>/hygiene-actions.log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" issue="" as="" pr="" of="" evidence="" dry=no
keep=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --as) as=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --of) of=$2; shift 2 ;;
    --evidence) evidence=$2; shift 2 ;;
    --keep-label) keep+=("$2"); shift 2 ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "issue-close.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$issue" && -n "$as" && ${#evidence} -ge 20 ]] || { sed -n '2,17p' "$0" >&2; exit 2; }
((${#keep[@]})) || keep=(pinned epic needs-human)
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
url="https://github.com/$repo"
refuse() { echo "refused: $*"; exit 3; }

journal="$state/ops/close-issue$issue.json"
marker="<!-- waaagh:close issue=$issue as=$as${pr:+ pr=$pr}${of:+ of=$of} -->"
done_log() { printf '%s\tclose\tissue=%s\tas=%s\t%s\n' "$(orch_iso "$(orch_now)")" "$issue" "$as" "${pr:+pr=$pr}${of:+of=$of}" >>"$state/hygiene-actions.log"; }
jset() { orch_journal "$journal" "$(jq -c --arg s "$1" '.state = $s' "$journal")"; }
view() { orch_read_retry 3 gh issue view "$issue" --repo "$repo" --json state,labels,comments; }
has_marker() { jq -e --arg m "$marker" '[.comments[]?.body | select(contains($m))] | length > 0' <<<"$1" >/dev/null; }

info=$(view) || { echo "unverified: issue $issue could not be read"; exit 9; }
# An unfinished earlier close of this issue: finish or report it, never repeat its comment.
if [[ -f "$journal" && "$dry" == no ]] && [[ "$(jq -r .state "$journal")" =~ ^(intent|commented|unknown)$ ]] &&
  [[ "$(jq -r .marker "$journal")" == "$marker" ]]; then
  if [[ "$(jq -r .state <<<"$info")" == CLOSED ]]; then
    jset "done"; done_log
    echo "closed $issue as $as (earlier attempt)"; exit 0
  fi
fi
[[ "$(jq -r .state <<<"$info")" == OPEN ]] || refuse "issue $issue is not open"
for label in "${keep[@]}"; do
  jq -e --arg l "$label" '[.labels[].name] | index($l)' <<<"$info" >/dev/null && refuse "issue $issue is labelled $label"
done

case "$as" in
  fixed)
    [[ -n "$pr" ]] || refuse "--as fixed needs --pr"
    [[ "$(gh pr view "$pr" --repo "$repo" --json state | jq -r .state)" == MERGED ]] || refuse "PR $pr is not merged"
    body="Closing as already fixed by [#$pr]($url/pull/$pr).

$evidence

Reopen if the defect still reproduces on the current default branch."
    args=(--reason completed)
    ;;
  duplicate)
    [[ -n "$of" && "$of" != "$issue" ]] || refuse "--as duplicate needs --of a different issue"
    [[ "$(gh issue view "$of" --repo "$repo" --json state | jq -r .state)" == OPEN ]] || refuse "issue $of is not open"
    body="Closing as a duplicate of [#$of]($url/issues/$of).

$evidence"
    args=(--duplicate-of "$of")
    ;;
  *) refuse "--as must be fixed or duplicate" ;;
esac

if [[ "$dry" == yes ]]; then
  printf 'would close %s as %s:\n%s\n' "$issue" "$as" "$body"
  exit 0
fi
orch_journal "$journal" "$(jq -cn --arg repo "$repo" --argjson issue "$issue" --arg as "$as" --arg target "${pr:-$of}" \
  --arg marker "$marker" --arg at "$(orch_iso "$(orch_now)")" \
  '{op: "close", repo: $repo, issue: $issue, as: $as, target: $target, marker: $marker, state: "intent", started_at: $at}')"
rc=0
if has_marker "$info"; then
  # The comment of an earlier attempt is already there: close without commenting again.
  gh issue close "$issue" --repo "$repo" "${args[@]}" >/dev/null 2>&1 || rc=$?
else
  gh issue close "$issue" --repo "$repo" "${args[@]}" --comment "$body

$marker" >/dev/null 2>&1 || rc=$?
fi
if ! after=$(view); then
  jset unknown
  echo "unverified: close of issue $issue sent (exit $rc) but not read back; rerun to reconcile"; exit 9
fi
if [[ "$(jq -r .state <<<"$after")" == CLOSED ]]; then
  jset "done"; done_log
  echo "closed $issue as $as"
elif has_marker "$after"; then
  jset commented
  echo "close failed after the comment was posted (exit $rc); rerun to finish without a second comment"; exit 5
else
  jset failed
  echo "close failed (exit $rc)"; exit 5
fi
