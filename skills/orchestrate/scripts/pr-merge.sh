#!/usr/bin/env bash
# Merge ONE pull request after re-checking, at merge time, that it is still the PR that was judged
# ready. Never merges a draft, a fork-head PR, a PR by an unlisted author, or a moved head.
#
# Usage: pr-merge.sh --pr N --head SHA [--repo OWNER/REPO] [--author LOGIN]...
#                    [--method squash|merge|rebase] [--main-fix]
#                    [--admin --except-check NAME... --evidence TEXT] [--ignore-check NAME]...
#                    [--worktree DIR --merge-check CMD]
#   --head      the head SHA (any prefix >= 7) that pr-ready.sh judged; a moved head refuses
#   --admin     bypass branch protection. Allowed only in the fast path: more open PRs than
#               ORCHESTRATE_FAST_PATH_OVER (default 20), or ORCHESTRATE_ADMIN_MERGE=1 when the
#               user authorized it. Needs --evidence naming the classified flake or pending
#               advisory check being bypassed; it is written to the merge log. The exception is
#               only for the checks named by --except-check: a fresh pr-ready.sh row for this PR
#               must show no blocker other than failures of exactly those checks (no review
#               thread, unknown thread or policy read, conflict, pending check, missing required
#               check), or the merge is refused with exit 6.
#   --ignore-check  advisory checks, passed to pr-ready.sh for that row. If one of them is failing
#               on the head, --evidence is required too (and logged), as in direct mode.
# Without --admin the same fresh row must be READY for this exact head, or the merge is refused
# with exit 7 (the row's verdict and reasons are printed), so the merge never depends on the
# server's branch protection. Ungated merging is a deliberate mode: ORCHESTRATE_DIRECT_MERGE=1,
# set only on the user's word, skips this readiness gate (not the identity, head or hold checks).
#   --main-fix  this PR fixes a red default branch; merge although MAIN_RED is set
# Merge-sensitive paths (merge-sensitive.sh; none configured: no reads, no effect): a PR touching
# one takes a per-pattern lock in <state dir>/locks/ for the merge, so merges over the same path are
# serialized (another PR holding it: exit 12; a lock older than ORCHESTRATE_SENSITIVE_LOCK_TTL,
# default 900 s, is taken over). Then its head must contain the current base branch, or the
# merge-result check must pass (`--worktree DIR --merge-check CMD`: CMD runs on the base merged with
# the head in a temporary worktree of DIR); otherwise it is refused with exit 11 (merge the base in
# and wait for a green run). After exit 8, 9 or 10 the lock is kept, so a merge still in flight on
# GitHub keeps other PRs over that path waiting; a rerun for the same PR takes it back.
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
#       | 10 pending on GitHub: the merge got a 5xx or "merge already in progress" and the PR is
#       still OPEN after the waits (`pending:`), or Pull Requests is in an outage (`outage:`);
#       not merged, not failed: do not merge by other means, run again later to reconcile
#       | 11 stale: touches a merge-sensitive path and the base moved past the head
#       | 12 busy: another PR's merge holds the lock of a merge-sensitive path it touches
#       | 13 needs review: the owner's bot-review policy (review-gate.sh check) is not met
#       | 14 held: the PR is in the hold file (hold.sh); only `hold.sh release` (or check
#       --release) clears it. Also every PR while a release freeze is on (freeze.sh; `freeze.sh
#       end` lifts it). Checked before the gates and again right before the merge.
#       Also when the PR's latest internal review verdict (review-ledger.sh) is not ship
#       (`held: ... latest internal review`); only a newer ship verdict clears that. A ship
#       recorded --head R holds a PR whose head moved past R, unless every commit after R that is
#       not on the base is a GitHub-made update-branch merge (orch_review_covers in _lib.sh, #210;
#       local git in ORCHESTRATE_GIT_DIR, default the current directory)
# Holds: a PR in <state dir>/holds, or whose latest review-ledger.sh verdict is fix-first, rethink,
# fixing, repairing or repaired (#212), is never merged, in any mode (--admin, --main-fix and
# ORCHESTRATE_DIRECT_MERGE included); a hold file or review ledger that cannot be read refuses
# with exit 9.
# Review policy: when <state dir>/review-policy is set and not off, review-gate.sh check must say
# ok for the head; a merge it allowed without a review is added to the unreviewed-merges ledger.
# GitHub outages: success is read from the PR state, never from the merge's exit code. A 5xx or
# "merge already in progress" is pending, not success or failure: githubstatus.com is read
# (gh-status.sh) and its non-operational components logged; then the PR state is re-read after
# waits of 60 s, 120 s, ... (ORCHESTRATE_MERGE_TRIES rounds, default 3; ORCHESTRATE_MERGE_BACKOFF
# never below 60). Only a 5xx is re-sent (still bound to the head); "already in progress" is only
# re-read. While Pull Requests is down it stops at once and writes <state dir>/GITHUB_OUTAGE; while
# that file exists every run re-reads the status first and pauses (exit 10, nothing attempted or
# logged) until Pull Requests is operational again.
# Appends one line per attempt to <state dir>/merges.log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority high

repo="" pr="" head="" method=squash admin=no evidence="" main_fix=no mwt="" mcheck=""
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
    --worktree) mwt=$2; shift 2 ;;
    --merge-check) mcheck=$2; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "pr-merge.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$pr" && ${#head} -ge 7 ]] || { orch_usage >&2; exit 2; }
[[ -z "$mwt" && -z "$mcheck" || -n "$mwt" && -n "$mcheck" ]] ||
  { echo "pr-merge.sh: --worktree and --merge-check go together" >&2; exit 2; }
case "$method" in squash | merge | rebase) ;; *) echo "pr-merge.sh: bad --method $method" >&2; exit 2 ;; esac
repo=$(orch_repo "$repo")
((${#authors[@]})) || authors=("$(orch_author)")
state=$(orch_state_dir "$repo")
log() { printf '%s\tpr=%s\thead=%s\t%s\n' "$(orch_iso "$(orch_now)")" "$pr" "${head:0:9}" "$*" >>"$state/merges.log"; }

# Merge-sensitive locks owned by this PR are released on exit, except while the merge may still be
# in flight on GitHub (8 queued, 9 unknown, 10 pending).
lockdir="$state/locks"
release_locks() {
  local d
  for d in "$lockdir"/sensitive-*; do
    [[ -d "$d" && "$(cat "$d/pr" 2>/dev/null)" == "$pr" ]] && rm -rf "$d"
  done
  return 0
}
on_exit() { case $? in 8 | 9 | 10) ;; *) release_locks ;; esac; }
trap on_exit EXIT

journal="$state/ops/merge-pr$pr.json"
# An unfinished earlier attempt is reconciled before anything else: never merge twice.
if [[ -f "$journal" ]] && [[ "$(jq -r .state "$journal" 2>/dev/null)" =~ ^(intent|unknown|queued|pending)$ ]]; then
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

# The hold file (hold.sh) wins over every mode: a held PR is never merged (#202).
refuse_if_held() {
  local hrc=0 hold
  hold=$(orch_hold_of "$repo" "$pr") || hrc=$?
  case "$hrc" in
    0) log "refused held: $hold"
      echo "held: PR $pr is in the hold file ($hold); $(orch_hold_hint "$hold")"; exit 14 ;;
    1) ;;
    *) release_locks; log "refused: hold file unreadable"
      echo "unverified: the hold file could not be read (hold.sh list); nothing was attempted"; exit 9 ;;
  esac
  # The latest internal review verdict is a gate too: fix-first (or any non-ship) holds (#206).
  # Once the full head is known, a ship verdict pinned to another head must cover it (#210).
  hrc=0
  hold=$(orch_review_hold_of "$repo" "$pr" "${full:-}" "${pbase:-}") || hrc=$?
  case "$hrc" in
    0) log "refused held: $hold"
      if [[ "$hold" == *" review:stale "* ]]; then
        echo "held: PR $pr's ship review is for another head ($hold); review this head and record it (review-ledger.sh record --head)"; exit 14
      fi
      echo "held: PR $pr's latest internal review is not ship ($hold); a newer ship verdict (review-ledger.sh record) clears it"; exit 14 ;;
    1) ;;
    *) release_locks; log "refused: review ledger unreadable"
      echo "unverified: the review ledger could not be read (review-ledger.sh latest); nothing was attempted"; exit 9 ;;
  esac
}
refuse_if_held

if [[ -f "$state/MAIN_RED" && "$main_fix" == no ]]; then
  echo "hold: default branch is red ($(head -1 "$state/MAIN_RED"))"; exit 4
fi

# Paused while GitHub's Pull Requests component is down: no attempt, no failure line per pass.
if [[ -f "$state/GITHUB_OUTAGE" ]]; then
  src=0
  st=$("$here/gh-status.sh") || src=$?
  if ((src == 4)); then
    echo "outage: merging paused since $(cut -f1 "$state/GITHUB_OUTAGE"); githubstatus: $st"; exit 10
  fi
  ((src != 0)) || rm -f "$state/GITHUB_OUTAGE"
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

info=$(orch_read_retry 3 gh pr view "$pr" --repo "$repo" --json state,isDraft,isCrossRepository,headRefOid,baseRefName,author,mergeable) ||
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
pbase=$(jq -r '.baseRefName // empty' <<<"$info")
refuse_if_held

if [[ "$admin" == yes || "${ORCHESTRATE_DIRECT_MERGE:-0}" != 1 ]]; then
  # A fresh readiness row for this exact head. The admin exception covers the named checks only;
  # every other dimension must be clear.
  flags=(--repo "$repo" --pr "$pr")
  for a in "${authors[@]}"; do flags+=(--author "$a"); done
  for c in ${ignores[@]+"${ignores[@]}"}; do flags+=(--ignore-check "$c"); done
  row=$("$here/pr-ready.sh" "${flags[@]}" 2>/dev/null | awk 'NR == 1') || row=""
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

# A check failing on this head may be bypassed (as advisory via --ignore-check, by --admin, or in
# direct mode) only with --evidence naming why; a lane calling it "infra" is not evidence.
if [[ -z "$evidence" ]] && { ((${#ignores[@]})) || [[ "${ORCHESTRATE_DIRECT_MERGE:-0}" == 1 ]]; }; then
  rflags=(--repo "$repo" --pr "$pr" --no-threads)
  for a in "${authors[@]}"; do rflags+=(--author "$a"); done
  raw=$("$here/pr-ready.sh" "${rflags[@]}" 2>/dev/null | awk 'NR == 1') || raw=""
  if [[ -z "$raw" ]]; then
    log "refused: check state unreadable and no --evidence"
    echo "refused: the head's checks could not be read; a merge past them needs --evidence"; exit 6
  fi
  failing=$(cut -f6 <<<"$raw" | tr ' ' '\n' | sed -n 's/^fail://p' | tr '\n' ',' | sed 's/,$//')
  if [[ -n "$failing" ]]; then
    log "refused: failing on the head without --evidence: $failing"
    echo "refused: $failing failing on this head; bypassing a failing check needs --evidence (the classifier verdict or flake entry)"
    exit 6
  fi
fi

# Bot-review policy (review-gate.sh; no review-policy file or policy off: no reads, no effect).
review=""
if [[ -f "$state/review-policy" && "$(awk 'NR == 1 { print $1 }' "$state/review-policy")" != off ]]; then
  src=0
  review=$("$here/review-gate.sh" check --repo "$repo" --pr "$pr" --head "$full") || src=$?
  case "$src" in
    0) ;;
    3) log "refused review: $review"; echo "needs review: $review (review-gate.sh policy)"; exit 13 ;;
    *) log "refused: review state unreadable: $review"; echo "unverified: review state of PR $pr unreadable; nothing was attempted"; exit 9 ;;
  esac
fi

# Merge-sensitive paths: lock each touched pattern, then require a head that contains the base or a
# passing merge-result check. Locks are taken before the check so no other merge moves the base
# over the same path between the check and this merge.
src=0
spats=$("$here/merge-sensitive.sh" paths --repo "$repo" --pr "$pr") || src=$?
if ((src)); then
  log "refused: $spats"; echo "$spats; nothing was attempted"; exit 9
fi
if [[ -n "$spats" ]]; then
  mkdir -p "$lockdir"
  ttl=${ORCHESTRATE_SENSITIVE_LOCK_TTL:-900}
  while IFS= read -r p; do
    d="$lockdir/sensitive-$(printf '%s' "$p" | cksum | cut -d' ' -f1)"
    if ! mkdir "$d" 2>/dev/null; then
      owner=$(cat "$d/pr" 2>/dev/null || true) at=$(cat "$d/at" 2>/dev/null || echo 0)
      [[ "$at" =~ ^[0-9]+$ ]] || at=0
      if [[ "$owner" != "$pr" ]] && (($(orch_now) - at < ttl)); then
        log "busy: PR ${owner:-?} holds the merge lock of sensitive path $p"
        echo "busy: PR ${owner:-?} is merging over merge-sensitive path $p (lock since $(orch_iso "$at")); try again after it"
        exit 12
      fi
      rm -rf "$d"
      mkdir "$d" 2>/dev/null || { echo "busy: lost the race for the lock of $p; try again"; exit 12; }
    fi
    printf '%s\n' "$pr" >"$d/pr"; printf '%s\n' "$p" >"$d/pattern"; orch_now >"$d/at"
  done <<<"$spats"
  cflags=(check --repo "$repo" --pr "$pr" --head "$full")
  [[ -z "$mcheck" ]] || cflags+=(--worktree "$mwt" --check-cmd "$mcheck")
  src=0
  sout=$("$here/merge-sensitive.sh" "${cflags[@]}") || src=$?
  case "$src" in
    0) log "sensitive $sout" ;;
    3) log "refused $sout"; echo "$sout"; exit 11 ;;
    *) release_locks; log "refused: $sout"; echo "$sout; nothing was attempted"; exit 9 ;;
  esac
fi

log() { printf '%s\tpr=%s\thead=%s\t%s\n' "$(orch_iso "$(orch_now)")" "$pr" "$full" "$*" >>"$state/merges.log"; }
# A hold set while the gates above ran (by hand, or when a fix pass starts) still stops the merge.
refuse_if_held
args=("--$method" --match-head-commit "$full")
[[ "$admin" == yes ]] && args+=(--admin)
attempt="$(orch_now)-$$"
orch_journal "$journal" "$(jq -cn --arg repo "$repo" --argjson pr "$pr" --arg head "$full" --arg attempt "$attempt" \
  --arg at "$(orch_iso "$(orch_now)")" --arg method "$method" --arg admin "$admin" \
  '{op: "merge", repo: $repo, pr: $pr, head: $head, attempt: $attempt, method: $method, admin: $admin,
    state: "intent", started_at: $at}')"
jset() { orch_journal "$journal" "$(jq -c --arg s "$1" --arg d "${2:-}" '.state = $s | .detail = $d' "$journal")"; }
diag="$state/ops/merge-pr$pr-$attempt.out"
# A 5xx, or GitHub saying the merge is already in progress: pending, never success or failure.
pending_kind() {
  if grep -qi 'merge already in progress' "$diag"; then echo in-progress
  elif grep -qiE 'HTTP 5[0-9][0-9]|bad gateway|service unavailable|gateway time-?out|internal server error' "$diag"; then
    echo 5xx
  fi
  return 0
}
tries=${ORCHESTRATE_MERGE_TRIES:-3} backoff=${ORCHESTRATE_MERGE_BACKOFF:-60} round=1 send=yes rc=0 out=""
((backoff >= 60)) || backoff=60
while :; do
  if [[ "$send" == yes ]]; then
    ((round == 1)) || diag="$state/ops/merge-pr$pr-$attempt-r$round.out"
    rc=0
    gh pr merge "$pr" --repo "$repo" "${args[@]}" >"$diag" 2>&1 || rc=$?
    out=$(tail -1 "$diag")
  fi
  # Reconcile: bounded reads of the PR; its state decides, never the merge's exit code.
  if ! after=$(orch_read_retry 3 gh pr view "$pr" --repo "$repo" --json state,mergeCommit,headRefOid,autoMergeRequest); then
    jset unknown "merge exit $rc; readback failed"
    log "unverified: merge exit $rc, readback failed; attempt $attempt; output in $diag"
    echo "unverified: the merge of PR $pr may or may not have happened (exit $rc, readback failed); run again to reconcile"
    exit 9
  fi
  final=$(jq -r '"\(.state) \(.mergeCommit.oid // "-")"' <<<"$after")
  # Only a still-OPEN PR at the judged head, not queued, can be pending.
  [[ "$final" == OPEN* && "$(jq -r '.headRefOid // ""' <<<"$after")" == "$full" &&
    "$(jq -r '.autoMergeRequest != null' <<<"$after")" != true ]] || break
  kind=$(pending_kind)
  [[ -n "$kind" ]] || break
  src=0
  st=$("$here/gh-status.sh") || src=$?
  log "pending: $kind (exit $rc: $out); githubstatus: $st"
  if ((src == 4)); then
    printf '%s\t%s\n' "$(orch_iso "$(orch_now)")" "$st" >"$state/GITHUB_OUTAGE"
    jset pending "$kind; outage: $st"
    echo "outage: GitHub reports $st; the merge of PR $pr is pending and merging is paused (do not merge again; a rerun reconciles)"
    exit 10
  fi
  if ((round >= tries)); then
    jset pending "$kind: $out"
    echo "pending: the merge of PR $pr got $kind ($out) and the PR is still OPEN after $round rounds; githubstatus: $st; a rerun reconciles"
    exit 10
  fi
  if [[ "${ORCHESTRATE_MERGE_FAKE_SLEEP:-0}" == 1 ]]; then echo "pr-merge: wait $backoff" >&2; else sleep "$backoff"; fi
  backoff=$((backoff * 2)) round=$((round + 1))
  if [[ "$kind" == 5xx ]]; then send=yes; else send=no; fi
done
if [[ "$final" == MERGED* ]]; then
  rm -f "$state/GITHUB_OUTAGE"
  jset merged "${final#MERGED }"
  log "merged ${final#MERGED } method=$method admin=$admin${evidence:+ evidence=$evidence}${review:+ review=$review}"
  if [[ "$review" == "ok unreviewed"* ]]; then
    "$here/review-gate.sh" ledger add --repo "$repo" --pr "$pr" --head "$full" --note "${review#ok unreviewed }" >/dev/null ||
      echo "warning: merged PR $pr without a review but the unreviewed-merges ledger write failed" >&2
  fi
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
