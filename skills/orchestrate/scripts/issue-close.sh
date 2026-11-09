#!/usr/bin/env bash
# Close ONE issue as already fixed, as a duplicate, or as completed, with the evidence in the
# closing comment. Standardizes what bots may do to the tracker and records every action.
#
# Usage: issue-close.sh --issue N --as fixed --pr P --evidence TEXT [--repo OWNER/REPO] [--dry-run]
#        issue-close.sh --issue N --as duplicate --of M --evidence TEXT [--repo OWNER/REPO] [--dry-run]
#        issue-close.sh --issue N --as completed [--pr P] --evidence TEXT [--platforms LIST|none]
#                       [--device PLATFORM=EVIDENCE]... [--repo OWNER/REPO] [--dry-run]
#   fixed      P must be a MERGED pull request; evidence = file:line on the default branch showing
#              the defect is gone
#   duplicate  M must be a different, OPEN issue; evidence = the sentence in each issue that shows
#              the same defect, and anything N adds that M lacks
#   completed  the issue's work is done. Gated by the campaign's close policy (campaign.sh
#              close-policy): owner-only (default) needs an owner decision recorded on the issue
#              ("Owner decision (YYYY-MM-DD): ...", decision.sh record); verified also accepts a
#              MERGED --pr P plus --platforms (every platform the change touches, or none) and one
#              --device PLATFORM=EVIDENCE per platform. A given --pr must be merged either way.
# Refuses an issue carrying a --keep-label (default: pinned, epic, needs-human, needs-decision;
# repeatable).
# Each close is journaled (<state dir>/ops/close-issue<N>.json) and its comment carries a hidden
# marker, so a retry after a partial failure (comment posted, close lost, or no readback) finishes
# the close without posting the comment again, and an already-finished close is reported once.
# Exit: 0 closed (or would close) | 3 refused | 5 close failed (rerun finishes it) | 9 outcome
#       unknown (the issue could not be read back; rerun to reconcile).
# Appends one line per completed close to <state dir>/hygiene-actions.log. After a close, prints
# one "stop: lane ..." line per active lane in lanes.tsv on the issue (lane-claim.sh on-issue):
# whoever ran the close passes those on, and the orchestrator sends each lane a stop message.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

repo="" issue="" as="" pr="" of="" evidence="" dry=no platforms=""
keep=() devices=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --as) as=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --of) of=$2; shift 2 ;;
    --evidence) evidence=$2; shift 2 ;;
    --keep-label) keep+=("$2"); shift 2 ;;
    --platforms) platforms=$2; shift 2 ;;
    --device) devices+=("$2"); shift 2 ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "issue-close.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$issue" && -n "$as" && ${#evidence} -ge 20 ]] || { orch_usage >&2; exit 2; }
((${#keep[@]})) || keep=(pinned epic needs-human needs-decision)
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
stops() { "$here/lane-claim.sh" on-issue --issues "$issue" --repo "$repo" || true; }
# The newest owner decision recorded on the issue (its first line), or nothing.
decision_line() {
  jq -r '[.comments[]?.body | select(test("^Owner decision \\([0-9]{4}-[0-9]{2}-[0-9]{2}\\): "))] | last // empty
    | split("\n")[0]' <<<"$1"
}
pr_merged() { [[ "$(gh pr view "$1" --repo "$repo" --json state | jq -r .state)" == MERGED ]]; }

info=$(view) || { echo "unverified: issue $issue could not be read"; exit 9; }
# An unfinished earlier close of this issue: finish or report it, never repeat its comment.
if [[ -f "$journal" && "$dry" == no ]] && [[ "$(jq -r .state "$journal")" =~ ^(intent|commented|unknown)$ ]] &&
  [[ "$(jq -r .marker "$journal")" == "$marker" ]]; then
  if [[ "$(jq -r .state <<<"$info")" == CLOSED ]]; then
    jset "done"; done_log
    echo "closed $issue as $as (earlier attempt)"; stops; exit 0
  fi
fi
[[ "$(jq -r .state <<<"$info")" == OPEN ]] || refuse "issue $issue is not open"
for label in "${keep[@]}"; do
  jq -e --arg l "$label" '[.labels[].name] | index($l)' <<<"$info" >/dev/null && refuse "issue $issue is labelled $label"
done

case "$as" in
  fixed)
    [[ -n "$pr" ]] || refuse "--as fixed needs --pr"
    pr_merged "$pr" || refuse "PR $pr is not merged"
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
  completed)
    policy=owner-only
    [[ ! -f "$state/campaign.json" ]] || policy=$(jq -r '.close_policy // "owner-only"' "$state/campaign.json")
    [[ -z "$pr" ]] || pr_merged "$pr" || refuse "PR $pr is not merged"
    decision=$(decision_line "$info")
    if [[ -n "$decision" ]]; then
      proof="$decision"
    elif [[ "$policy" == verified ]]; then
      [[ -n "$pr" ]] || refuse "close policy verified needs a merged --pr (or an owner decision on the issue)"
      [[ -n "$platforms" ]] || refuse "close policy verified needs --platforms (every platform the change touches, or none)"
      if [[ "$platforms" == none ]]; then
        proof="No device-facing platform is touched."
      else
        proof="Device evidence:"
        for plat in ${platforms//,/ }; do
          ev=""
          for d in "${devices[@]+"${devices[@]}"}"; do
            [[ "${d%%=*}" != "$plat" ]] || ev=${d#*=}
          done
          [[ ${#ev} -ge 10 ]] || refuse "no device evidence for $plat (--device $plat=EVIDENCE)"
          proof+=$'\n'"- $plat: $ev"
        done
      fi
    else
      refuse "close policy owner-only: no owner decision recorded on issue $issue (decision.sh record)"
    fi
    body="Closing as completed${pr:+ by [#$pr]($url/pull/$pr)}.

$evidence

$proof
Close policy: $policy."
    args=(--reason completed)
    ;;
  *) refuse "--as must be fixed, duplicate or completed" ;;
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
  stops
elif has_marker "$after"; then
  jset commented
  echo "close failed after the comment was posted (exit $rc); rerun to finish without a second comment"; exit 5
else
  jset failed
  echo "close failed (exit $rc)"; exit 5
fi
