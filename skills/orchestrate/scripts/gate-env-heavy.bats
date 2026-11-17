#!/usr/bin/env bats
# gate-slot.sh resolves the per-repo gate environment (--env-file, ORCHESTRATE_GATE_ENV, or
# <state dir>/<owner>__<repo>/gate-env.sh) before routing heavy builds, so Gradle/Xcode see it too (#288).
# Run: bats gate-env-heavy.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR BIN="$BATS_TEST_TMPDIR/bin"
  export ORCHESTRATE_SLOT_DIR="$T/slots" SLOT_POLL=0.05 ORCHESTRATE_BUILD_ROOT="$T/build" \
    ORCHESTRATE_STATE_DIR="$T/state"
  unset ORCHESTRATE_GATE_ENV GATE_ONLY_VAR
  mkdir -p "$BIN" "$T/state/acme__widget"
  git init -q "$T/co"; git -C "$T/co" remote add origin git@github.com:acme/widget.git
  cd "$T/co"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "GATE_ONLY_VAR=%s\n" "${GATE_ONLY_VAR:-}"' >"$BIN/gradlew"
  chmod +x "$BIN/gradlew"
  printf 'export GATE_ONLY_VAR=from-gate-env\n' >"$T/state/acme__widget/gate-env.sh"
  export PATH="$BIN:$PATH"
}

@test "a Gradle command sees a variable set only in the per-repo gate-env.sh" {
  run "$SCRIPTS/gate-slot.sh" -- gradlew test
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE_ONLY_VAR=from-gate-env"* ]]
}

@test "a Gradle command honours ORCHESTRATE_GATE_ENV" {
  printf 'export GATE_ONLY_VAR=from-env-var\n' >"$T/other-env.sh"
  ORCHESTRATE_GATE_ENV="$T/other-env.sh" run "$SCRIPTS/gate-slot.sh" -- gradlew test
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE_ONLY_VAR=from-env-var"* ]]
}

@test "an explicit --env-file wins for a Gradle command" {
  printf 'export GATE_ONLY_VAR=explicit\n' >"$T/explicit.sh"
  run "$SCRIPTS/gate-slot.sh" --env-file "$T/explicit.sh" -- gradlew test
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE_ONLY_VAR=explicit"* ]]
}

@test "a Gradle command with no gate env still runs" {
  rm "$T/state/acme__widget/gate-env.sh"
  run "$SCRIPTS/gate-slot.sh" -- gradlew test
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATE_ONLY_VAR="* ]]
  [[ "$output" != *"from-gate-env"* ]]
}
