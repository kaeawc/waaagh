#!/usr/bin/env bash
# Bot-review gate: the owner's review policy, quota-outage detection for review bots, the
# unreviewed-merges ledger, and one global request throttle per bot. Doctrine: review-quota.md.
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
#   Every command takes [--repo OWNER/REPO]. Bot ids (ORCHESTRATE_REVIEW_BOTS, default
#   "codex coderabbit"): codex = chatgpt-codex-connector[bot], coderabbit = coderabbitai[bot].
#   policy   print the review policy (default off), or set it and log the change to decisions.log.
#            off: no review gate | review-at-head: a completed bot review on the current head |
#            reviewed-once: a completed bot review on any head | green-only: no review needed.
#   exempt   green checks only for ONE PR (an owner call); the merge is still ledgered.
#   check    read-only verdict: "ok reviewed <why>", "ok unreviewed <why>" (merge, then ledger it)
#            or "wait <why>" (exit 3). A review counts when a listed bot submitted it (not pending)
#            and it is not a quota notice; a bot comment "Reviewed commit: <sha>" counts for that sha.
#            A fresh gh-snapshot.sh row for the PR (pr-snapshot/<head>.json, written in the last
#            ORCHESTRATE_SNAPSHOT_TTL seconds, default 300; with --head, for exactly that head)
#            stands in for the head read, and for the reviews read when it shows no review at all;
#            otherwise check reads them itself. Comments are always read.
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
#            first, then oldest) when the bot's window is open: one request per bot every
#            ORCHESTRATE_REVIEW_EVERY seconds (default 1200) across all PRs, and while the bot is
#            out of quota one probe every ORCHESTRATE_REVIEW_PROBE_EVERY (default 3600).
#            Prints "requested <id> pr=<n>", "throttled <id> next=<iso> queued=<n>" or "empty <id>".
#            Without --bot: the first listed bot that is not out of quota (merge-queue.sh on exit 13);
#            an out-of-quota bot is never asked, and when all are out: "out-of-quota all pr=<n>".
# State (<state dir>): review-policy, review-exempt.tsv, reviewer-out-of-quota.tsv,
#   unreviewed-merges.tsv, review-queue/<id>.tsv and <id>.last, review-requests.log; pr-snapshot/ read.
# Exit: 0 ok | 2 usage | 3 check: a review is still needed | 4 a read failed | 5 a write failed
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
if declare -F orch_gh_priority >/dev/null; then orch_gh_priority normal; fi

usage() { sed -n '2,47p' "$0" >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  -h | --help) sed -n '2,47p' "$0"; exit 0 ;;
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
    -h | --help) sed -n '2,47p' "$0"; exit 0 ;;
    -*) echo "review-gate.sh: unknown argument: $1" >&2; exit 2 ;;
    *) [[ -z "$sub" ]] || { echo "review-gate.sh: unexpected argument: $1" >&2; exit 2; }; sub=$1; shift ;;
  esac
done
[[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || usage
case "$priority" in high | normal) ;; *) usage ;; esac

bots=${ORCHESTRATE_REVIEW_BOTS:-codex coderabbit}
bot_login() {
  case "$1" in
    codex) echo chatgpt-codex-connector ;;
    coderabbit) echo coderabbitai ;;
    *) return 1 ;;
  esac
}
bot_trigger() {
  case "$1" in codex) echo "@codex review" ;; coderabbit) echo "@coderabbitai review" ;; esac
}
# LOGIN (with or without "[bot]") -> bot id, or nothing.
bot_of() {
  local l=${1%\[bot\]} b
  for b in $bots; do [[ "$(bot_login "$b")" == "$l" ]] && { echo "$b"; return 0; }; done
  return 0
}
known_bot() { local b; for b in $bots; do [[ "$b" == "$1" ]] && return 0; done; return 1; }
logins_json() { local b; for b in $bots; do bot_login "$b"; done | jq -R . | jq -sc .; }
# Quota or rate-limit notices from review bots (Codex "usage limits", CodeRabbit "rate limited",
# "free review limit"), case-insensitive.
quota_re='usage limits?|rate[- ]?limit|review limits?|quota (exceeded|exhausted|reached)|out of (credits|quota)'

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

cmd_check() {
  [[ -n "$pr" ]] || usage
  local policy reviews comments verdict snap
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
  comments=$(fetch_comments) || { echo "unverified: comments of PR $pr could not be read"; exit 4; }
  verdict=$(jq -rn --argjson r "$reviews" --argjson c "$comments" --argjson bots "$(logins_json)" \
    --arg head "$head" --arg re "$quota_re" '
    def bot: (.user.login // "" | sub("\\[bot\\]$"; "")) as $l | $bots | index($l) != null;
    def quota: (.body // "") | test($re; "i");
    def sha_ok($s): ($s | length) >= 7 and ($head | startswith($s));
    ([$r[] | select(bot and .state != "PENDING" and (quota | not))]) as $rev
    | ([$c[] | select(bot and (quota | not)) | (.body // "")
        | capture("[Rr]eviewed commit:?[ `]*(?<s>[0-9a-f]{7,40})") | .s]) as $csha
    | if any($rev[]; .commit_id == $head) or any($csha[]; sha_ok(.)) then "head"
      elif ($rev | length) > 0 or ($csha | length) > 0 then "earlier"
      else "never" end')
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
  local reviews comments events b line last
  reviews=$(fetch_reviews) || { echo "unverified: reviews of PR $pr could not be read"; exit 4; }
  comments=$(fetch_comments) || { echo "unverified: comments of PR $pr could not be read"; exit 4; }
  # One row per bot item, oldest first: login  kind(quota|review)  time.
  events=$(jq -rn --argjson r "$reviews" --argjson c "$comments" --arg re "$quota_re" '
    ([$r[] | select(.state != "PENDING") | {l: .user.login, t: .submitted_at, b: .body}]
     + [$c[] | {l: .user.login, t: .created_at, b: .body}])
    | map(select(.l != null and .t != null)) | sort_by(.t)[]
    | [.l, (if (.b // "") | test($re; "i") then "quota" else "review" end), .t] | @tsv')
  for b in $bots; do
    line=$(awk -F'\t' -v OFS='\t' -v l="$(bot_login "$b")" '{ sub(/\[bot\]$/, "", $1) } $1 == l' <<<"$events")
    [[ -n "$line" ]] || continue
    last=$(awk -F'\t' '$2 == "quota" { t = $3 } END { print t }' <<<"$line")
    if [[ -n "$last" ]]; then
      if awk -F'\t' -v t="$last" '$2 == "review" && $3 > t { f = 1 } END { exit !f }' <<<"$line"; then
        if [[ -f "$flags" ]] && awk -F'\t' -v b="$b" '$1 == b { f = 1 } END { exit !f }' "$flags"; then
          rewrite "$flags" '$1 != b' -v b="$b"
          echo "recovered $b pr=$pr"
        fi
      else
        echo "quota $b $(record_quota "$b") pr=$pr"
      fi
    fi
  done
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
4. Keep waiting for reviews: requests stay throttled to one per bot per window across all PRs,
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
    local b
    for b in $bots; do
      known_bot "$b" && bot_login "$b" >/dev/null || continue
      out_of_quota "$b" || { bot=$b; break; }
    done
    [[ -n "$bot" ]] || { echo "out-of-quota all pr=$pr"; return 0; }
  fi
  known_bot "$bot" || { echo "review-gate.sh: unknown bot id '$bot' (ORCHESTRATE_REVIEW_BOTS: $bots)" >&2; exit 2; }
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
  if [[ "$dry" == yes ]]; then echo "would request $bot pr=$tpr ($(bot_trigger "$bot"))"; return 0; fi
  gh pr comment "$tpr" --repo "$repo" --body "$(bot_trigger "$bot")" >/dev/null 2>&1 || rc=$?
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
