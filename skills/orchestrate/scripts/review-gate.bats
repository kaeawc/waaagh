#!/usr/bin/env bats
# review-gate.sh (bot-review policy, quota outages, unreviewed ledger, request throttle) and its use
# by pr-merge.sh and merge-queue.sh, against a stubbed gh. Run: bats review-gate.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1793880000
  unset ORCHESTRATE_REVIEW_BOT_LOGIN ORCHESTRATE_REVIEW_TRIGGER ORCHESTRATE_REVIEW_CHECK ORCHESTRATE_REVIEW_QUOTA_RE ORCHESTRATE_REVIEW_EVERY ORCHESTRATE_REVIEW_PROBE_EVERY ORCHESTRATE_DIRECT_MERGE ORCHESTRATE_MERGE_SENSITIVE
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  OLD=1111111234567890abcdef1234567890abcdef12
  echo "$HEAD" >"$FX/head"
  echo '[]' >"$FX/reviews.json"
  echo '[]' >"$FX/comments.json"
  echo '{"check_runs":[]}' >"$FX/check-runs.json"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
case "$all" in
  "api repos/o/r/pulls/"*"/reviews"*) [ ! -f "$FX/read-fail" ] || { echo "HTTP 404" >&2; exit 1; }; cat "$FX/reviews.json" ;;
  "api repos/o/r/issues/"*"/comments"*) cat "$FX/comments.json" ;;
  "api repos/o/r/commits/"*"/check-runs"*) cat "$FX/check-runs.json" ;;
  "api --paginate repos/o/r/pulls/"*"/files"*) printf 'src/a.ts\n' ;;
  "pr comment"*) echo "$all" >>"$FX/writes" ;;
  "pr view"*"--json headRefOid") jq -n --arg h "$(cat "$FX/head")" '{headRefOid: $h}' ;;
  "pr view"*) if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}';
    else jq -n --arg h "$(cat "$FX/head")" '{state: "OPEN", isDraft: false, isCrossRepository: false,
      headRefOid: $h, author: {login: "me"}, mergeable: "MERGEABLE", autoMergeRequest: null}'; fi ;;
  "pr merge"*) echo MERGED >"$FX/merged" ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

rg() { "$SCRIPTS/review-gate.sh" "$@" --repo o/r; }
review() { # LOGIN COMMIT [BODY] [STATE] [AT]
  jq --arg l "$1" --arg c "$2" --arg b "${3:-Looks fine}" --arg s "${4:-COMMENTED}" --arg t "${5:-2026-11-05T09:00:00Z}" \
    '. + [{user: {login: $l}, commit_id: $c, body: $b, state: $s, submitted_at: $t}]' "$FX/reviews.json" >"$FX/r.tmp"
  mv "$FX/r.tmp" "$FX/reviews.json"
}
comment() { # LOGIN BODY [AT]
  jq --arg l "$1" --arg b "$2" --arg t "${3:-2026-11-05T09:30:00Z}" \
    '. + [{user: {login: $l}, body: $b, created_at: $t}]' "$FX/comments.json" >"$FX/c.tmp"
  mv "$FX/c.tmp" "$FX/comments.json"
}
checkrun() { # TITLE [CONCLUSION] [STATUS] [NAME] [COMPLETED_AT]: a check run on the head
  jq --arg t "$1" --arg c "${2:-neutral}" --arg s "${3:-completed}" --arg n "${4:-Claude Code Review}" \
    --arg at "${5:-2026-11-05T09:00:00Z}" \
    '.check_runs += [{name: $n, status: $s, conclusion: (if $s == "completed" then $c else null end),
      completed_at: $at, output: {title: $t}}]' "$FX/check-runs.json" >"$FX/k.tmp"
  mv "$FX/k.tmp" "$FX/check-runs.json"
}
merge() { ORCHESTRATE_DIRECT_MERGE=1 "$SCRIPTS/pr-merge.sh" --repo o/r --pr 5 --head "${HEAD:0:9}" --evidence test "$@"; }

@test "policy: off by default; a change is logged in decisions.log; unknown modes refused" {
  run rg policy
  [ "$status" -eq 0 ]
  [ "$output" = off ]
  run rg policy reviewed-once --note "owner, outage"
  [ "$status" -eq 0 ]
  [ "$output" = "review policy: reviewed-once (was off)" ]
  run rg policy
  [ "$output" = reviewed-once ]
  grep -q $'review-policy\toff -> reviewed-once\towner, outage' "$STATE/decisions.log"
  run rg policy sometimes
  [ "$status" -eq 2 ]
}

@test "check: policy off allows without reading GitHub" {
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok unreviewed policy=off" ]
  [ ! -f "$FX/calls" ]
}

@test "check review-at-head: head review passes, earlier review and none wait, quota notices never count" {
  rg policy review-at-head >/dev/null
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$output" = "wait never-reviewed" ]
  review claude '' "⚠️ Code review skipped: o has reached its monthly code review spending cap" COMMENTED
  review "claude[bot]" "$HEAD" "⚠️ Code review skipped: o has no extra usage available to pay for this review" COMMENTED
  review someone "$HEAD"
  review "github-actions[bot]" "$HEAD"
  review claude "$HEAD" "draft" PENDING
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$output" = "wait never-reviewed" ]
  review "claude[bot]" "$OLD"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$output" = "wait no-review-at-head" ]
  review "claude[bot]" "$HEAD"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ] && [ "$output" = "ok reviewed at-head" ]
}

@test "check: the bot's completed check run on the head counts as a review there; head read when not given" {
  rg policy review-at-head >/dev/null
  review "claude[bot]" "$OLD"
  # Not a review of this head: queued, in progress, declined, failed, timed out, another check.
  while IFS='|' read -r title concl st name; do
    echo '{"check_runs":[]}' >"$FX/check-runs.json"
    checkrun "$title" "$concl" "$st" "$name"
    run rg check --pr 5
    [ "$status" -eq 3 ] && [ "$output" = "wait no-review-at-head" ] || { echo "$title/$name: $status $output"; return 1; }
  done <<'CASES'
Code review queued...||queued|Claude Code Review
Code review in progress...||in_progress|Claude Code Review
Code review declined|neutral|completed|Claude Code Review
Code review failed|failure|completed|Claude Code Review
Code review timed out|timed_out|completed|Claude Code Review
Code review found no issues|neutral|completed|Some Other Check
CASES
  grep -q 'api repos/o/r/commits/'"$HEAD"'/check-runs?check_name=Claude%20Code%20Review&per_page=100' "$FX/calls"
  # The newest completed run decides: a found-no-issues run after a failed one is a review.
  checkrun "Code review failed" failure completed "Claude Code Review" 2026-11-05T08:00:00Z
  checkrun "Code review found no issues" neutral completed "Claude Code Review" 2026-11-05T10:00:00Z
  run rg check --pr 5
  [ "$status" -eq 0 ]
  [ "$output" = "ok reviewed at-head" ]
  grep -q 'pr view 5 --repo o/r --json headRefOid' "$FX/calls"
  # A review at the head needs no check-run read.
  review "claude[bot]" "$HEAD"
  : >"$FX/calls"
  run rg check --pr 5 --head "$HEAD"
  [ "$output" = "ok reviewed at-head" ]
  [ "$(grep -c check-runs "$FX/calls" || true)" -eq 0 ]
}

@test "check: a check run that kept an earlier result is an earlier review; an unreadable one counts for nothing" {
  rg policy reviewed-once >/dev/null
  checkrun "Code review skipped — no new changes" skipped
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok reviewed earlier-head (reviewed-once)" ]
  rg policy review-at-head >/dev/null
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$output" = "wait no-review-at-head" ]
  echo '{"check_runs":[]}' >"$FX/check-runs.json"
  checkrun "Code review not repeated — earlier findings still open" neutral
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$output" = "wait no-review-at-head" ]
  echo 'not json' >"$FX/check-runs.json"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$output" = "wait never-reviewed" ]
  # With no check run name configured, no check run is read.
  : >"$FX/calls"
  ORCHESTRATE_REVIEW_CHECK= run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$(grep -c check-runs "$FX/calls" || true)" -eq 0 ]
}

@test "check reviewed-once and green-only; an exemption allows one PR unreviewed" {
  rg policy reviewed-once >/dev/null
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ]
  [ "$output" = "wait never-reviewed" ]
  review claude "$OLD"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok reviewed earlier-head (reviewed-once)" ]
  echo '[]' >"$FX/reviews.json"
  rg policy green-only >/dev/null
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok unreviewed green-only (never)" ]
  rg policy review-at-head >/dev/null
  run rg exempt --pr 5 --reason "gates the manual-test round"
  [ "$status" -eq 0 ]
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "ok unreviewed exempt" ]
  run rg check --pr 6 --head "$HEAD"
  [ "$status" -eq 3 ]
  grep -q $'review-exempt\tpr=5\tgates the manual-test round' "$STATE/decisions.log"
}

@test "check: unreadable reviews are exit 4, never ok" {
  rg policy review-at-head >/dev/null
  touch "$FX/read-fail"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 4 ] && [[ "$output" == unverified:* ]]
}

@test "notice: the bot's budget notices are flagged once, and other comments pass" {
  run rg notice --author "claude[bot]" --pr 5 <<<"⚠️ Code review skipped: o has reached its monthly code review spending cap. An admin can raise it at https://claude.ai/admin-settings/usage"
  [ "$status" -eq 0 ]
  [ "$output" = "quota claude new pr=5" ]
  ORCHESTRATE_NOW=1793883600 run rg notice --author claude --pr 6 <<<"⚠️ Code review skipped: o has no extra usage available to pay for this review"
  [ "$output" = "quota claude known pr=6" ]
  ORCHESTRATE_NOW=1793883600 run rg notice --author claude --pr 7 <<<"⚠️ Code review skipped: what is left of the budget is too low to start another review"
  [ "$output" = "quota claude known pr=7" ]
  run rg notice --author claude <<<"No review was started: manual reviews can only be requested by someone with write access to this repository."
  [ "$output" = "bot claude" ]
  run rg notice --author alice <<<"we hit the spending cap in prod"
  [ "$output" = other ]
  run rg notice --author "github-actions[bot]" <<<"Code review declined"
  [ "$output" = other ]
  run rg outage
  [ "$output" = "out-of-quota claude since=2026-11-05T12:00:00Z last=2026-11-05T13:00:00Z asked=no" ]
}

@test "notice: the login and the quota pattern are overridable defaults" {
  ORCHESTRATE_REVIEW_BOT_LOGIN="my-claude-app[bot]" run rg notice --author my-claude-app <<<"spending cap reached"
  [ "$output" = "quota claude new" ]
  ORCHESTRATE_REVIEW_BOT_LOGIN="my-claude-app[bot]" run rg notice --author claude <<<"spending cap reached"
  [ "$output" = other ]
  ORCHESTRATE_REVIEW_QUOTA_RE='out of tokens' run rg notice --author claude <<<"Out of tokens for today"
  [ "$output" = "quota claude known" ]
  ORCHESTRATE_REVIEW_QUOTA_RE='out of tokens' run rg notice --author claude <<<"spending cap reached"
  [ "$output" = "bot claude" ]
}

@test "outage ask: one question with the ladder, asked once per outage" {
  run rg outage ask
  [ "$output" = "no reviewer out of quota" ]
  rg notice --author claude <<<"is too low to start another review" >/dev/null
  run rg outage ask --waiting 8
  [ "$status" -eq 0 ]
  [[ "$output" == "Bot reviews are out of quota: claude (since 2026-11-05T12:00:00Z). 8 PRs with green checks are waiting for a review. Review policy is off."* ]]
  [[ "$output" == *"1. Green checks only for one urgent PR"*"2. Green checks only for all PRs"*"unreviewed-merges ledger"*"3. Reviewed once is enough"*"4. Keep waiting"* ]]
  run rg outage ask
  [ "$output" = "already asked" ]
  run rg outage ask --force
  [[ "$output" == "Bot reviews are out of quota"* ]]
  # More notices in the same outage, or from another login, do not ask again.
  rg notice --author claude-x <<<"spending cap" >/dev/null
  rg notice --author claude <<<"spending cap" >/dev/null
  run rg outage ask
  [ "$output" = "already asked" ]
  # A new outage after the last one cleared is asked again.
  rg outage clear --bot claude >/dev/null
  ORCHESTRATE_NOW=1793890000 rg notice --author claude <<<"spending cap" >/dev/null
  run rg outage ask
  [[ "$output" == "Bot reviews are out of quota: claude (since 2026-11-05T14:46:40Z)."* ]]
}

@test "scan: records notices from a PR and clears the bot when a later review completed" {
  comment claude "⚠️ Code review skipped: o has reached its monthly code review spending cap" 2026-11-05T09:00:00Z
  comment someone "spending cap?" 2026-11-05T09:10:00Z
  run rg scan --pr 5
  [ "$status" -eq 0 ]
  [ "$output" = "quota claude new pr=5" ]
  review "claude[bot]" "$HEAD" "Claude finished reviewing: 1 important finding" COMMENTED 2026-11-05T10:00:00Z
  run rg scan --pr 5
  [ "$output" = "recovered claude pr=5" ]
  run rg outage
  [ "$output" = "no reviewer out of quota" ]
}

@test "ledger: pr-merge.sh ledgers a green-only merge; clear names pending retro reviews" {
  rg policy green-only >/dev/null
  run merge
  [ "$status" -eq 0 ]
  [[ "$output" == "merged 5 feedface" ]]
  run rg ledger pending
  [ "$output" = "$(printf '2026-11-05T12:00:00Z\t5\t%s\tgreen-only (never)\tpending' "$HEAD")" ]
  grep -q 'review=ok unreviewed green-only' "$STATE/merges.log"
  rg notice --author claude <<<"spending cap" >/dev/null
  run rg outage clear --bot claude
  [ "$output" = "cleared claude; unreviewed merges awaiting a retroactive review: 1 (review-gate.sh ledger pending)" ]
  rg ledger requested --pr 5 >/dev/null
  run rg ledger pending
  [ -z "$output" ]
  [[ "$(rg ledger)" == *$'\trequested' ]]
}

@test "pr-merge: a policy not met refuses with exit 13 and merges nothing; reviewed merges are not ledgered" {
  rg policy review-at-head >/dev/null
  run merge
  [ "$status" -eq 13 ]
  [ "$output" = "needs review: wait never-reviewed (review-gate.sh policy)" ]
  [ "$(grep -c 'pr merge' "$FX/calls" || true)" -eq 0 ]
  grep -q 'refused review: wait never-reviewed' "$STATE/merges.log"
  review claude "$HEAD"
  run merge
  [ "$status" -eq 0 ]
  [ ! -s "$STATE/unreviewed-merges.tsv" ]
}

@test "pr-merge: an exempt PR merges once and the exemption is consumed; no policy file reads nothing" {
  run merge
  [ "$status" -eq 0 ]
  [ "$(grep -c reviews "$FX/calls" || true)" -eq 0 ]
  rm -f "$FX/merged" "$STATE/ops/merge-pr5.json"
  rg policy review-at-head >/dev/null
  rg exempt --pr 5 --reason urgent >/dev/null
  run merge
  [ "$status" -eq 0 ]
  grep -q $'\t5\t.*\texempt\tpending' "$STATE/unreviewed-merges.tsv"
  [ -z "$(rg exempt --list)" ]
}

@test "request: one request per window across PRs, gating PRs first, probes while out of quota" {
  run rg request --bot claude --pr 7
  [ "$status" -eq 0 ]
  [ "$output" = "requested claude pr=7 queued=0" ]
  grep -q '^pr comment 7 --repo o/r --body @claude review$' "$FX/writes"
  run rg request --bot claude --pr 8
  [ "$output" = "throttled claude next=2026-11-05T12:20:00Z queued=1" ]
  ORCHESTRATE_NOW=1793880060 run rg request --bot claude --pr 9 --priority high
  [ "$output" = "throttled claude next=2026-11-05T12:20:00Z queued=2" ]
  ORCHESTRATE_NOW=1793881200 run rg request --bot claude
  [ "$output" = "requested claude pr=9 queued=1" ]
  [ "$(wc -l <"$FX/writes" | tr -d ' ')" = 2 ]
  rg notice --author claude <<<"spending cap" >/dev/null
  ORCHESTRATE_NOW=1793882400 run rg request --bot claude
  [ "$output" = "throttled claude next=2026-11-05T13:20:00Z queued=1" ]
  ORCHESTRATE_NOW=1793884800 run rg request --bot claude --dry-run
  [ "$output" = "would request claude pr=8 (@claude review)" ]
  ORCHESTRATE_NOW=1793884800 rg request --bot claude >/dev/null
  run rg request --bot claude
  [ "$output" = "empty claude" ]
  run rg request --bot nobody --pr 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown bot id 'nobody'"* ]]
  [ "$(wc -l <"$STATE/review-requests.log" | tr -d ' ')" = 3 ]
}

@test "request: the request phrase is an overridable default; an empty one posts nothing and waits" {
  ORCHESTRATE_REVIEW_TRIGGER="@claude review once" run rg request --pr 7
  [ "$output" = "requested claude pr=7 queued=0" ]
  grep -q '^pr comment 7 --repo o/r --body @claude review once$' "$FX/writes"
  ORCHESTRATE_REVIEW_TRIGGER= ORCHESTRATE_NOW=1793890000 run rg request --pr 8
  [ "$status" -eq 0 ]
  [ "$output" = "not-requested claude pr=8 (ORCHESTRATE_REVIEW_TRIGGER is empty: waiting for an automatic review)" ]
  [ "$(wc -l <"$FX/writes" | tr -d ' ')" -eq 1 ]
  [ "$(grep -c '^8' "$STATE/review-queue/claude.tsv" || true)" -eq 0 ]
}

@test "merge-queue: pr-merge exit 13 keeps the item waiting" {
  grep -q '13) set_outcome "$qid" waiting "waiting for a bot review' "$SCRIPTS/merge-queue.sh"
}

@test "docs: the doctrine, merge-bot brief and README point at review-gate.sh" {
  grep -q 'review-quota.md' "$ROOT/skills/orchestrate/SKILL.md"
  grep -q 'review-gate.sh notice' "$ROOT/skills/orchestrate/SKILL.md"
  grep -q 'Exit 13' "$ROOT/skills/orchestrate/roles/merge-bot.md"
  grep -q '`review-gate.sh`' "$ROOT/README.md"
  for w in review-at-head reviewed-once green-only "outage ask" "ledger pending" ORCHESTRATE_REVIEW_EVERY "--priority high" \
           "@claude review" "claude[bot]" ORCHESTRATE_REVIEW_TRIGGER "Claude Code Review"; do
    grep -q -F -- "$w" "$ROOT/skills/orchestrate/review-quota.md" || { echo "review-quota.md lacks $w"; return 1; }
  done
}

@test "docs and the gate name no Codex or CodeRabbit reviewer" {
  for f in skills/orchestrate/review-quota.md skills/orchestrate/scripts/review-gate.sh skills/orchestrate/roles/merge-bot.md; do
    [ "$(grep -c -i -E 'codex|coderabbit' "$ROOT/$f" || true)" -eq 0 ] || { echo "$f names codex/coderabbit"; return 1; }
  done
}

@test "help covers exactly the header" {
  run "$SCRIPTS/review-gate.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == "# Bot-review gate:"* && "$output" == *"5 a write failed" ]]
}

@test "request without --bot: the bot unless it is out of quota; then nothing is asked or queued" {
  run rg request
  [ "$status" -eq 2 ]
  run rg request --pr 7
  [ "$status" -eq 0 ]
  [ "$output" = "requested claude pr=7 queued=0" ]
  rg notice --author claude <<<"⚠️ Code review skipped: has reached its monthly code review spending cap" >/dev/null
  ORCHESTRATE_NOW=1793890000 run rg request --pr 8
  [ "$status" -eq 0 ]
  [ "$output" = "out-of-quota claude pr=8" ]
  [ "$(wc -l <"$FX/writes" | tr -d ' ')" -eq 1 ]
  [ "$(grep -c '^8' "$STATE/review-queue/claude.tsv" || true)" -eq 0 ]
}
