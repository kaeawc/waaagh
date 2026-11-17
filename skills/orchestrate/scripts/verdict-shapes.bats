#!/usr/bin/env bats
# issue-candidates.sh sweep recognises every markdown shape of a device verdict line (#282).
# Run: bats verdict-shapes.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
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
  printf '[{"number":90,"title":"Fix","mergedAt":"2026-09-26T00:00:00Z","body":"","closingIssuesReferences":[{"number":1}]}]' >"$FX/prs.json"
  git init -q "$BATS_TEST_TMPDIR/repo"
}

# bucket_for BODY: the sweep bucket of a fixed issue whose only comment is BODY
bucket_for() {
  jq -n --arg b "$1" '[{number: 1, title: "t", labels: [{name: "needs-local:android-emulator"}],
    comments: [{body: $b, createdAt: "2026-09-27T10:00:00Z"}]}]' >"$FX/issues.json"
  run "$SCRIPTS/issue-candidates.sh" sweep --repo o/r --checkout "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | awk -F'\t' '$2 == 1 {print $1}'
}

@test "PASS verdicts in plain and bold/italic shapes all close the issue" {
  [ "$(bucket_for 'Device verification: PASS on android')" = A ]
  [ "$(bucket_for '**Device verification:** PASS on android')" = A ]
  [ "$(bucket_for '**Device verification: PASS** on android')" = A ]
  [ "$(bucket_for '_Device verification_: pass on android')" = A ]
  [ "$(bucket_for '> **Device evidence:**   PASS on android')" = A ]
}

@test "FAIL verdicts in plain and bold/italic shapes all keep the issue open" {
  [ "$(bucket_for 'Device verification: FAIL on android')" = C ]
  [ "$(bucket_for '**Device verification:** FAIL on android')" = C ]
  [ "$(bucket_for '**Device verification: FAIL** on android')" = C ]
  [ "$(bucket_for '_Device verification_: fail on android')" = C ]
}
