#!/usr/bin/env bash
# Merge ONE pull request after re-checking, at merge time, that it is still the PR that was judged
# ready. Never merges a draft, a fork-head PR, a PR by an unlisted author, or a moved head.
#
# Usage: pr-merge.sh --pr N --head SHA [--repo OWNER/REPO] [--author LOGIN]...
#                    [--method squash|merge|rebase] [--main-fix]
#                    [--admin --except-check NAME... --evidence TEXT] [--ignore-check NAME]...
#   --head      the head SHA (any prefix >= 7) that pr-ready.sh judged; a moved head refuses
#   --admin     bypass branch protection. Allowed only in the fast path: more open PRs than
#               ORCHESTRATE_FAST_PATH_OVER (default 20), or ORCHESTRATE_ADMIN_MERGE=1 when the
#               user authorized it. Needs --evidence naming the classified flake or pending
#               advisory check being bypassed; it is written to the merge log. The exception is
#               only for the checks named by --except-check: a fresh pr-ready.sh row for this PR
#               must show no blocker other than failures of exactly those checks (no review
#               thread, unknown thread or policy read, conflict, pending check, missing required
#               check), or the merge is refused with exit 6.
#   --ignore-check  advisory checks, passed to pr-ready.sh for that row
# Without --admin the same fresh row must be READY for this exact head, or the merge is refused
# with exit 7 (the row's verdict and reasons are printed), so the merge never depends on the
# server's branch protection. Ungated merging is a deliberate mode: ORCHESTRATE_DIRECT_MERGE=1,
# set only on the user's word, skips this readiness gate (not the identity, head or hold checks).
#   --main-fix  this PR fixes a red default branch; merge although MAIN_RED is set
# The merge itself is bound to the full head SHA read here (gh pr merge --match-head-commit), so a
# push that lands between this check and the merge makes GitHub refuse it; that refusal is
# re-read and reported as a moved head, never retried without the guard.
# Every attempt is journaled before the mutation (<state dir>/ops/merge-pr<N>.json: repo, PR, full
# head, attempt id, state) and reconciled after it with bounded reads, keeping the merge command's
# exit code and full output in <state dir>/ops/. A rerun first reconciles an unfinished journal
# against the PR: already MERGED is reported as merged without merging again.
# Exit: 0 merged | 3 ineligible or head moved (also during the merge) | 4 default branch is red
#       (hold) | 5 merge rejected | 6 --admin not allowed | 7 not ready | 8 accepted but queued
#       on GitHub (merge queue or auto-merge): not merged yet, do not merge again
#       | 9 outcome unknown (the PR could not be read back): run again later to reconcile
# Appends one line per attempt to <state dir>/merges.log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" pr="" head="" method=squash admin=no evidence="" main_fix=no
authors=() excepts=() ignores=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --author) authors+=("$2"); shift 2 ;;
    --method) method=$2; shift 2 ;;
    --admin) admin=yes; shift ;;
    --evidence) evidence=$2; shift 2 ;;
    --except-check) excepts+=("$2"); shift 2 ;;
    --ignore-check) ignores+=("$2"); shift 2 ;;
    --main-fix) main_fix=yes; shift ;;
    -h | --help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "pr-merge.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$pr" && ${#head} -ge 7 ]] || { sed -n '2,34p' "$0" >&2; exit 2; }
case "$method" in squash | merge | rebase) ;; *) echo "pr-merge.sh: bad --method $method" >&2; exit 2 ;; esac
repo=$(orch_repo "$repo")
((${#authors[@]})) || authors=("$(orch_author)")
state=$(orch_state_dir "$repo")
log() { printf '%s\tpr=%s\thead=%s\t%s\n' "$(orch_iso "$(orch_now)")" "$pr" "${head:0:9}" "$*" >>"$state/merges.log"; }

journal="$state/ops/merge-pr$pr.json"
# An unfinished earlier attempt is reconciled before anything else: never merge twice.
if [[ -f "$journal" ]] && [[ "$(jq -r .state "$journal" 2>/dev/null)" =~ ^(intent|unknown|queued)$ ]]; then
  jfull=$(jq -r .head "$journal")
  now=$(orch_read_retry 3 gh pr view "$pr" --repo "$repo" --json state,mergeCommit,headRefOid,autoMergeRequest) ||
    { echo "unverified: an earlier merge attempt of PR $pr is unreconciled and the PR is unreadable"; exit 9; }
  case "$(jq -r .state <<<"$now")" in
    MERGED)
      orch_journal "$journal" "$(jq -c --arg at "$(orch_iso "$(orch_now)")" '.state = "merged" | .reconciled_at = $at' "$journal")"
      printf '%s\tpr=%s\thead=%s\t%s\n' "$(orch_iso "$(orch_now)")" "$pr" "$jfull" \
        "merged $(jq -r '.mergeCommit.oid // "-"' <<<"$now") (reconciled earlier attempt $(jq -r .attempt "$journal"))" >>"$state/merges.log"
      echo "merged $pr $(jq -r '.mergeCommit.oid // "-"' <<<"$now") (earlier attempt)"
      exit 0 ;;
    OPEN)
      if [[ "$(jq -r '.autoMergeRequest != null' <<<"$now")" == true ]]; then
        echo "queued: PR $pr is queued to merge on GitHub (earlier attempt); not merging again"; exit 8
      fi
      orch_journal "$journal" "$(jq -c '.state = "superseded"' "$journal")" ;;
    *) orch_journal "$journal" "$(jq -c '.state = "superseded"' "$journal")" ;;
  esac
fi

if [[ -f "$state/MAIN_RED" && "$main_fix" == no ]]; then
  echo "hold: default branch is red ($(head -1 "$state/MAIN_RED"))"; exit 4
fi

if [[ "$admin" == yes ]]; then
  [[ -n "$evidence" ]] || { echo "refused: --admin needs --evidence"; exit 6; }
  ((${#excepts[@]})) || { echo "refused: --admin needs --except-check for each check it bypasses"; exit 6; }
  if [[ "${ORCHESTRATE_ADMIN_MERGE:-0}" != 1 ]]; then
    over=${ORCHESTRATE_FAST_PATH_OVER:-20}
    open=$(gh pr list --repo "$repo" --state open --limit 300 --json number | jq length)
    if ((open <= over)); then
      echo "refused: --admin is fast-path only ($open open PRs, threshold >$over)"; exit 6
    fi
  fi
fi

info=$(orch_read_retry 3 gh pr view "$pr" --repo "$repo" --json state,isDraft,isCrossRepository,headRefOid,author,mergeable) ||
  { echo "unverified: PR $pr could not be read; nothing was attempted"; exit 9; }
ok=$(jq -r --arg head "$head" --args '
  .state == "OPEN" and (.isDraft | not) and (.isCrossRepository | not)
  and (.headRefOid | startswith($head)) and (.mergeable != "CONFLICTING")
  and (.author.login as $a | $ARGS.positional | index($a) != null)' "${authors[@]}" <<<"$info")
if [[ "$ok" != true ]]; then
  echo "ineligible: $(jq -c '{state,isDraft,isCrossRepository,head:.headRefOid[0:9],author:.author.login,mergeable}' <<<"$info")"
  log "refused ineligible"
  exit 3
fi

full=$(jq -r .headRefOid <<<"$info")

if [[ "$admin" == yes || "${ORCHESTRATE_DIRECT_MERGE:-0}" != 1 ]]; then
  # A fresh readiness row for this exact head. The admin exception covers the named checks only;
  # every other dimension must be clear.
  flags=(--repo "$repo" --pr "$pr")
  for a in "${authors[@]}"; do flags+=(--author "$a"); done
  for c in ${ignores[@]+"${ignores[@]}"}; do flags+=(--ignore-check "$c"); done
  row=$("$here/pr-ready.sh" "${flags[@]}" 2>/dev/null | head -1) || row=""
  IFS=$'\t' read -r _ verdict rhead _ _ detail <<<"$row"
  why=""
  if [[ -z "$row" ]]; then why=" no readiness row for PR $pr"
  elif [[ "$full" != "$rhead"* ]]; then why=" readiness row is for head $rhead, not ${full:0:9}"
  elif [[ "$admin" == no ]]; then
    if [[ "$verdict" != READY ]]; then
      log "refused not ready: $verdict $detail"
      echo "not ready: $verdict $detail"
      exit 7
    fi
  elif [[ "$verdict" == BLOCK ]]; then
    for token in $detail; do
      if [[ "$token" == fail:* ]]; then
        IFS=, read -r -a failed <<<"${token#fail:}"
        for f in "${failed[@]}"; do
          printf '%s\n' "${excepts[@]}" | grep -qxF -- "$f" || why+=" fail:$f (not excepted)"
        done
      else
        why+=" $token"
      fi
    done
  elif [[ "$verdict" != READY ]]; then why=" $verdict ${detail}"
  fi
  if [[ -n "$why" && "$admin" == no ]]; then
    log "refused:$why"
    echo "refused:$why"
    exit 7
  fi
  if [[ -n "$why" ]]; then
    log "refused admin: blockers beyond the excepted checks:$why"
    echo "refused: --admin covers only ${excepts[*]}; other blockers:$why"
    exit 6
  fi
fi
log() { printf '%s\tpr=%s\thead=%s\t%s\n' "$(orch_iso "$(orch_now)")" "$pr" "$full" "$*" >>"$state/merges.log"; }
args=("--$method" --match-head-commit "$full")
[[ "$admin" == yes ]] && args+=(--admin)
attempt="$(orch_now)-$$"
orch_journal "$journal" "$(jq -cn --arg repo "$repo" --argjson pr "$pr" --arg head "$full" --arg attempt "$attempt" \
  --arg at "$(orch_iso "$(orch_now)")" --arg method "$method" --arg admin "$admin" \
  '{op: "merge", repo: $repo, pr: $pr, head: $head, attempt: $attempt, method: $method, admin: $admin,
    state: "intent", started_at: $at}')"
jset() { orch_journal "$journal" "$(jq -c --arg s "$1" --arg d "${2:-}" '.state = $s | .detail = $d' "$journal")"; }
diag="$state/ops/merge-pr$pr-$attempt.out"
rc=0
gh pr merge "$pr" --repo "$repo" "${args[@]}" >"$diag" 2>&1 || rc=$?
out=$(tail -1 "$diag")

# Reconcile: bounded reads of the PR, never a second mutation.
if ! after=$(orch_read_retry 3 gh pr view "$pr" --repo "$repo" --json state,mergeCommit,headRefOid,autoMergeRequest); then
  jset unknown "merge exit $rc; readback failed"
  log "unverified: merge exit $rc, readback failed; attempt $attempt; output in $diag"
  echo "unverified: the merge of PR $pr may or may not have happened (exit $rc, readback failed); run again to reconcile"
  exit 9
fi
final=$(jq -r '"\(.state) \(.mergeCommit.oid // "-")"' <<<"$after")
if [[ "$final" == MERGED* ]]; then
  jset merged "${final#MERGED }"
  log "merged ${final#MERGED } method=$method admin=$admin${evidence:+ evidence=$evidence}"
  echo "merged $pr ${final#MERGED }"
elif [[ "$(jq -r '.headRefOid // ""' <<<"$after")" != "$full" ]]; then
  now=$(jq -r '.headRefOid // "-"' <<<"$after")
  jset rejected "head moved to $now"
  log "refused head moved during merge to ${now:0:9}: $out"
  echo "head moved during merge: judged ${full:0:9}, now ${now:0:9}; re-judge it"
  exit 3
elif [[ "$final" == OPEN* ]] && { [[ "$(jq -r '.autoMergeRequest != null' <<<"$after")" == true ]] ||
  { ((rc == 0)) && grep -qiE 'queue|auto-?merge|will be (automatically )?merged' "$diag"; }; }; then
  jset queued "$out"
  log "queued on GitHub: $out"
  echo "queued: GitHub accepted the merge of PR $pr but has not merged it yet ($out); do not merge again"
  exit 8
else
  jset rejected "exit $rc: $out"
  log "failed: exit $rc: $out"
  echo "merge failed: $out"
  exit 5
fi
