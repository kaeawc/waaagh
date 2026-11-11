#!/usr/bin/env bash
# Bot-review gate: the owner's review policy, quota-outage detection for the review bot (Claude
# Code Review), the unreviewed-merges ledger, and one global request throttle. Doctrine:
# review-quota.md.
#
# Usage: review-gate.sh policy [off|review-at-head|reviewed-once|green-only] [--note TEXT]
#        review-gate.sh exempt --pr N --reason TEXT | exempt --list
#        review-gate.sh check --pr N [--head SHA]
#        review-gate.sh notice --author LOGIN [--pr N]          (comment body on stdin)
#        review-gate.sh scan --pr N
#        review-gate.sh outage [ask [--waiting N] [--force] | clear --bot ID]
#        review-gate.sh ledger [list|pending|requested --pr N | add --pr N --head SHA --note VIA]
#        review-gate.sh request --bot ID [--pr N [--priority high|normal]] [--dry-run]
#        review-gate.sh request --pr N [--priority high|normal] [--dry-run]
#   Every command takes [--repo OWNER/REPO]. The one review bot has the id "claude" (the only
#   --bot value): Claude Code Review, which posts as ORCHESTRATE_REVIEW_BOT_LOGIN (default
#   claude[bot]) and is asked with the top-level comment ORCHESTRATE_REVIEW_TRIGGER (default
#   "@claude review": one review, no subscription to later pushes; set it empty to never post and
#   only wait for automatic reviews). Its check run is ORCHESTRATE_REVIEW_CHECK (default "Claude
#   Code Review"); ORCHESTRATE_REVIEW_QUOTA_RE overrides the quota-notice pattern.
#   policy   print the review policy (default off), or set it and log the change to decisions.log.
#            off: no review gate | review-at-head: a completed bot review on the current head |
#            reviewed-once: a completed bot review on any head | green-only: no review needed.
#   exempt   green checks only for ONE PR (an owner call); the merge is still ledgered.
#   check    read-only verdict: "ok reviewed <why>", "ok unreviewed <why>" (merge, then ledger it)
#            or "wait <why>" (exit 3). A review counts when the bot submitted it (not pending) and
#            it is not a quota notice. Without one at the head, the bot's completed check run on
#            the head counts too (a clean review may post a note and no PR review), unless its
#            title says the review was skipped, declined, not repeated, failed or timed out; an
#            unreadable check run counts for nothing.
#            A fresh gh-snapshot.sh row for the PR (pr-snapshot/<head>.json, written in the last
#            ORCHESTRATE_SNAPSHOT_TTL seconds, default 300; with --head, for exactly that head)
#            stands in for the head read, and for the reviews read when it shows no review at all;
#            otherwise check reads them itself.
#   notice   classify one PR comment: "quota <id> new|known" (a quota notice; the outage flag is
#            set, or its last-seen time moved), "bot <id>" or "other". A quota notice needs no
#            orchestrator turn; "new" means ask the owner once: `outage ask`.
#   scan     read a PR's comments and reviews: record quota notices ("quota <id> ...") and clear a
#            bot whose completed review is newer than its last notice ("recovered <id>").
#   outage   print the out-of-quota flags; `ask` prints the owner's policy ladder as one question
#            (once per outage; --force prints it again); `clear` ends a bot's outage and names the
#            ledgered merges that now need a retroactive review.
#   ledger   unreviewed merges (TSV: time pr head via status); `pending` lists those whose review
#            was not requested yet; `requested` marks one requested; `add` (pr-merge.sh) records a
#            merge made without a review and consumes the PR's exemption.
#   request  queue a review request for PR N, then post the queue's next request (high priority
#            first, then oldest) when the bot's window is open: one request every
#            ORCHESTRATE_REVIEW_EVERY seconds (default 1200) across all PRs, and while the bot is
#            out of quota one probe every ORCHESTRATE_REVIEW_PROBE_EVERY (default 3600).
#            Prints "requested <id> pr=<n>", "throttled <id> next=<iso> queued=<n>" or "empty <id>".
#            Without --bot (merge-queue.sh on exit 13): an out-of-quota bot is never asked, so
#            "out-of-quota <id> pr=<n>" and nothing is queued. With an empty trigger nothing is
#            posted or queued: "not-requested <id> pr=<n> ..." (wait for an automatic review).
# State (<state dir>): review-policy, review-exempt.tsv, reviewer-out-of-quota.tsv,
#   unreviewed-merges.tsv, review-queue/<id>.tsv and <id>.last, review-requests.log; pr-snapshot/ read.
# Exit: 0 ok | 2 usage | 3 check: a review is still needed | 4 a read failed | 5 a write failed
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  -h | --help) orch_usage; exit 0 ;;
  -*) echo "review-gate.sh: unknown argument: $cmd" >&2; exit 2 ;;
esac
if [[ -n "$cmd" ]]; then shift; fi
sub="" repo="" pr="" head="" note="" reason="" author="" bot="" priority=normal waiting="" force=no dry=no list=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --head) head=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --author) author=$2; shift 2 ;;
    --bot) bot=$2; shift 2 ;;
    --priority) priority=$2; shift 2 ;;
    --waiting) waiting=$2; shift 2 ;;
    --force) force=yes; shift ;;
    --dry-run) dry=yes; shift ;;
    --list) list=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    -*) echo "review-gate.sh: unknown argument: $1" >&2; exit 2 ;;
    *) [[ -z "$sub" ]] || { echo "review-gate.sh: unexpected argument: $1" >&2; exit 2; }; sub=$1; shift ;;
  esac
done
[[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || usage
case "$priority" in high | normal) ;; *) usage ;; esac

# The one review bot: Claude Code Review (code.claude.com/docs/en/code-review). Its id names the
# state files (review-queue/claude.tsv, the outage flag); the login, trigger and check run name
# are overridable defaults.
bid=claude
blogin=${ORCHESTRATE_REVIEW_BOT_LOGIN:-claude[bot]}
blogin=${blogin%\[bot\]}
trigger=${ORCHESTRATE_REVIEW_TRIGGER-@claude review}
check_name=${ORCHESTRATE_REVIEW_CHECK-Claude Code Review}
# LOGIN (with or without "[bot]") -> bot id, or nothing.
bot_of() { [[ "${1%\[bot\]}" == "$blogin" ]] && echo "$bid"; return 0; }
# Claude Code Review's "⚠️ Code review skipped" budget comments ("has reached its monthly code
# review spending cap", "has no extra usage available to pay for this review", "is too low to
# start another review") and a "Code review declined" note; case-insensitive.
quota_re=${ORCHESTRATE_REVIEW_QUOTA_RE:-spending cap|no extra usage|too low to start another review|code review declined}

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
now=$(orch_now)
iso=$(orch_iso "$now")
flags="$state/reviewer-out-of-quota.tsv"
ledger="$state/unreviewed-merges.tsv"
exempts="$state/review-exempt.tsv"
qdir="$state/review-queue"

read_policy() {
  local p=off
  [[ -f "$state/review-policy" ]] && p=$(awk 'NR == 1 { print $1 }' "$state/review-policy")
  echo "${p:-off}"
}

# rewrite FILE AWK-PROGRAM [awk -v args...]: filter a TSV in place (temp file + mv).
rewrite() {
  local f=$1 prog=$2
  shift 2
  [[ -f "$f" ]] || return 0
  awk -F'\t' -v OFS='\t' "$@" "$prog" "$f" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

# record_quota BOT: set or touch the outage flag; prints new|known.
record_quota() {
  if [[ -f "$flags" ]] && awk -F'\t' -v b="$1" '$1 == b { f = 1 } END { exit !f }' "$flags"; then
    rewrite "$flags" '$1 == b { $3 = t } { print }' -v b="$1" -v t="$iso"
    echo known
  else
    printf '%s\t%s\t%s\tno\n' "$1" "$iso" "$iso" >>"$flags"
    echo new
  fi
}

cmd_policy() {
  if [[ -z "$sub" ]]; then read_policy; return 0; fi
  case "$sub" in off | review-at-head | reviewed-once | green-only) ;; *) usage ;; esac
  local old
  old=$(read_policy)
  printf '%s\n' "$sub" >"$state/review-policy"
  printf '%s\treview-policy\t%s -> %s\t%s\n' "$iso" "$old" "$sub" "${note:--}" >>"$state/decisions.log"
  echo "review policy: $sub (was $old)"
}

cmd_exempt() {
  if [[ "$list" == yes ]]; then [[ -f "$exempts" ]] && cat "$exempts"; return 0; fi
  [[ -n "$pr" && -n "$reason" ]] || usage
  rewrite "$exempts" '$1 != p' -v p="$pr"
  printf '%s\t%s\t%s\n' "$pr" "$iso" "$reason" >>"$exempts"
  printf '%s\treview-exempt\tpr=%s\t%s\n' "$iso" "$pr" "$reason" >>"$state/decisions.log"
  echo "exempt: PR $pr merges on green checks without a review (ledgered)"
}

# fetch_reviews / fetch_comments: one JSON array each (every page).
fetch_reviews() {
  orch_read_retry 3 gh api "repos/$repo/pulls/$pr/reviews?per_page=100" --paginate | jq -cs 'add // []'
}
fetch_comments() {
  orch_read_retry 3 gh api "repos/$repo/issues/$pr/comments?per_page=100" --paginate | jq -cs 'add // []'
}

# snapshot_row: the PR's gh-snapshot.sh row when it is fresh (written in the last
# ORCHESTRATE_SNAPSHOT_TTL seconds) and, with --head, for exactly that head; nothing otherwise.
snapshot_row() {
  local dir="$state/pr-snapshot" f="" t ttl=${ORCHESTRATE_SNAPSHOT_TTL:-300}
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=300
  [[ -d "$dir" ]] || return 0
  if [[ -n "$head" ]]; then
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] && f="$dir/$head.json"
  else
    f=$(grep -l "\"number\":${pr}[,}]" "$dir"/*.json 2>/dev/null | sed -n '1p') || f=""
  fi
  [[ -n "$f" && -f "$f" ]] || return 0
  t=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 0
  [[ "$t" =~ ^[0-9]+$ ]] && ((now - t <= ttl)) || return 0
  jq -ce --argjson n "$pr" 'select(.number == $n and (.head | type == "string") and (.review | type == "string"))' "$f" 2>/dev/null || true
}

# check_run_verdict: "head" when the bot's newest check run on $head completed a review, "earlier"
# when it kept an earlier review's result (skipped: no new changes, or not repeated), nothing
# otherwise (queued, in progress, declined, failed, timed out, cancelled, or unreadable).
check_run_verdict() {
  local runs enc
  enc=$(jq -rn --arg n "$check_name" '$n | @uri')
  runs=$(orch_read_retry 2 gh api "repos/$repo/commits/$head/check-runs?check_name=$enc&per_page=100") || return 0
  jq -r --arg n "$check_name" '
    [(.check_runs // [])[] | select(.name == $n and .status == "completed")] | sort_by(.completed_at // "") | last
    | if . == null then empty
      else (.output.title // "" | ascii_downcase) as $t
      | if ($t | test("no new changes|not repeated")) then "earlier"
        elif .conclusion == "neutral" or .conclusion == "success" then
          (if ($t | test("skipped|declined|failed|timed out|cancel")) then empty else "head" end)
        else empty end
      end' <<<"$runs" 2>/dev/null || true
}

cmd_check() {
  [[ -n "$pr" ]] || usage
  local policy reviews verdict snap
  policy=$(read_policy)
  if [[ -f "$exempts" ]] && awk -F'\t' -v p="$pr" '$1 == p { f = 1 } END { exit !f }' "$exempts"; then
    echo "ok unreviewed exempt"; return 0
  fi
  case "$policy" in
    off) echo "ok unreviewed policy=off"; return 0 ;;
    green-only) ;;
    review-at-head | reviewed-once) ;;
    *) echo "review-gate.sh: unknown policy '$policy' in $state/review-policy" >&2; exit 2 ;;
  esac
  snap=$(snapshot_row)
  [[ -z "$snap" || -n "$head" ]] || head=$(jq -r .head <<<"$snap")
  if [[ -z "$head" ]]; then
    head=$(orch_read_retry 3 gh pr view "$pr" --repo "$repo" --json headRefOid | jq -r .headRefOid) ||
      { echo "unverified: PR $pr could not be read"; exit 4; }
  fi
  if [[ -n "$snap" && "$(jq -r .review <<<"$snap")" == NONE ]]; then
    reviews='[]'
  else
    reviews=$(fetch_reviews) || { echo "unverified: reviews of PR $pr could not be read"; exit 4; }
  fi
  # Reviews travel as a file, not an argument: one argument is capped at 128 KiB (#121).
  verdict=$(jq -rn --slurpfile r <(printf '%s\n' "$reviews") --arg login "$blogin" --arg head "$head" --arg re "$quota_re" '
    def bot: (.user.login // "" | sub("\\[bot\\]$"; "")) == $login;
    def quota: (.body // "") | test($re; "i");
    $r[0] as $r |
    ([$r[] | select(bot and .state != "PENDING" and (quota | not))]) as $rev
    | if any($rev[]; .commit_id == $head) then "head"
      elif ($rev | length) > 0 then "earlier"
      else "never" end')
  # No review at the head: the bot's completed check run there is a review (a clean one may post
  # a note and no PR review); one that kept an earlier result counts as an earlier review.
  if [[ "$verdict" != head && -n "$check_name" ]]; then
    case "$(check_run_verdict)" in
      head) verdict="head" ;;
      earlier) [[ "$verdict" == never ]] && verdict=earlier ;;
    esac
  fi
  case "$policy:$verdict" in
    *:head) echo "ok reviewed at-head" ;;
    reviewed-once:earlier) echo "ok reviewed earlier-head (reviewed-once)" ;;
    green-only:*) echo "ok unreviewed green-only ($verdict)" ;;
    review-at-head:earlier) echo "wait no-review-at-head"; exit 3 ;;
    *:never) echo "wait never-reviewed"; exit 3 ;;
  esac
}

cmd_notice() {
  [[ -n "$author" ]] || usage
  local b body
  b=$(bot_of "$author")
  body=$(cat)
  if [[ -z "$b" ]]; then echo other; return 0; fi
  if grep -qiE "$quota_re" <<<"$body"; then
    echo "quota $b $(record_quota "$b")${pr:+ pr=$pr}"
  else
    echo "bot $b"
  fi
}

cmd_scan() {
  [[ -n "$pr" ]] || usage
  local reviews comments events line last
  reviews=$(fetch_reviews) || { echo "unverified: reviews of PR $pr could not be read"; exit 4; }
  comments=$(fetch_comments) || { echo "unverified: comments of PR $pr could not be read"; exit 4; }
  # One row per bot item, oldest first: login  kind(quota|review)  time.
  events=$(jq -rn --slurpfile r <(printf '%s\n' "$reviews") --slurpfile c <(printf '%s\n' "$comments") --arg re "$quota_re" '
    $r[0] as $r | $c[0] as $c |
    ([$r[] | select(.state != "PENDING") | {l: .user.login, t: .submitted_at, b: .body}]
     + [$c[] | {l: .user.login, t: .created_at, b: .body}])
    | map(select(.l != null and .t != null)) | sort_by(.t)[]
    | [.l, (if (.b // "") | test($re; "i") then "quota" else "review" end), .t] | @tsv')
  line=$(awk -F'\t' -v OFS='\t' -v l="$blogin" '{ sub(/\[bot\]$/, "", $1) } $1 == l' <<<"$events")
  [[ -n "$line" ]] || return 0
  last=$(awk -F'\t' '$2 == "quota" { t = $3 } END { print t }' <<<"$line")
  [[ -n "$last" ]] || return 0
  if awk -F'\t' -v t="$last" '$2 == "review" && $3 > t { f = 1 } END { exit !f }' <<<"$line"; then
    if out_of_quota "$bid"; then
      rewrite "$flags" '$1 != b' -v b="$bid"
      echo "recovered $bid pr=$pr"
    fi
  else
    echo "quota $bid $(record_quota "$bid") pr=$pr"
  fi
}

cmd_outage() {
  case "$sub" in
    "")
      if [[ -s "$flags" ]]; then
        awk -F'\t' '{ printf "out-of-quota %s since=%s last=%s asked=%s\n", $1, $2, $3, $4 }' "$flags"
      else
        echo "no reviewer out of quota"
      fi ;;
    ask)
      [[ -s "$flags" ]] || { echo "no reviewer out of quota"; return 0; }
      if [[ "$force" == no ]] && ! awk -F'\t' '$4 != "yes" { f = 1 } END { exit !f }' "$flags"; then
        echo "already asked"; return 0
      fi
      local who policy
      who=$(awk -F'\t' '{ printf "%s%s (since %s)", (NR > 1 ? ", " : ""), $1, $2 }' "$flags")
      policy=$(read_policy)
      printf 'Bot reviews are out of quota: %s.%s Review policy is %s. How should merging go until reviews are back?\n' \
        "$who" "${waiting:+ $waiting PRs with green checks are waiting for a review.}" "$policy"
      cat <<'Q'
1. Green checks only for one urgent PR (name it): review-gate.sh exempt --pr N --reason "..."
2. Green checks only for all PRs until reviews return (policy green-only): each such merge is
   logged in the unreviewed-merges ledger and gets a review requested when reviews are back;
   findings become follow-up issues
3. Reviewed once is enough (policy reviewed-once): a PR with a completed bot review on an earlier
   head merges on green checks; never-reviewed PRs still wait for one review
4. Keep waiting for reviews: requests stay throttled to one per window across all PRs,
   gating PRs first
Q
      rewrite "$flags" '{ $4 = "yes"; print }' ;;
    clear)
      [[ -n "$bot" ]] || usage
      rewrite "$flags" '$1 != b' -v b="$bot"
      local n=0
      [[ -f "$ledger" ]] && n=$(awk -F'\t' '$5 == "pending"' "$ledger" | wc -l | tr -d ' ')
      echo "cleared $bot; unreviewed merges awaiting a retroactive review: $n (review-gate.sh ledger pending)" ;;
    *) usage ;;
  esac
}

cmd_ledger() {
  case "$sub" in
    "" | list) [[ -f "$ledger" ]] && cat "$ledger"; return 0 ;;
    pending) [[ -f "$ledger" ]] && awk -F'\t' '$5 == "pending"' "$ledger"; return 0 ;;
    requested)
      [[ -n "$pr" ]] || usage
      rewrite "$ledger" '$2 == p && $5 == "pending" { $5 = "requested" } { print }' -v p="$pr"
      echo "ledger: PR $pr review requested" ;;
    add)
      # Internal: pr-merge.sh adds a merge made without a review (--head FULL --note VIA).
      [[ -n "$pr" && -n "$head" ]] || usage
      printf '%s\t%s\t%s\t%s\tpending\n' "$iso" "$pr" "$head" "${note:-unreviewed}" >>"$ledger"
      rewrite "$exempts" '$1 != p' -v p="$pr" ;;
    *) usage ;;
  esac
}

out_of_quota() { [[ -f "$flags" ]] && awk -F'\t' -v b="$1" '$1 == b { f = 1 } END { exit !f }' "$flags"; }

cmd_request() {
  if [[ -z "$bot" ]]; then
    [[ -n "$pr" ]] || usage
    out_of_quota "$bid" && { echo "out-of-quota $bid pr=$pr"; return 0; }
    bot=$bid
  fi
  [[ "$bot" == "$bid" ]] || { echo "review-gate.sh: unknown bot id '$bot' (the review bot is '$bid')" >&2; exit 2; }
  if [[ -z "$trigger" ]]; then
    echo "not-requested $bid${pr:+ pr=$pr} (ORCHESTRATE_REVIEW_TRIGGER is empty: waiting for an automatic review)"
    return 0
  fi
  mkdir -p "$qdir"
  local q="$qdir/$bot.tsv" last=0 every next top tpr n rc=0
  if [[ -n "$pr" ]]; then
    rewrite "$q" '$1 != p' -v p="$pr"
    printf '%s\t%s\t%s\n' "$pr" "$priority" "$now" >>"$q"
  fi
  if [[ ! -s "$q" ]]; then echo "empty $bot"; return 0; fi
  [[ -f "$qdir/$bot.last" ]] && last=$(cat "$qdir/$bot.last")
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  every=${ORCHESTRATE_REVIEW_EVERY:-1200}
  if out_of_quota "$bot"; then
    every=${ORCHESTRATE_REVIEW_PROBE_EVERY:-3600}
  fi
  n=$(wc -l <"$q" | tr -d ' ')
  next=$((last + every))
  if ((now < next)); then
    echo "throttled $bot next=$(orch_iso "$next") queued=$n"; return 0
  fi
  top=$(awk -F'\t' '{ print ($2 == "high" ? 0 : 1) "\t" $3 "\t" $1 }' "$q" | sort -t$'\t' -k1,1n -k2,2n | awk -F'\t' 'NR == 1 { print $3 }')
  tpr=$top
  if [[ "$dry" == yes ]]; then echo "would request $bot pr=$tpr ($trigger)"; return 0; fi
  gh pr comment "$tpr" --repo "$repo" --body "$trigger" >/dev/null 2>&1 || rc=$?
  if ((rc)); then
    printf '%s\t%s\tpr=%s\tfailed exit=%s\n' "$iso" "$bot" "$tpr" "$rc" >>"$state/review-requests.log"
    echo "request to $bot on PR $tpr failed (exit $rc); still queued"; exit 5
  fi
  printf '%s\n' "$now" >"$qdir/$bot.last"
  rewrite "$q" '$1 != p' -v p="$tpr"
  printf '%s\t%s\tpr=%s\trequested\n' "$iso" "$bot" "$tpr" >>"$state/review-requests.log"
  echo "requested $bot pr=$tpr queued=$((n - 1))"
}

case "$cmd" in
  policy) cmd_policy ;;
  exempt) cmd_exempt ;;
  check) cmd_check ;;
  notice) cmd_notice ;;
  scan) cmd_scan ;;
  outage) cmd_outage ;;
  ledger) cmd_ledger ;;
  request) cmd_request ;;
  *) usage ;;
esac
