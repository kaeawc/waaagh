#!/usr/bin/env bats
# The device-to-cloud handoff (#89): cloud-dispatch.sh fixtures / payload refuse a cloud-ready
# issue whose captured fixtures stay on the local host, and the brief names the fixtures exactly.
# gh is stubbed: issue, comments and timeline JSON come from $FX. Run: bats cloud-fixtures.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FX"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
f=""
case "$*" in
  "api repos/o/r/issues/"*"/comments?per_page=100"*) f=comments ;;
  "api repos/o/r/issues/"*"/timeline?per_page=100"*) f=timeline ;;
  "api repos/o/r/issues/"*) f=issue ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
[ -f "$FX/$f.json" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
cat "$FX/$f.json"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_JITTER=0
  ST="$ORCHESTRATE_STATE_DIR/o__r"
  echo '[]' >"$FX/comments.json"
  echo '[]' >"$FX/timeline.json"
}
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r --no-blocker-check; }   # blockers: cloud-blockers.bats
issue() { # issue BODY [LABEL]
  jq -n --arg b "$1" --arg l "${2:-}" '{number: 7, html_url: "https://github.com/o/r/issues/7", body: $b,
    labels: (if $l == "" then [] else [{name: $l}] end)}' >"$FX/issue.json"
}
comment() { # comment ID BODY (appended)
  jq --arg id "$1" --arg b "$2" '. + [{id: ($id | tonumber), body: $b,
    html_url: ("https://github.com/o/r/issues/7#issuecomment-" + $id)}]' "$FX/comments.json" >"$FX/c.tmp"
  mv "$FX/c.tmp" "$FX/comments.json"
}
has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }

@test "an issue that never mentions fixtures needs none, and the timeline is not read" {
  issue "Rename the flag --foo to --bar in the CLI."
  run cd_ fixtures --issue 7
  [ "$status" -eq 0 ]
  [ "$output" = "fixtures none" ]
  ! grep -q timeline "$FX/calls"
}

@test "captured fixtures behind only a local path and an excerpt are refused (exit 5)" {
  issue 'Parse the Smart Stack XCUI dump. Excerpt: `<Other id="x">`. Full captured dumps in ~/.claude/orchestrate/o__r/evidence-l16833c/dump.txt'
  run cd_ fixtures --issue 7
  [ "$status" -eq 5 ]
  [[ "$output" == *"#7 needs captured fixtures but none travel with it"* ]]
  [[ "$output" == *"only a local path: ~/.claude/orchestrate/o__r/evidence-l16833c/dump.txt"* ]]
  [[ "$output" == *"Route it back to the lane"* ]]
}

@test "a <details> fixtures comment satisfies the check and is named by URL" {
  issue "Parser for the captured XCUI dumps; fixtures in the comments."
  comment 11 "Looks good."
  comment 12 $'Fixtures for #7:\n<details><summary>fixtures/stack.xml</summary>\n\n```xml\n<a/>\n```\n</details>'
  run cd_ fixtures --issue 7
  [ "$status" -eq 0 ]
  [ "$output" = "fixtures https://github.com/o/r/issues/7#issuecomment-12" ]
  ! grep -q timeline "$FX/calls"
}

@test "a <details> block in the body itself counts" {
  issue $'Captured on watchOS 11:\n<details><summary>fixtures/a.txt</summary>\n\nraw\n</details>'
  run cd_ fixtures --issue 7
  [ "$output" = "fixtures https://github.com/o/r/issues/7" ]
}

@test "a linked open or merged fixtures-only PR counts; a closed unmerged one does not" {
  issue "Parser for the captured dumps."
  jq -n '[{event: "cross-referenced", source: {issue: {html_url: "https://github.com/o/r/pull/30",
      title: "Add XCUI fixtures for #7", state: "closed", pull_request: {merged_at: null}}}},
    {event: "cross-referenced", source: {issue: {html_url: "https://github.com/o/r/issues/31",
      title: "fixtures tracking", state: "open"}}},
    {event: "labeled"}]' >"$FX/timeline.json"
  run cd_ fixtures --issue 7
  [ "$status" -eq 5 ]
  jq -n '[{event: "cross-referenced", source: {issue: {html_url: "https://github.com/o/r/pull/32",
      title: "Smart Stack fixtures", state: "closed", pull_request: {merged_at: "2026-11-08T00:00:00Z"}}}}]' >"$FX/timeline.json"
  run cd_ fixtures --issue 7
  [ "$status" -eq 0 ]
  [ "$output" = "fixtures https://github.com/o/r/pull/32" ]
}

@test "the needs-fixtures label and --require demand fixtures without any mention" {
  issue "Write the parser." needs-fixtures
  run cd_ fixtures --issue 7
  [ "$status" -eq 5 ]
  issue "Write the parser."
  run cd_ fixtures --issue 7 --require
  [ "$status" -eq 5 ]
  run cd_ fixtures --issue 7
  [ "$output" = "fixtures none" ]
}

@test "an unreadable issue is exit 7, never a dispatch" {
  rm -f "$FX/issue.json"
  run cd_ fixtures --issue 7
  [ "$status" -eq 7 ]
  [[ "$output" == *"could not be read; do not dispatch"* ]]
}

@test "payload runs the check: refuses without fixtures, and the brief names them when present" {
  issue "Parser; captured dumps at /Users/me/evidence-1/d.txt"
  run cd_ payload --issue 7 --env env_1 --source u --base main
  [ "$status" -eq 5 ]
  [ ! -s "$ST/cloud-sessions.tsv" ]
  comment 40 $'<details><summary>fixtures/d.txt</summary>\n\nraw\n</details>'
  run cd_ payload --issue 7 --env env_1 --source u --base main
  [ "$status" -eq 0 ]
  msg=$(jq -r '.job_config.ccr.events[0].data.message' <<<"$output")
  [[ "$msg" == *"Implement the issue, with tests. Commit the captured fixtures from https://github.com/o/r/issues/7#issuecomment-40 verbatim; never hand-write, trim or regenerate them."* ]]
  [[ "$msg" != *'{{'* ]]
  [ "${#msg}" -lt 1500 ]
}

@test "brief: --fixtures none adds nothing; an override template without the placeholder gets a line" {
  run cd_ brief --issue 7 --base main --fixtures none
  [[ "$output" == *"Implement the issue, with tests."$'\n'* ]]
  [[ "$output" != *"Commit the captured fixtures"* ]]
  mkdir -p "$ST"
  printf 'Fix {{REPO}}#{{ISSUE}}.\n' >"$ST/cloud-brief.md"
  run cd_ brief --issue 7 --base main --fixtures "https://x/1 https://x/2"
  [ "$output" = "$(printf 'Fix o/r#7.\nCommit the captured fixtures from https://x/1 https://x/2 verbatim; never hand-write, trim or regenerate them.')" ]
  ! [ -s "$FX/calls" ]
}

@test "queue drop takes an issue routed back out of the queue" {
  cd_ queue add 7 8 9
  run cd_ queue drop 8 12
  [ "$status" -eq 0 ]
  [ "$output" = "dropped 8" ]
  run cd_ queue list
  [ "$output" = "$(printf '7\n9')" ]
  run cd_ queue add 8
  [ "$output" = "queued 8" ]
}

@test "handoff doctrine: local side attaches, dispatcher checks, brief names the comment (#89)" {
  D="$ROOT/skills/orchestrate/device-cloud-handoff.md"
  has "$D" "A local path is never enough"
  has "$D" "<details>"
  has "$D" "fixtures-only PR"
  has "$D" "sha256"
  has "$D" "Exit 5, refused"
  has "$D" "queue drop N"
  has "$D" "verbatim"
  has "$ROOT/skills/orchestrate/roles/cloud-dispatch.md" "device-cloud-handoff.md"
  has "$ROOT/skills/orchestrate/roles/cloud-session-brief.md" "{{FIXTURES}}"
  has "$ROOT/skills/orchestrate/roles/verification.md" "device-cloud-handoff.md"
  has "$ROOT/skills/orchestrate/roles/verify-batch.md" "device-cloud-handoff.md"
  has "$ROOT/skills/orchestrate/roles/implementation-lane.md" "device-cloud-handoff.md"
  has "$ROOT/skills/orchestrate/roles/router.md" "device-cloud-handoff.md"
  has "$ROOT/skills/orchestrate/SKILL.md" "device-cloud-handoff.md"
}
