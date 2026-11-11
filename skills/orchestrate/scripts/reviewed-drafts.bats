#!/usr/bin/env bats
# Reviewed drafts (#205): triage-tick.sh snapshot names every draft PR with a ship verdict or green
# checks (pr-ready.sh skips drafts, so the merge loop never reaches them), and in autonomous mode
# (campaign.sh mode autonomous) marks a ship draft that no hold names ready. Stubbed gh.
# Run: bats reviewed-drafts.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  unset ORCHESTRATE_DEVICE_SLOTS ORCHESTRATE_CLASSIFIER_CMD ORCHESTRATE_HOST_LOAD ORCHESTRATE_GH_API
  export ORCHESTRATE_HOST_LOAD1=0.50 ORCHESTRATE_HOST_CPUS=8 ORCHESTRATE_HOST_FREE_MB=32768
  ST="$ORCHESTRATE_STATE_DIR/o__r"; mkdir -p "$ST"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
case "$*" in
  "api repos/o/r/actions/runs?"*)
    echo '{"workflow_runs":[{"name":"Test","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaa","id":10,"created_at":"2026-09-27T01:00:00Z"}]}' ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "issue list"*) echo '[]' ;;
  "api graphql"*"reviewThreads"*) echo 'no threads here' >&2; exit 1 ;;
  "api graphql"*) cat "$FX/snapshot.json" ;;
  "pr ready "*)
    [ ! -f "$FX/ready-refused" ] || { echo "GraphQL: Resource not accessible by integration (markPullRequestReadyForReview)" >&2; exit 1; }
    [ ! -f "$FX/ready-fails" ] || { echo "HTTP 500: boom" >&2; exit 1; }
    a="$*"; n=${a#pr ready }; touch "$FX/undrafted-${n%% *}"; echo "ready" ;;
  "api -X PATCH repos/o/r/pulls/"*)
    [ -f "$FX/rest-keeps-draft" ] || { a="$*"; n=${a#api -X PATCH repos/o/r/pulls/}; touch "$FX/undrafted-${n%% *}"; }
    echo '{}' ;;
  "api repos/o/r/pulls/"*)
    a="$*"; n=${a#api repos/o/r/pulls/}; n=${n%% *}
    if [ -f "$FX/undrafted-$n" ]; then echo "{\"number\":$n,\"draft\":false}"; else echo "{\"number\":$n,\"draft\":true}"; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  # Open PRs: 20 a draft with a ship verdict, 21 a draft with green checks only, 22 a draft with
  # neither, 23 a ready PR with a ship verdict (not a draft: nothing to say).
  echo '[{"number":20,"closingIssuesReferences":[]},{"number":21,"closingIssuesReferences":[]},{"number":22,"closingIssuesReferences":[]},{"number":23,"closingIssuesReferences":[]}]' >"$FX/prs.json"
  jq -n 'def node($n; $h; $d; $r): {number: $n, headRefOid: $h, isDraft: $d,
        commits: {nodes: [{commit: {statusCheckRollup: {state: $r}}}]}, reviews: {nodes: []}};
    {data: {repository: {pullRequests: {pageInfo: {hasNextPage: false}, nodes: [
      node(20; "a20a20a20a20"; true; "PENDING"), node(21; "a21a21a21a21"; true; "SUCCESS"),
      node(22; "a22a22a22a22"; true; "FAILURE"), node(23; "a23a23a23a23"; false; "SUCCESS")]}}}}' >"$FX/snapshot.json"
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 20 --verdict ship --head a20a20a >/dev/null
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 23 --verdict ship >/dev/null
}

snap() { "$SCRIPTS/triage-tick.sh" snapshot --repo o/r --branch main "$@"; }
calls() { cat "$FX/calls" 2>/dev/null || true; }

@test "attended: a draft with a ship verdict or green checks is reported, nothing is marked ready" {
  run snap
  [ "$status" -eq 0 ]
  [ "$(grep -c '^reviewed-draft ' <<<"$output")" -eq 2 ]
  [[ "$output" == *$'\nreviewed-draft #20 review=ship rollup=PENDING: mark ready?\n'* ]]
  [[ "$output" == *$'\nreviewed-draft #21 review=none rollup=SUCCESS: mark ready?\n'* ]]
  [[ "$output" != *"reviewed-draft #22"* ]]
  [[ "$output" != *"reviewed-draft #23"* ]]
  [[ "$(snap_line verdict)" == *"reviewed-draft=2"* ]]
  required_snapshot_lines
  [ "$(calls | grep -c '^pr ready' || true)" -eq 0 ]
  [ "$(calls | grep -c 'PATCH' || true)" -eq 0 ]
  [ ! -f "$ST/drafts.log" ]
}

@test "the reviewed-draft line sits right after prs and is documented in the usage header" {
  run snap
  [ "$status" -eq 0 ]
  [ "$(awk '$1 == "prs" { p = NR } $1 == "reviewed-draft" && !d { d = NR } END { print d - p }' <<<"$output")" = 1 ]
  run snapshot_line_names "$SCRIPTS/triage-tick.sh"
  [ "$(awk '$1 == "prs" { p = NR } $1 == "reviewed-draft" { d = NR } END { print d - p }' <<<"$output")" = 1 ]
  grep -q 'reviewed-draft=<n>' "$SCRIPTS/triage-tick.sh"
}

@test "autonomous: a ship draft no hold names is marked ready and read back; green-only drafts are only reported" {
  run "$SCRIPTS/campaign.sh" mode autonomous --repo o/r
  [ "$output" = autonomous ]
  run snap
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nreviewed-draft #20 review=ship rollup=PENDING: marked ready\n'* ]]
  [[ "$output" == *"reviewed-draft #21 review=none rollup=SUCCESS: mark ready?"* ]]
  [[ "$(snap_line verdict)" == *"reviewed-draft=1"* ]]
  [ "$(calls | grep -c '^pr ready 20 --repo o/r$' || true)" -eq 1 ]
  [ "$(calls | grep -c '^pr ready 21' || true)" -eq 0 ]
  [[ "$(cat "$ST/drafts.log")" == *$'pr=20\tvia=graphql\tmarked ready'* ]]
}

@test "autonomous: a held draft, a frozen campaign, or a ship verdict for an older head is not marked ready" {
  "$SCRIPTS/campaign.sh" mode autonomous --repo o/r >/dev/null
  "$SCRIPTS/hold.sh" add --repo o/r --pr 20 --until main-green --reason "wait" >/dev/null
  run snap
  [[ "$output" == *"reviewed-draft #20 review=ship rollup=PENDING: held (until:main-green)"* ]]
  [[ "$(snap_line verdict)" == *"reviewed-draft=2"* ]]
  "$SCRIPTS/hold.sh" release --repo o/r --pr 20 >/dev/null
  printf '2026-09-27T00:00:00Z\trelease\n' >"$ST/FREEZE"
  run snap
  [[ "$output" == *"reviewed-draft #20 review=ship rollup=PENDING: held (until:freeze-end)"* ]]
  rm "$ST/FREEZE"
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 20 --verdict ship --head 0ld0ld0 >/dev/null
  run snap
  [[ "$output" == *"reviewed-draft #20 review=ship rollup=PENDING: mark ready? (the ship verdict is for 0ld0ld0, not the head)"* ]]
  [ "$(calls | grep -c '^pr ready' || true)" -eq 0 ]
}

@test "autonomous: a non-ship latest verdict is not ship; a green draft under fix-first is held" {
  "$SCRIPTS/campaign.sh" mode autonomous --repo o/r >/dev/null
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 20 --verdict fix-first >/dev/null
  "$SCRIPTS/review-ledger.sh" record --repo o/r --pr 21 --verdict rethink >/dev/null
  run snap
  [[ "$output" != *"reviewed-draft #20"* ]]
  [[ "$output" == *"reviewed-draft #21 review=rethink rollup=SUCCESS: held (until:review-ship)"* ]]
  [ "$(calls | grep -c '^pr ready' || true)" -eq 0 ]
}

@test "autonomous: GraphQL refused falls back to REST and reads back; with the fallback off the refusal is the failure" {
  "$SCRIPTS/campaign.sh" mode autonomous --repo o/r >/dev/null
  touch "$FX/ready-refused"
  run snap
  [[ "$output" == *"reviewed-draft #20 review=ship rollup=PENDING: marked ready"* ]]
  [ "$(calls | grep -c '^api -X PATCH repos/o/r/pulls/20 -F draft=false$' || true)" -eq 1 ]
  [[ "$(cat "$ST/drafts.log")" == *$'pr=20\tvia=rest\tmarked ready'* ]]
  [ -f "$ORCHESTRATE_STATE_DIR/gh-no-graphql" ]
  # ORCHESTRATE_GH_API=graphql never falls back: the refusal is the failure.
  rm -f "$FX"/undrafted-* "$FX/calls"
  ORCHESTRATE_GH_API=graphql run snap
  [[ "$output" == *"reviewed-draft #20 review=ship rollup=PENDING: mark-ready failed (graphql: GraphQL: Resource not accessible"* ]]
  [ "$(calls | grep -c 'PATCH' || true)" -eq 0 ]
  [[ "$(snap_line verdict)" == *"reviewed-draft=2"* ]]
}

@test "autonomous: REST that keeps the draft, or a failed write, is reported as mark-ready failed" {
  "$SCRIPTS/campaign.sh" mode autonomous --repo o/r >/dev/null
  touch "$FX/ready-refused" "$FX/rest-keeps-draft"
  run snap
  [[ "$output" == *"reviewed-draft #20 review=ship rollup=PENDING: mark-ready failed (still a draft after the rest write"* ]]
  [[ "$(snap_line verdict)" == *"reviewed-draft=2"* ]]
  rm -f "$FX/ready-refused" "$FX/rest-keeps-draft" "$ORCHESTRATE_STATE_DIR/gh-no-graphql"
  touch "$FX/ready-fails"
  run snap
  [[ "$output" == *"reviewed-draft #20 review=ship rollup=PENDING: mark-ready failed (graphql: HTTP 500: boom)"* ]]
  [ "$(awk 'END { print NR }' "$ST/drafts.log")" -eq 2 ]
}

@test "campaign mode defaults to attended, is set in the ledger, shows in status and refuses other values" {
  run "$SCRIPTS/campaign.sh" mode --repo o/r
  [ "$output" = attended ]
  run "$SCRIPTS/campaign.sh" mode sometimes --repo o/r
  [ "$status" -eq 2 ]
  run "$SCRIPTS/campaign.sh" mode verified --repo o/r
  [ "$status" -eq 2 ]
  run "$SCRIPTS/campaign.sh" close-policy autonomous --repo o/r
  [ "$status" -eq 2 ]
  "$SCRIPTS/campaign.sh" mode autonomous --repo o/r >/dev/null
  [ "$(jq -r .mode "$ST/campaign.json")" = autonomous ]
  run "$SCRIPTS/campaign.sh" status --repo o/r
  [[ "$output" == *$'\nmode=autonomous\n'* ]]
}

@test "the briefs open PRs ready for review, and the doctrine names the reviewed-draft line" {
  grep -q 'ready for review, not as a draft' "$ROOT/skills/orchestrate/briefs/implement.md"
  grep -q 'ready for review, not as a draft' "$ROOT/skills/orchestrate/roles/cloud-session-brief.md"
  grep -q 'reviewed-draft=<n>' "$ROOT/skills/orchestrate/roles/triage-tick.md"
  grep -q 'campaign.sh" mode autonomous' "$ROOT/skills/orchestrate/roles/triage-tick.md"
}
