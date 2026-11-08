#!/usr/bin/env bats
# Blocked issues stay out of the candidate lists (#116): issue-candidates.sh sweep --drop-blocked
# moves blocked C rows to a "blocked" bucket, cloud-dispatch.sh payload refuses a blocked issue
# (exit 8; --no-blocker-check allows it) and queue add warns. An unreadable blocker check is
# reported as unverified, never as clear. gh is stubbed. Run: bats blocked-candidates.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/nogit"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_JITTER=0   # 2026-09-27T12:00:00Z
  ST="$ORCHESTRATE_STATE_DIR/o__r"
  # Lists: `issue list [--label L]` from $FX/issues.json, `pr list` from $FX/prs.json.
  # REST: issue N is $FX/issue-N.json (missing: 404; containing "500": a server error), its
  # blocked_by list $FX/deps-N.json (missing: []); comments and timeline are [].
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"; all=${all% --include}
echo "$all" >>"$FX/calls"
label=""; prev=""
for a in "$@"; do [ "$prev" = --label ] && label=$a; prev=$a; done
case "$all" in
  "issue list"*)
    if [ -n "$label" ]; then jq --arg l "$label" '[.[] | select(any(.labels[]; .name == $l))]' "$FX/issues.json"
    else jq '[.[] | {number, labels}]' "$FX/issues.json"; fi ;;
  "pr list"*) cat "$FX/prs.json" ;;
  "api repos/o/r/issues/"*/dependencies/blocked_by*)
    n=${all#api repos/o/r/issues/}; n=${n%%/*}
    if [ -f "$FX/deps-$n.json" ]; then cat "$FX/deps-$n.json"; else echo '[]'; fi ;;
  "api repos/o/r/issues/"*"/comments?per_page=100"* | "api repos/o/r/issues/"*"/timeline?per_page=100"*)
    echo '[]' ;;
  "api repos/o/r/issues/"*)
    n=${all#api repos/o/r/issues/}
    if [ ! -f "$FX/issue-$n.json" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1
    elif grep -qx 500 "$FX/issue-$n.json"; then echo "gh: Server Error (HTTP 500)" >&2; exit 1
    else cat "$FX/issue-$n.json"; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo '[]' >"$FX/prs.json"
}

rest_issue() { # n state [body]
  jq -n --argjson n "$1" --arg s "$2" --arg b "${3:-}" \
    '{number: $n, state: $s, body: $b, html_url: "https://github.com/o/r/issues/\($n)", labels: []}' >"$FX/issue-$1.json"
}
dep() { # n blocker-number blocker-state
  jq -n --argjson b "$2" --arg s "$3" '[{number: $b, state: $s, repository_url: "https://api.github.com/repos/o/r"}]' >"$FX/deps-$1.json"
}
list_issue() { # n title labels(comma)
  local cur; cur=$(cat "$FX/issues.json" 2>/dev/null || echo '[]')
  jq -n --argjson cur "$cur" --argjson n "$1" --arg t "$2" --arg l "$3" \
    '$cur + [{number: $n, title: $t, labels: ($l | split(",") | map({name: .})), comments: []}]' >"$FX/issues.json"
}
row() { printf '%s\n' "$output" | awk -F'\t' -v n="$1" '$2 == n'; }
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r; }
sweep() { "$SCRIPTS/issue-candidates.sh" sweep --repo o/r --checkout "$BATS_TEST_TMPDIR/nogit" "$@"; }

@test "sweep --drop-blocked moves a blocked C row to the blocked bucket; unreadable stays C, unverified" {
  list_issue 4 "C: clear" needs-local:android-emulator
  list_issue 5 "C: blocked natively" needs-local:android-emulator
  list_issue 6 "C: blocked in the body" needs-local:ios-simulator
  list_issue 7 "C: unreadable" needs-local:android-emulator
  list_issue 8 "B: fixed" needs-local:android-emulator
  echo '[{"number":90,"title":"Fix","mergedAt":"2026-09-26T00:00:00Z","body":"Fixes #8","closingIssuesReferences":[]}]' >"$FX/prs.json"
  rest_issue 4 open; rest_issue 5 open; rest_issue 6 open "Blocked by #30"; rest_issue 30 open
  dep 5 21 open
  echo 500 >"$FX/issue-7.json"
  # Without the flag: unchanged rows, no blocker reads.
  run sweep
  [ "$status" -eq 0 ]
  [ "$(row 5 | cut -f1)" = C ]
  if grep -q blocked_by "$FX/calls"; then false; fi   # not run: the next line reads $lines
  [[ "${lines[${#lines[@]}-1]}" == "# A=0 B=1 C=4 D=0; shown 5 of 5 in A,B,C,D;"* ]]
  run sweep --drop-blocked
  [ "$status" -eq 0 ]
  [[ "$(row 4)" == $'C\t4\tandroid\t-\tandroid:-\tno merged fix\t'* ]]
  [ "$(row 5 | cut -f1,6,7)" = $'blocked\tblocked by #21\tC: blocked natively' ]
  [ "$(row 6 | cut -f1,6)" = $'blocked\tblocked by #30' ]
  [ "$(row 7 | cut -f1,6)" = $'C\tno merged fix; blockers unverified (issue)' ]
  [ "$(row 8 | cut -f1)" = B ]
  # Blocked rows come last, after the A-D rows.
  [ "$(printf '%s\n' "$output" | awk -F'\t' '!/^#/ { print $1 }' | tr '\n' ' ')" = "B C C blocked blocked " ]
  last=${lines[${#lines[@]}-1]}
  [[ "$last" == "# A=0 B=1 C=2 D=0 blocked=2 unverified=1; shown 5 of 5 in A,B,C,D,blocked;"* ]]
  full=${last##*all: }
  [ "$(awk -F'\t' '$1 == "blocked"' "$full" | wc -l | tr -d ' ')" = 2 ]
  # The B row is not checked: only C rows cost blocker reads.
  run ! grep -q "issues/8" "$FX/calls"
  # --bucket C leaves the blocked rows out of the shortlist.
  run sweep --drop-blocked --bucket C
  [ "$(printf '%s\n' "$output" | awk -F'\t' '!/^#/ { print $2 }' | tr '\n' ' ')" = "4 7 " ]
}

@test "sweep --drop-blocked: a blocker check that fails outright leaves every C row unverified" {
  list_issue 4 "C" needs-local:android-emulator
  rest_issue 4 open
  printf '#!/usr/bin/env bash\nexit 2\n' >"$BATS_TEST_TMPDIR/ob"
  mkdir -p "$BATS_TEST_TMPDIR/copy"
  cp "$SCRIPTS"/*.sh "$BATS_TEST_TMPDIR/copy/"
  cp "$BATS_TEST_TMPDIR/ob" "$BATS_TEST_TMPDIR/copy/open-blockers.sh"
  chmod +x "$BATS_TEST_TMPDIR/copy/"*.sh
  run "$BATS_TEST_TMPDIR/copy/issue-candidates.sh" sweep --repo o/r --checkout "$BATS_TEST_TMPDIR/nogit" --drop-blocked
  [ "$status" -eq 0 ]
  [[ "$output" == *"open-blockers.sh failed (exit 2); C rows unverified"* ]]
  [ "$(row 4 | cut -f1,6)" = $'C\tno merged fix; blockers unverified (blocker check)' ]
  [[ "$output" == *"blocked=0 unverified=1;"* ]]
}

@test "payload refuses a blocked issue (exit 8), allows it with --no-blocker-check" {
  rest_issue 5 open; dep 5 21 open
  run cd_ payload --issue 5 --env env_1 --source u --base main --fixtures none
  [ "$status" -eq 8 ]
  [[ "$output" == *"#5 BLOCKED by #21: route the blocker first; do not dispatch it"* ]]
  run cd_ payload --issue 5 --env env_1 --source u --base main --fixtures none --no-blocker-check
  [ "$status" -eq 0 ]
  [ "$(jq -r .name <<<"$output")" = "r #5 cloud lane" ]
  # A closed blocker is no blocker.
  dep 5 21 closed
  run cd_ payload --issue 5 --env env_1 --source u --base main --fixtures none
  [ "$status" -eq 0 ]
  # The check runs before the fixtures check: a blocked issue never reads its comments.
  dep 5 21 open; : >"$FX/calls"
  run cd_ payload --issue 5 --env env_1 --source u --base main
  [ "$status" -eq 8 ]
  ! grep -q comments "$FX/calls"
}

@test "payload: an unreadable blocker check is unverified (exit 7), not clear; repair skips it" {
  echo 500 >"$FX/issue-5.json"
  run cd_ payload --issue 5 --env env_1 --source u --base main --fixtures none
  [ "$status" -eq 7 ]
  [[ "$output" == *"#5: blockers unverified (issue); do not dispatch it"* ]]
  rest_issue 5 open "Blocked by #30"   # #30 does not answer at all
  echo 500 >"$FX/issue-30.json"
  run cd_ payload --issue 5 --env env_1 --source u --base main --fixtures none
  [ "$status" -eq 7 ]
  [[ "$output" == *"blockers unverified (#30)"* ]]
  # A repair dispatch (its PR exists) is never refused on blockers.
  run cd_ payload --issue 5 --pr 31 --env env_1 --source u --base main --brief-ref repair
  [ "$status" -eq 0 ]
}

@test "queue add warns about blocked and unverified issues but still queues them" {
  rest_issue 5 open; dep 5 21 open
  rest_issue 6 open
  echo 500 >"$FX/issue-7.json"
  run cd_ queue add 5 6 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"queued 5"*"queued 6"*"queued 7"* ]]
  [[ "$output" == *"warning: #5 BLOCKED by #21"* ]]
  [[ "$output" == *"warning: #7 blockers unverified: issue"* ]]
  [[ "$output" != *"#6 "* ]]
  [ "$(cat "$ST/cloud-queue.txt" | tr '\n' ' ')" = "5 6 7 " ]
  # Already-queued issues are not re-checked; --no-blocker-check skips the reads.
  : >"$FX/calls"
  run cd_ queue add 5 8 --no-blocker-check
  [ "$output" = "queued 8" ]
  [ ! -s "$FX/calls" ]
}

@test "doctrine: the sweep and the cloud dispatcher drop blocked issues (#116)" {
  grep -qF -- "--drop-blocked" "$ROOT/skills/orchestrate/roles/local-sweep.md"
  grep -qF -- "Exit 8" "$ROOT/skills/orchestrate/roles/cloud-dispatch.md"
  grep -qF -- "--no-blocker-check" "$ROOT/skills/orchestrate/roles/cloud-dispatch.md"
}
