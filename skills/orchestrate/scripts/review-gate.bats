#!/usr/bin/env bats
# review-gate.sh (bot-review policy, quota outages, unreviewed ledger, request throttle) and its use
# by pr-merge.sh and merge-queue.sh, against a stubbed gh. Run: bats review-gate.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1793880000
  unset ORCHESTRATE_REVIEW_BOTS ORCHESTRATE_REVIEW_EVERY ORCHESTRATE_REVIEW_PROBE_EVERY ORCHESTRATE_DIRECT_MERGE ORCHESTRATE_MERGE_SENSITIVE
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  HEAD=abcdef1234567890abcdef1234567890abcdef12
  OLD=1111111234567890abcdef1234567890abcdef12
  echo "$HEAD" >"$FX/head"
  echo '[]' >"$FX/reviews.json"
  echo '[]' >"$FX/comments.json"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
case "$all" in
  "api repos/o/r/pulls/"*"/reviews"*) [ ! -f "$FX/read-fail" ] || { echo "HTTP 404" >&2; exit 1; }; cat "$FX/reviews.json" ;;
  "api repos/o/r/issues/"*"/comments"*) cat "$FX/comments.json" ;;
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
merge() { ORCHESTRATE_DIRECT_MERGE=1 "$SCRIPTS/pr-merge.sh" --repo o/r --pr 5 --head "${HEAD:0:9}" --evidence test "$@"; }

@test "policy: off by default; a change is logged in decisions.log; unknown modes refused" {
  run rg policy
  [ "$status" -eq 0 ] && [ "$output" = off ]
  run rg policy reviewed-once --note "owner, outage"
  [ "$status" -eq 0 ] && [ "$output" = "review policy: reviewed-once (was off)" ]
  run rg policy
  [ "$output" = reviewed-once ]
  grep -q $'review-policy\toff -> reviewed-once\towner, outage' "$STATE/decisions.log"
  run rg policy sometimes
  [ "$status" -eq 2 ]
}

@test "check: policy off allows without reading GitHub" {
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ] && [ "$output" = "ok unreviewed policy=off" ]
  [ ! -f "$FX/calls" ]
}

@test "check review-at-head: head review passes, earlier review and none wait, quota notices never count" {
  rg policy review-at-head >/dev/null
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ] && [ "$output" = "wait never-reviewed" ]
  review coderabbitai '' "You have hit the free review limit" COMMENTED
  review "chatgpt-codex-connector[bot]" "$HEAD" "You have reached your Codex usage limits" COMMENTED
  review someone "$HEAD"
  review coderabbitai "$HEAD" "draft" PENDING
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ] && [ "$output" = "wait never-reviewed" ]
  review "coderabbitai[bot]" "$OLD"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ] && [ "$output" = "wait no-review-at-head" ]
  review "chatgpt-codex-connector[bot]" "$HEAD"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ] && [ "$output" = "ok reviewed at-head" ]
}

@test "check: a bot comment naming the reviewed commit counts for that commit; head read when not given" {
  rg policy review-at-head >/dev/null
  comment "chatgpt-codex-connector[bot]" "Codex Review: Didn't find any major issues. Reviewed commit: \`${OLD:0:10}\`"
  run rg check --pr 5
  [ "$status" -eq 3 ] && [ "$output" = "wait no-review-at-head" ]
  comment "chatgpt-codex-connector[bot]" "Codex Review: no issues. Reviewed commit: \`${HEAD:0:10}\`"
  run rg check --pr 5
  [ "$status" -eq 0 ] && [ "$output" = "ok reviewed at-head" ]
  grep -q 'pr view 5 --repo o/r --json headRefOid' "$FX/calls"
}

@test "check reviewed-once and green-only; an exemption allows one PR unreviewed" {
  rg policy reviewed-once >/dev/null
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 3 ] && [ "$output" = "wait never-reviewed" ]
  review coderabbitai "$OLD"
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ] && [ "$output" = "ok reviewed earlier-head (reviewed-once)" ]
  echo '[]' >"$FX/reviews.json"
  rg policy green-only >/dev/null
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ] && [ "$output" = "ok unreviewed green-only (never)" ]
  rg policy review-at-head >/dev/null
  run rg exempt --pr 5 --reason "gates the manual-test round"
  [ "$status" -eq 0 ]
  run rg check --pr 5 --head "$HEAD"
  [ "$status" -eq 0 ] && [ "$output" = "ok unreviewed exempt" ]
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

@test "notice: quota notices are classified per bot, flagged once, and other comments pass" {
  run rg notice --author "chatgpt-codex-connector[bot]" --pr 5 <<<"You have reached your Codex usage limits. Try again later."
  [ "$status" -eq 0 ] && [ "$output" = "quota codex new pr=5" ]
  ORCHESTRATE_NOW=1793883600 run rg notice --author chatgpt-codex-connector --pr 6 <<<"usage limits reached"
  [ "$output" = "quota codex known pr=6" ]
  run rg notice --author coderabbitai --pr 5 <<<"Rate limit exceeded: please wait 23 minutes before requesting another review."
  [ "$output" = "quota coderabbit new pr=5" ]
  run rg notice --author coderabbitai <<<"Walkthrough: adds a parser"
  [ "$output" = "bot coderabbit" ]
  run rg notice --author alice <<<"we hit a rate limit in prod"
  [ "$output" = other ]
  run rg outage
  [ "$output" = "$(printf 'out-of-quota codex since=2026-11-05T12:00:00Z last=2026-11-05T13:00:00Z asked=no\nout-of-quota coderabbit since=2026-11-05T12:00:00Z last=2026-11-05T12:00:00Z asked=no')" ]
}

@test "outage ask: one question with the ladder, asked once per outage" {
  run rg outage ask
  [ "$output" = "no reviewer out of quota" ]
  rg notice --author coderabbitai <<<"free review limit reached" >/dev/null
  run rg outage ask --waiting 8
  [ "$status" -eq 0 ]
  [[ "$output" == "Bot reviews are out of quota: coderabbit (since 2026-11-05T12:00:00Z). 8 PRs with green checks are waiting for a review. Review policy is off."* ]]
  [[ "$output" == *"1. Green checks only for one urgent PR"*"2. Green checks only for all PRs"*"unreviewed-merges ledger"*"3. Reviewed once is enough"*"4. Keep waiting"* ]]
  run rg outage ask
  [ "$output" = "already asked" ]
  run rg outage ask --force
  [[ "$output" == "Bot reviews are out of quota"* ]]
  rg notice --author codex-x <<<"usage limits" >/dev/null
  rg notice --author chatgpt-codex-connector <<<"usage limits" >/dev/null
  run rg outage ask
  [[ "$output" == "Bot reviews are out of quota: coderabbit (since"*", codex (since"* ]]
}

@test "scan: records notices from a PR and clears a bot whose later review completed" {
  comment coderabbitai "Rate limit exceeded" 2026-11-05T09:00:00Z
  comment someone "rate limit?" 2026-11-05T09:10:00Z
  run rg scan --pr 5
  [ "$status" -eq 0 ] && [ "$output" = "quota coderabbit new pr=5" ]
  review "coderabbitai[bot]" "$HEAD" "Actionable comments posted: 1" COMMENTED 2026-11-05T10:00:00Z
  run rg scan --pr 5
  [ "$output" = "recovered coderabbit pr=5" ]
  run rg outage
  [ "$output" = "no reviewer out of quota" ]
}

@test "ledger: pr-merge.sh ledgers a green-only merge; clear names pending retro reviews" {
  rg policy green-only >/dev/null
  run merge
  [ "$status" -eq 0 ] && [[ "$output" == "merged 5 feedface" ]]
  run rg ledger pending
  [ "$output" = "$(printf '2026-11-05T12:00:00Z\t5\t%s\tgreen-only (never)\tpending' "$HEAD")" ]
  grep -q 'review=ok unreviewed green-only' "$STATE/merges.log"
  rg notice --author coderabbitai <<<"rate limited" >/dev/null
  run rg outage clear --bot coderabbit
  [ "$output" = "cleared coderabbit; unreviewed merges awaiting a retroactive review: 1 (review-gate.sh ledger pending)" ]
  rg ledger requested --pr 5 >/dev/null
  run rg ledger pending
  [ -z "$output" ]
  [[ "$(rg ledger)" == *$'\trequested' ]]
}

@test "pr-merge: a policy not met refuses with exit 13 and merges nothing; reviewed merges are not ledgered" {
  rg policy review-at-head >/dev/null
  run merge
  [ "$status" -eq 13 ] && [ "$output" = "needs review: wait never-reviewed (review-gate.sh policy)" ]
  ! grep -q 'pr merge' "$FX/calls"
  grep -q 'refused review: wait never-reviewed' "$STATE/merges.log"
  review coderabbitai "$HEAD"
  run merge
  [ "$status" -eq 0 ]
  [ ! -s "$STATE/unreviewed-merges.tsv" ]
}

@test "pr-merge: an exempt PR merges once and the exemption is consumed; no policy file reads nothing" {
  run merge
  [ "$status" -eq 0 ]
  ! grep -q reviews "$FX/calls"
  rm -f "$FX/merged" "$STATE/ops/merge-pr5.json"
  rg policy review-at-head >/dev/null
  rg exempt --pr 5 --reason urgent >/dev/null
  run merge
  [ "$status" -eq 0 ]
  grep -q $'\t5\t.*\texempt\tpending' "$STATE/unreviewed-merges.tsv"
  [ -z "$(rg exempt --list)" ]
}

@test "request: one request per bot per window across PRs, gating PRs first, probes while out of quota" {
  run rg request --bot coderabbit --pr 7
  [ "$status" -eq 0 ] && [ "$output" = "requested coderabbit pr=7 queued=0" ]
  grep -q 'pr comment 7 --repo o/r --body @coderabbitai review' "$FX/writes"
  run rg request --bot coderabbit --pr 8
  [ "$output" = "throttled coderabbit next=2026-11-05T12:20:00Z queued=1" ]
  ORCHESTRATE_NOW=1793880060 run rg request --bot coderabbit --pr 9 --priority high
  [ "$output" = "throttled coderabbit next=2026-11-05T12:20:00Z queued=2" ]
  ORCHESTRATE_NOW=1793881200 run rg request --bot coderabbit
  [ "$output" = "requested coderabbit pr=9 queued=1" ]
  [ "$(wc -l <"$FX/writes" | tr -d ' ')" = 2 ]
  rg notice --author coderabbitai <<<"rate limited" >/dev/null
  ORCHESTRATE_NOW=1793882400 run rg request --bot coderabbit
  [ "$output" = "throttled coderabbit next=2026-11-05T13:20:00Z queued=1" ]
  ORCHESTRATE_NOW=1793884800 run rg request --bot coderabbit --dry-run
  [ "$output" = "would request coderabbit pr=8 (@coderabbitai review)" ]
  run rg request --bot codex
  [ "$output" = "empty codex" ]
  run rg request --bot nobody --pr 1
  [ "$status" -eq 2 ]
  [ "$(wc -l <"$STATE/review-requests.log" | tr -d ' ')" = 2 ]
}

@test "merge-queue: pr-merge exit 13 keeps the item waiting" {
  grep -q '13) set_outcome "$qid" waiting "waiting for a bot review' "$SCRIPTS/merge-queue.sh"
}

@test "docs: the doctrine, merge-bot brief and README point at review-gate.sh" {
  grep -q 'review-quota.md' "$ROOT/skills/orchestrate/SKILL.md"
  grep -q 'review-gate.sh notice' "$ROOT/skills/orchestrate/SKILL.md"
  grep -q 'Exit 13' "$ROOT/skills/orchestrate/roles/merge-bot.md"
  grep -q '`review-gate.sh`' "$ROOT/README.md"
  for w in review-at-head reviewed-once green-only "outage ask" "ledger pending" ORCHESTRATE_REVIEW_EVERY "--priority high"; do
    grep -q -- "$w" "$ROOT/skills/orchestrate/review-quota.md"
  done
}

@test "help covers exactly the header" {
  run "$SCRIPTS/review-gate.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == "# Bot-review gate:"* && "$output" == *"5 a write failed" ]]
}

@test "request without --bot: the first listed bot not out of quota; none asked when all are out" {
  run rg request
  [ "$status" -eq 2 ]
  rg notice --author chatgpt-codex-connector <<<"You have reached your Codex usage limits" >/dev/null
  run rg request --pr 7
  [ "$status" -eq 0 ] && [ "$output" = "requested coderabbit pr=7 queued=0" ]
  [ "$(grep -c '@codex' "$FX/writes" || true)" -eq 0 ]
  ORCHESTRATE_REVIEW_BOTS=codex run rg request --pr 8
  [ "$status" -eq 0 ] && [ "$output" = "out-of-quota all pr=8" ]
  [ "$(wc -l <"$FX/writes" | tr -d ' ')" -eq 1 ]
  run test -e "$STATE/review-queue/codex.tsv"
  [ "$status" -ne 0 ]
}
