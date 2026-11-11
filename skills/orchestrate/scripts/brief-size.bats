#!/usr/bin/env bats
# What the cloud brief size caps protect (#239). The only size limit that applies to dispatch is on
# the cloud session's first message, the create payload's events[0].data.message: Anthropic
# documents 65,536 characters for a routine run's text (POST /v1/claude_code/routines/{id}/fire,
# "Maximum 65,536 characters"); the create call documents no lower one. So the message is measured
# as cloud-dispatch.sh payload renders it, held to half that limit. A repository brief
# (.claude/briefs/K.md) never travels in the payload: --brief-ref sends one line and the session
# reads the file from its checkout, so the brief has no transport limit. Its cap is a readability
# budget (every session reads it whole), measured on the installed file, with room for new rules.
# See ../briefs/README.md, "Size". Run: bats brief-size.bats

MESSAGE_LIMIT=65536             # characters, the documented cap on a routine run's text
MESSAGE_CAP=$((MESSAGE_LIMIT / 2)) # bytes (never fewer than characters): 2x headroom
PROMPT_CAP=512                  # the --brief-ref one-line prompt, fixtures named
BRIEF_CAP=4096                  # an installed .claude/briefs/K.md

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FX"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "unexpected gh call: $*" >&2
exit 9
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_JITTER=0
  # Long but realistic values, so the measure covers what a real repository fills in.
  GATES="shellcheck -S warning -x scripts/*.sh, bats tests/*.bats, npm run lint, npm test -- --ci, cargo test --workspace, ./gradlew check"
  FIXTURES="https://github.com/o/r/issues/5#issuecomment-1234567890 https://github.com/o/r/pull/123456"
}
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r --no-blocker-check; }
message() { jq -r '.job_config.ccr.events[0].data.message' <<<"$1"; }

@test "the rendered inline brief, the payload's first message, stays under half the documented limit" {
  run cd_ payload --issue 123456 --env env_1 --source u --base main --gates "$GATES" --fixtures "$FIXTURES"
  [ "$status" -eq 0 ]
  msg=$(message "$output")
  [[ "$msg" == *"$GATES"* ]]
  bytes=$(printf '%s' "$msg" | wc -c)
  echo "inline message: $bytes bytes, cap $MESSAGE_CAP (limit $MESSAGE_LIMIT characters)"
  [ "$bytes" -lt "$MESSAGE_CAP" ]
}

@test "the --brief-ref prompt is one line, under its own cap, for both kinds" {
  for k in implement repair; do
    run cd_ payload --issue 123456 --pr 654321 --env env_1 --source u --base main --fixtures "$FIXTURES" --brief-ref "$k"
    [ "$status" -eq 0 ]
    msg=$(message "$output")
    [[ "$msg" == "Follow .claude/briefs/$k.md "*"(commit verbatim)." ]]
    [ "$(printf '%s\n' "$msg" | wc -l)" -eq 1 ]
    bytes=$(printf '%s' "$msg" | wc -c)
    echo "$k prompt: $bytes bytes, cap $PROMPT_CAP"
    [ "$bytes" -lt "$PROMPT_CAP" ]
  done
}

@test "an installed brief stays under the readability cap, with room for a new rule" {
  CO="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$CO"
  run cd_ briefs install --dir "$CO" --base main --gates "$GATES"
  [ "$status" -eq 0 ]
  for k in implement repair; do
    bytes=$(wc -c <"$CO/.claude/briefs/$k.md")
    echo "$k brief: $bytes bytes installed, cap $BRIEF_CAP"
    # 400 bytes is a short rule or two: adding one must not force rewording other steps (#239).
    [ "$((bytes + 400))" -lt "$BRIEF_CAP" ]
  done
}

@test "doctrine: briefs/README.md names the size caps and their source" {
  R="$SCRIPTS/../briefs/README.md"
  grep -qF "## Size" "$R"
  grep -qF "65,536 characters" "$R"
  grep -qF "brief-size.bats" "$R"
}
