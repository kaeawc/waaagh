#!/usr/bin/env bats
# .github/workflows/lint.yml (#372): actionlint, pinned and checksum-checked, over the workflows and
# the shipped template, with shellcheck on the run: blocks.

setup() {
  load test_helper
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  WF="$ROOT/.github/workflows/lint.yml"
}

@test "lint runs actionlint over every workflow and the workflow templates" {
  grep -qF 'actionlint -color .github/workflows/*.yml skills/orchestrate/templates/*.yml' "$WF"
  grep -qF 'run: shellcheck --version' "$WF"   # no shellcheck on the runner would silently skip the run: checks
}

@test "lint downloads a pinned actionlint and verifies its sha256" {
  grep -qE '^ +ACTIONLINT_VERSION: [0-9]+\.[0-9]+\.[0-9]+$' "$WF"
  grep -qE '^ +ACTIONLINT_SHA256: [0-9a-f]{64}$' "$WF"
  grep -qF 'sha256sum -c -' "$WF"
}

@test "lint has read-only permissions, a timeout and every action pinned to a commit" {
  grep -qx '  contents: read' "$WF"
  grep -qE '^    timeout-minutes: [0-9]+$' "$WF"
  grep -qE '^on:' "$WF"
  ! grep -E '^\s*-?\s*uses:' "$WF" | grep -vE '@[0-9a-f]{40} # v[0-9]'
}

@test "every workflow in the repository pins its actions to a commit with a version comment" {
  for f in "$ROOT"/.github/workflows/*.yml; do
    bad=$(grep -E '^\s*-?\s*uses:' "$f" | grep -cvE '(@[0-9a-f]{40} # v[0-9]|uses: \./)' || true)
    [ "$bad" -eq 0 ] || { echo "unpinned action in $f"; return 1; }
  done
}
