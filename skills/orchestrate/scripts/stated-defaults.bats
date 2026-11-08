#!/usr/bin/env bats
# Stated defaults instead of blocking owner questions (#107): decision.sh default records the
# question with the default taken, defaults lists them for the report, batch offers them, record
# ticks them; and the doctrine says when a blocking question is allowed.

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  DOC="$ROOT/skills/orchestrate"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # default and defaults are local: any gh call is a failure.
  printf '#!/bin/sh\necho "gh $*" >>"%s/gh-calls"\nexit 99\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1794096000 # 2026-11-08T00:00:00Z
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
}

@test "default appends the question with the default taken, logs it, and calls no gh" {
  run "$SCRIPTS/decision.sh" default --repo o/r --issue 12 --question "pause merging while runners stall?" --default "keep merging"
  [ "$status" -eq 0 ]
  [[ "$output" == *"taking default: #12 pause merging while runners stall? → keep merging"* ]]
  [ "$(cat "$STATE/decisions.md")" = "- [ ] #12 pause merging while runners stall? — default taken (2026-11-08): keep merging — recommend: keep merging — overridable" ]
  [[ "$(cat "$STATE/decisions.log")" == *$'\tdefault\tissue=12\tpause merging while runners stall?\tkeep merging' ]]
  [ ! -e "$BATS_TEST_TMPDIR/gh-calls" ]
}

@test "default is idempotent for an open question and works without an issue" {
  "$SCRIPTS/decision.sh" default --repo o/r --question "keep the codex route?" --default yes
  run "$SCRIPTS/decision.sh" default --repo o/r --question "keep the codex route?" --default yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already recorded"* ]]
  [ "$(grep -c 'keep the codex route' "$STATE/decisions.md")" -eq 1 ]
  [[ "$(cat "$STATE/decisions.md")" == "- [ ] keep the codex route? — default taken (2026-11-08): yes —"* ]]
}

@test "default refuses missing fields, a bad issue and an em-dash separator" {
  run "$SCRIPTS/decision.sh" default --repo o/r --question "q?"
  [ "$status" -eq 2 ]
  run "$SCRIPTS/decision.sh" default --repo o/r --default d
  [ "$status" -eq 2 ]
  run "$SCRIPTS/decision.sh" default --repo o/r --issue x --question q --default d
  [ "$status" -eq 2 ]
  run "$SCRIPTS/decision.sh" default --repo o/r --question "a — b" --default d
  [ "$status" -eq 2 ]
  [ ! -e "$STATE/decisions.md" ]
}

@test "defaults lists open stated defaults only; batch offers them as recommendations" {
  run "$SCRIPTS/decision.sh" defaults --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "no stated defaults" ]
  mkdir -p "$STATE"
  cat >"$STATE/decisions.md" <<'EOF'
- [ ] #3 split the parser? — split / keep — recommend: split — blocks #4
- [x] #5 old one? — default taken (2026-11-01): yes — recommend: yes — overridable
EOF
  "$SCRIPTS/decision.sh" default --repo o/r --issue 12 --question "pause merging?" --default "keep merging"
  run "$SCRIPTS/decision.sh" defaults --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "- #12 pause merging? → keep merging (taken 2026-11-08)" ]
  run "$SCRIPTS/decision.sh" batch --repo o/r
  [[ "$output" == *"2 decisions are pending"* ]]
  [[ "$output" == *"#12 pause merging? → keep merging"* ]]
}

@test "doctrine: stated defaults over blocking questions, one at a time, loops cover the wait" {
  od="$DOC/owner-decisions.md"
  [[ "$(cat "$od")" == *"## Stated defaults, not blocking questions"* ]]
  [[ "$(cat "$od")" == *'decision.sh" default'* ]]
  [[ "$(cat "$od")" == *"at most one at a time"* ]]
  [[ "$(cat "$od")" == *'loops.sh" status'* ]]
  [[ "$(cat "$od")" == *"overnight"* ]]
  [[ "$(cat "$od")" == *"session cron fires only while the REPL is idle"* ]]
  [[ "$(cat "$DOC/SKILL.md")" == *"Never block on a question with a safe default"* ]]
  [[ "$(cat "$DOC/SKILL.md")" == *"decision.sh default"* ]]
  [[ "$(cat "$DOC/reporting.md")" == *"decision.sh defaults"* ]]
  [[ "$(cat "$ROOT/README.md")" == *'`defaults` lists those for the report'* ]]
}
