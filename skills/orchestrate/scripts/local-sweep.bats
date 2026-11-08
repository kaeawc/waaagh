#!/usr/bin/env bats
# issue-candidates.sh sweep (the A/B/C/D buckets for needs-local issues) against a stubbed gh and a
# fixture git history, plus the local-sweep / verify-batch doctrine contract.
# Run: bats local-sweep.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/nogit"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  # `issue list --label L` serves the issues in $FX/issues.json carrying L; without --label, every
  # issue's number and labels. `pr list` serves $FX/prs.json. LIST_FAIL=1 fails every list.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
[ "${LIST_FAIL:-0}" = 1 ] && { echo "HTTP 404: Not Found" >&2; exit 1; }
label=""; prev=""
for a in "$@"; do [ "$prev" = --label ] && label=$a; prev=$a; done
case "$1 $2" in
  "issue list")
    if [ -n "$label" ]; then jq --arg l "$label" '[.[] | select(any(.labels[]; .name == $l))]' "$FX/issues.json"
    else jq '[.[] | {number, labels}]' "$FX/issues.json"; fi ;;
  "pr list") cat "$FX/prs.json" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo '[]' >"$FX/prs.json"
}

# issue N TITLE LABELS(comma) [COMMENTS-JSON]
issue() {
  local cur; cur=$(cat "$FX/issues.json" 2>/dev/null || echo '[]')
  jq -n --argjson cur "$cur" --argjson n "$1" --arg t "$2" --arg l "$3" --argjson c "${4:-[]}" \
    '$cur + [{number: $n, title: $t, labels: ($l | split(",") | map({name: .})), comments: $c}]' >"$FX/issues.json"
}
comment() { jq -n --arg b "$1" --arg t "${2:-2026-09-27T10:00:00Z}" '{body: $b, createdAt: $t}'; }
row() { printf '%s\n' "$output" | awk -F'\t' -v n="$1" '$2 == n'; }

@test "sweep sorts needs-local issues into A, B, C and D and groups B by platform" {
  ok_android=$(comment "Device verification: PASS on android (Pixel 8 emulator, API 35) at abc1234")
  ok_ios=$(comment "Device verification: PASS on ios (iPhone 16 simulator, iOS 18) at abc1234")
  issue 1 "A: fixed and verified" needs-local:android-emulator "[$ok_android]"
  issue 2 "B: fixed, ios unverified" needs-local:ios-simulator
  issue 3 "B: fixed, android unverified" needs-local:android-emulator
  issue 4 "C: nothing merged" needs-local:android-emulator
  issue 5 "D: only referenced" needs-local:ios-simulator
  issue 6 "D: PASS without a fix" needs-local:ios-simulator "[$ok_ios]"
  issue 7 "two platforms, one verified" "needs-local:android-emulator,needs-local:ios-simulator" "[$ok_android]"
  issue 8 "C: FAIL after the fix" needs-local:android-emulator \
    "[$(comment 'Device verification: FAIL on android: still hangs' 2026-09-27T11:00:00Z)]"
  issue 9 "stale PASS before the fix" needs-local:android-emulator \
    "[$(comment 'Device verification: PASS on android' 2026-09-01T00:00:00Z)]"
  issue 10 "D: research" needs-local:research
  issue 11 "D: loose device note" needs-local:android-emulator \
    "[$(comment 'Verified on the Pixel emulator, works now')]"
  issue 12 "cloud issue, not swept" cloud-ready
  cat >"$FX/prs.json" <<'JSON'
[{"number":90,"title":"Fix tap","mergedAt":"2026-09-26T00:00:00Z","body":"Fixes #1, closes #2","closingIssuesReferences":[{"number":7}]},
 {"number":91,"title":"Part of #5","mergedAt":"2026-09-26T00:00:00Z","body":"","closingIssuesReferences":[]},
 {"number":92,"title":"More","mergedAt":"2026-09-20T00:00:00Z","body":"resolves #8\nfixes #9\nfixes #10\nfixes #11\nfixes #12","closingIssuesReferences":[]}]
JSON
  git init -q "$BATS_TEST_TMPDIR/repo"
  GIT_COMMITTER_DATE=2026-09-25T00:00:00Z git -C "$BATS_TEST_TMPDIR/repo" commit -q --allow-empty \
    -m "Handle the android back stack" -m "Fixes #3"
  run "$SCRIPTS/issue-candidates.sh" sweep --repo o/r --checkout "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [[ "$(row 1)" == $'A\t1\tandroid\t#90\tandroid:PASS\t'* ]]
  [[ "$(row 2)" == $'B\t2\tios\t#90\tios:-\tfix merged; verify on ios\t'* ]]
  [ "$(row 3 | cut -f1,4)" = "B	$(git -C "$BATS_TEST_TMPDIR/repo" log -1 --format=%h)" ]
  [[ "$(row 4)" == $'C\t4\tandroid\t-\tandroid:-\tno merged fix\t'* ]]
  [ "$(row 5 | cut -f1,4,6)" = $'D\t#91\tmentioned without a closing keyword' ]
  [ "$(row 6 | cut -f1,6)" = $'D\tdevice PASS without a merged fix' ]
  [ "$(row 7 | cut -f1,3,5,6)" = $'B\tandroid,ios\tandroid:PASS,ios:-\tfix merged; verify on ios' ]
  [ "$(row 8 | cut -f1,5,6)" = $'C\tandroid:FAIL\tdevice FAIL after the fix' ]
  [ "$(row 9 | cut -f1,5)" = $'B\tandroid:-' ]
  [ "$(row 10 | cut -f1,6)" = $'D\tresearch route: confirm the measurement' ]
  [ "$(row 11 | cut -f1,6)" = $'D\tunstructured device evidence: confirm' ]
  [ -z "$(row 12)" ]
  # Sorted by bucket, then platforms: the B rows for one platform are adjacent.
  [ "$(printf '%s\n' "$output" | grep -v '^# ' | cut -f1,2 | tr '\t\n' ': ')" = "A:1 B:3 B:9 B:7 B:2 C:4 C:8 D:11 D:5 D:6 D:10 " ]
  [[ "$output" == *"# A=1 B=4 C=2 D=4; shown 11 of 11 in A,B,C,D; git: HEAD; all: $ORCHESTRATE_STATE_DIR/o__r/candidates/sweep-"*.tsv ]]
  full=$(printf '%s\n' "$output" | sed -n 's/^# .*; all: //p')
  [ "$(wc -l <"$full" | tr -d ' ')" = 11 ]
  # One list call per route label in use, plus the label scan; the merged-PR window is 180 days.
  [ "$(grep -c -- '--label needs-local:' "$FX/calls")" = 3 ]
  grep -q 'merged:>=2026-03-31' "$FX/calls"
}

@test "sweep filters buckets, caps rows and works without git history" {
  issue 1 "fixed" needs-local:android-emulator
  issue 2 "fixed too" needs-local:android-emulator
  issue 3 "open" needs-local:macos-xcode
  echo '[{"number":90,"title":"x","mergedAt":"2026-09-26T00:00:00Z","body":"Fixes #1\nFixes #2","closingIssuesReferences":[]}]' >"$FX/prs.json"
  cd "$BATS_TEST_TMPDIR/nogit"
  run "$SCRIPTS/issue-candidates.sh" sweep --repo o/r --checkout "$BATS_TEST_TMPDIR/nogit" --bucket B --limit 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -vc '^# ')" = 1 ]
  [[ "$output" == *$'B\t1\tandroid\t#90\t'* ]]
  [[ "$output" == *"# A=0 B=2 C=1 D=0; shown 1 of 2 in B; git: none; all: "* ]]
  run "$SCRIPTS/issue-candidates.sh" sweep --repo o/r --checkout "$BATS_TEST_TMPDIR/nogit" --route needs-local:macos-xcode
  [[ "$output" == $'C\t3\tmacos\t-\tmacos:-\tno merged fix\topen\n# A=0 B=0 C=1 D=0;'* ]]
}

@test "sweep exits 4 when issues cannot be read, and 2 on a bad command" {
  issue 1 "x" needs-local:android-emulator
  LIST_FAIL=1 run "$SCRIPTS/issue-candidates.sh" sweep --repo o/r --checkout "$BATS_TEST_TMPDIR/nogit"
  [ "$status" -eq 4 ]
  run "$SCRIPTS/issue-candidates.sh" bogus --repo o/r
  [ "$status" -eq 2 ]
  [[ "$output" == *"issue-candidates.sh sweep"* ]]
  [[ "$output" != *"set -euo pipefail"* ]]
  run "$SCRIPTS/issue-candidates.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exit: 0 ok | 2 usage | 4 issues or merged PRs could not be read"* ]]
}

@test "local-sweep and verify-batch roles are indexed and wired into the doctrine" {
  for role in local-sweep verify-batch; do
    [ -f "$ROOT/skills/orchestrate/roles/$role.md" ]
    grep -q "\`$role.md\`" "$ROOT/skills/orchestrate/roles/README.md"
    grep -q "$role" "$ROOT/skills/orchestrate/SKILL.md"
  done
  grep -q 'issue-candidates.sh sweep' "$ROOT/skills/orchestrate/roles/local-sweep.md"
  grep -q 'Device verification: PASS' "$ROOT/skills/orchestrate/roles/verify-batch.md"
  grep -qF 'issue-candidates.sh" sweep' "$ROOT/skills/orchestrate/routing.md"
  grep -q 'sweep' "$ROOT/README.md"
}
