#!/usr/bin/env bats
# .github/workflows/coverage.yml: the coverage floors run on PRs that change scripts (#157), still on
# every push to main, and in their own workflow so test.yml's fast check does not wait for them.

setup() {
  load test_helper
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  WF="$ROOT/.github/workflows/coverage.yml"
}

# The lines of the top-level `on:` block.
on_block() { awk '/^on:/ { f = 1; next } f && /^[^ #]/ { exit } f' "$WF"; }

@test "coverage runs on pushes to main and by hand" {
  [[ "$(on_block)" == *$'  push:\n    branches: [main]'* ]]
  [[ "$(on_block)" == *"  workflow_dispatch:"* ]]
}

@test "coverage runs on pull requests that touch scripts, suites, dev/ or the workflow" {
  on=$(on_block)
  [[ "$on" == *$'  pull_request:\n    paths:'* ]]
  for p in "'skills/orchestrate/scripts/**'" "'bin/**'" "'dev/**'" "'.github/workflows/coverage.yml'"; do
    [[ "$on" == *"      - $p"* ]] || { echo "missing path filter: $p"; return 1; }
  done
}

@test "the floor check checks floors, and test.yml does not run coverage" {
  [[ "$(cat "$WF")" == *"dev/coverage.sh --check dev/coverage-floor.tsv"* ]]
  [ "$(grep -c 'coverage.sh' "$ROOT/.github/workflows/test.yml" || true)" -eq 0 ]
}
