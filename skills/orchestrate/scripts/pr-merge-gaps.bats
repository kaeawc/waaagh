#!/usr/bin/env bats
# pr-merge.sh refusal paths the other suites do not reach: a missing or stale readiness row (exit 7),
# unreadable, unproven, pending or missing check state without --evidence (exit 6, #428), an
# unreadable review state (exit 9), the merge-sensitive refusals (exit 9) and lock loop, a
# superseded journal, and --method.
# Stubbed gh. Run: bats scripts/pr-merge-gaps.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_DIRECT_MERGE ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE ORCHESTRATE_REVIEW_BOT_LOGIN ORCHESTRATE_REVIEW_TRIGGER ORCHESTRATE_REVIEW_CHECK
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  HEAD=abcdef0123456789abcdef0123456789abcdef01
  # Fixture switches in $FX: list-forbidden (PR list answers HTTP 403), list-head (the head the PR
  # list shows), view-state (state `pr view` reports), reviews-fail, files-fail, base-fail, behind,
  # rollup (JSON checks added to the passing "build"), rules (the rulesets answer).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
HEAD=abcdef0123456789abcdef0123456789abcdef01
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) cat "$FX/rules" 2>/dev/null || echo '[]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) echo '{"data":{"repository":{"p1":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' ;;
  "api --paginate repos/o/r/pulls/1/files"*) [ ! -f "$FX/files-fail" ] || { echo "HTTP 404" >&2; exit 1; }; printf 'gradle/libs.versions.toml\nsrc/a.kt\n' ;;
  "api repos/o/r/pulls/1/reviews"*) [ ! -f "$FX/reviews-fail" ] || { echo "HTTP 404" >&2; exit 1; }; echo '[]' ;;
  "api repos/o/r/issues/1/comments"*) echo '[]' ;;
  "api repos/o/r/pulls/1 "*) [ ! -f "$FX/base-fail" ] || { echo "HTTP 404" >&2; exit 1; }; echo main ;;
  "api repos/o/r/compare/"*"...main "*) printf 'gradle/libs.versions.toml\n' ;; # the base's drift
  "api repos/o/r/compare/"*) cat "$FX/behind" 2>/dev/null || echo 0 ;;
  "pr list"*) [ ! -f "$FX/list-forbidden" ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    jq -n --arg h "$(cat "$FX/list-head" 2>/dev/null || echo "$HEAD")" '[{number: 1, author: {login: "me"}, isDraft: false,
      isCrossRepository: false, baseRefName: "main", headRefOid: $h, mergeable: "MERGEABLE", labels: [],
      statusCheckRollup: [{name: "build", conclusion: "SUCCESS"}]} | .statusCheckRollup += ($x | fromjson)]' \
      --arg x "$(cat "$FX/rollup" 2>/dev/null || echo '[]')" ;;
  "pr merge"*) echo MERGED >"$FX/merged" ;;
  "pr view"*) if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}'
    else jq -n --arg h "$HEAD" --arg s "$(cat "$FX/view-state" 2>/dev/null || echo OPEN)" '{state: $s, isDraft: false,
      isCrossRepository: false, headRefOid: $h, author: {login: "me"}, mergeable: "MERGEABLE", autoMergeRequest: null}'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

pm() { run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 1 --head abcdef0 "$@"; }
merges() { grep -c '^pr merge' "$FX/calls" || true; }

@test "--method merge is passed to the merge, still bound to the full head" {
  pm --method merge
  [ "$status" -eq 0 ]
  grep -q "^pr merge 1 --repo o/r --merge --match-head-commit $HEAD$" "$FX/calls"
  grep -q 'method=merge' "$STATE/merges.log"
}

@test "no readiness row, or a row for another head, is refused with exit 7 and nothing merged" {
  echo 1111111111111111111111111111111111111111 >"$FX/list-head"
  pm
  [ "$status" -eq 7 ]
  [ "$output" = "refused: readiness row is for head 111111111, not abcdef012" ]
  grep -q $'\trefused: readiness row is for head 111111111' "$STATE/merges.log"
  rm "$FX/list-head"
  touch "$FX/list-forbidden"
  pm
  [ "$status" -eq 7 ]
  [ "$output" = "refused: no readiness row for PR 1" ]
  [ "$(merges)" -eq 0 ]
}

@test "direct mode without --evidence refuses when the head's checks cannot be read (exit 6)" {
  touch "$FX/list-forbidden"
  ORCHESTRATE_DIRECT_MERGE=1 pm
  [ "$status" -eq 6 ]
  [ "$output" = "refused: the head's checks could not be read; a merge past them needs --evidence" ]
  grep -q 'refused: check state unreadable and no --evidence' "$STATE/merges.log"
  [ "$(merges)" -eq 0 ]
  # With evidence the unreadable check state is not consulted.
  ORCHESTRATE_DIRECT_MERGE=1 pm --evidence "owner: ship it"
  [ "$status" -eq 0 ]
}

@test "an unreadable review state, or an unknown policy, is exit 9 and nothing is attempted" {
  mkdir -p "$STATE"
  echo review-at-head >"$STATE/review-policy"
  touch "$FX/reviews-fail"
  pm
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: review state of PR 1 unreadable; nothing was attempted" ]
  grep -q 'refused: review state unreadable: unverified: reviews of PR 1 could not be read' "$STATE/merges.log"
  echo sometimes >"$STATE/review-policy"
  pm
  [ "$status" -eq 9 ]
  [ "$(merges)" -eq 0 ]
  [ ! -f "$STATE/ops/merge-pr1.json" ]
}

@test "merge-sensitive: unreadable PR files or an unverifiable check refuse with exit 9 and release the lock" {
  export ORCHESTRATE_MERGE_SENSITIVE=gradle/libs.versions.toml
  touch "$FX/files-fail"
  pm
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: the files of PR 1 could not be read; nothing was attempted" ]
  rm "$FX/files-fail"
  touch "$FX/base-fail"
  pm
  [ "$status" -eq 9 ]
  [ "$output" = "unverified: the base branch of PR 1 could not be read; nothing was attempted" ]
  [ -z "$(ls -A "$STATE/locks" 2>/dev/null)" ]
  [ "$(merges)" -eq 0 ]
}

@test "merge-sensitive: every touched pattern is locked for the merge, then released" {
  export ORCHESTRATE_MERGE_SENSITIVE='gradle/libs.versions.toml,src/'
  pm
  [ "$status" -eq 0 ]
  grep -q 'sensitive clear: PR 1 touches gradle/libs.versions.toml,src/ and its head contains main' "$STATE/merges.log"
  [ "$(merges)" -eq 1 ]
  [ -z "$(ls -A "$STATE/locks")" ]
}

@test "an unfinished journal for a PR that is no longer open is superseded, then the PR is ineligible" {
  mkdir -p "$STATE/ops"
  jq -cn --arg h "$HEAD" '{op: "merge", repo: "o/r", pr: 1, head: $h, attempt: "1-1", state: "intent"}' >"$STATE/ops/merge-pr1.json"
  echo CLOSED >"$FX/view-state"
  pm
  [ "$status" -eq 3 ]
  [[ "$output" == "ineligible: "*'"state":"CLOSED"'* ]]
  [ "$(jq -r .state "$STATE/ops/merge-pr1.json")" = superseded ]
  [ "$(merges)" -eq 0 ]
}

# A pr-ready.sh stand-in (ORCHESTRATE_SCRIPTS_DIR) for rows the stubbed gh cannot produce: it prints
# $FX/gated-row for a call with --ignore-check and $FX/raw-row for one without (the probe's call).
stub_ready() {
  mkdir -p "$BATS_TEST_TMPDIR/scripts"
  cat >"$BATS_TEST_TMPDIR/scripts/pr-ready.sh" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" --ignore-check "*) cat "$FX/gated-row" ;; *) cat "$FX/raw-row" ;; esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/scripts/pr-ready.sh"
  export ORCHESTRATE_SCRIPTS_DIR="$BATS_TEST_TMPDIR/scripts"
  printf '1\tREADY\tabcdef012\tMERGEABLE\t1\t-\n' >"$FX/gated-row"
}

@test "an advisory check still pending on the head needs --evidence (#428)" {
  echo '[{"name": "sim", "status": "IN_PROGRESS"}]' >"$FX/rollup"
  pm --ignore-check sim
  [ "$status" -eq 6 ]
  [ "$output" = "refused: sim pending on this head; merging before it reports needs --evidence (or wait for it)" ]
  grep -q $'\trefused: pending on the head without --evidence: sim' "$STATE/merges.log"
  [ "$(merges)" -eq 0 ]
}

@test "an advisory check that is required but absent on the head needs --evidence (#428)" {
  echo '[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "sim"}]}}]' >"$FX/rules"
  pm --ignore-check sim
  [ "$status" -eq 6 ]
  [ "$output" = "refused: required sim missing on this head; merging without it needs --evidence" ]
  grep -q $'\trefused: missing on the head without --evidence: sim' "$STATE/merges.log"
  [ "$(merges)" -eq 0 ]
}

@test "an unreadable or unproven check state in the probe's row needs --evidence (#428)" {
  stub_ready
  printf '1\tBLOCK\tabcdef012\tUNKNOWN\t0\tchecks=unknown\n' >"$FX/raw-row"
  pm --ignore-check sim
  [ "$status" -eq 6 ]
  [ "$output" = "refused: the head's checks could not be read (checks=unknown); a merge past them needs --evidence" ]
  grep -q $'\trefused: check state unreadable and no --evidence: checks=unknown' "$STATE/merges.log"
  # A SKIP row proves nothing about checks unless it is ready-but-skipped; an unknown token or
  # verdict fails closed.
  printf '1\tSKIP\tabcdef012\tMERGEABLE\t1\tlabel:hold\n' >"$FX/raw-row"
  pm --ignore-check sim
  [ "$status" -eq 6 ]
  [ "$output" = "refused: the head's checks are not proven passing (SKIP label:hold); a merge past them needs --evidence" ]
  printf '1\tBLOCK\tabcdef012\tMERGEABLE\t1\tnew-token=1\n' >"$FX/raw-row"
  pm --ignore-check sim
  [ "$status" -eq 6 ]
  [ "$output" = "refused: the head's checks are not proven passing (new-token=1); a merge past them needs --evidence" ]
  printf '1\tLATER\tabcdef012\tMERGEABLE\t1\t-\n' >"$FX/raw-row"
  pm --ignore-check sim
  [ "$status" -eq 6 ]
  [ "$output" = "refused: the head's checks are not proven passing (verdict LATER); a merge past them needs --evidence" ]
  [ "$(merges)" -eq 0 ]
  printf '1\tSKIP\tabcdef012\tMERGEABLE\t1\tlabel:hold ready-but-skipped\n' >"$FX/raw-row"
  pm --ignore-check sim
  [ "$status" -eq 0 ]
}

@test "direct mode: only a failing check needs --evidence; pending or unread checks do not (pin)" {
  stub_ready
  for row in 'WAIT\tabcdef012\tMERGEABLE\t0\tpending:build' 'BLOCK\tabcdef012\tUNKNOWN\t0\tchecks=unknown' \
             'SKIP\tabcdef012\tMERGEABLE\t1\tlabel:hold'; do
    printf "1\t$row\n" >"$FX/raw-row"
    ORCHESTRATE_DIRECT_MERGE=1 pm
    [ "$status" -eq 0 ]
    rm "$FX/merged"
  done
  printf '1\tBLOCK\tabcdef012\tMERGEABLE\t1\tfail:build\n' >"$FX/raw-row"
  ORCHESTRATE_DIRECT_MERGE=1 pm
  [ "$status" -eq 6 ]
  [[ "$output" == "refused: build failing on this head"* ]]
}

@test "direct mode: a raw row blocked only by non-check reasons still merges without --evidence (pin)" {
  stub_ready
  printf '1\tBLOCK\tabcdef012\tCONFLICTING\t1\tconflict\n' >"$FX/raw-row"
  ORCHESTRATE_DIRECT_MERGE=1 pm
  [ "$status" -eq 0 ]
  [ "$(merges)" -eq 1 ]
}

@test "an advisory check that passes merges without --evidence, and --evidence skips the probe (pin)" {
  echo '[{"name": "sim", "conclusion": "SUCCESS"}]' >"$FX/rollup"
  pm --ignore-check sim
  [ "$status" -eq 0 ]
  [ "$(merges)" -eq 1 ]
  rm "$FX/merged"
  echo '[{"name": "sim", "status": "IN_PROGRESS"}]' >"$FX/rollup"
  pm --ignore-check sim --evidence "sim: owner waived the pending run"
  [ "$status" -eq 0 ]
  grep -q 'evidence=sim: owner waived the pending run' "$STATE/merges.log"
  [ "$(merges)" -eq 2 ]
}
