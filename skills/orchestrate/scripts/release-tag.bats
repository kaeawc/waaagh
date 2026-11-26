#!/usr/bin/env bats
# Release tags for the App broker action (#359): dev/release-tag.sh cuts waaagh's next vX.Y.Z tag on
# HEAD (the first is v0.1.0), and .github/workflows/release-tag.yml runs it when
# actions/app-broker changes on main, then pushes the tag and creates its release. Consumers pin
# `@<sha> # vX.Y.Z`, which their Dependabot bumps. Run: bats release-tag.bats

setup() {
  load test_helper
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  WF="$ROOT/.github/workflows/release-tag.yml"
  R="$BATS_TEST_TMPDIR/repo"; mkdir -p "$R/.claude-plugin"
  git -C "$R" init -q -b main
  echo '{"name":"waaagh"}' >"$R/.claude-plugin/plugin.json"
  git -C "$R" add -A && git -C "$R" commit -qm one
}
rt() { (cd "$R" && "$ROOT/dev/release-tag.sh" "$@"); }
commit() { echo "$1" >>"$R/f" && git -C "$R" add -A && git -C "$R" commit -qm "$1"; }

@test "the first tag is v0.1.0; a tagged HEAD cuts nothing" {
  run rt
  [ "$status" -eq 0 ]
  [ "$output" = "tagged v0.1.0" ]
  [ "$(git -C "$R" cat-file -t v0.1.0)" = tag ]   # annotated
  run rt
  [ "$output" = "already v0.1.0" ]
  [ "$(git -C "$R" tag -l | wc -l | tr -d ' ')" -eq 1 ]
}

@test "later tags bump the newest vX.Y.Z by version order, not by name" {
  git -C "$R" tag v0.9.0 && commit a && git -C "$R" tag v0.10.0 && git -C "$R" tag not-a-release
  commit b
  run rt
  [ "$output" = "tagged v0.10.1" ]
  commit c; run rt --bump minor
  [ "$output" = "tagged v0.11.0" ]
  commit d; run rt --bump major
  [ "$output" = "tagged v1.0.0" ]
}

@test "bad input: an unknown bump cuts nothing; a version in plugin.json does not pick the first tag" {
  run rt --bump huge
  [ "$status" -eq 2 ]
  [ -z "$(git -C "$R" tag -l)" ]
  echo '{"name":"waaagh","version":"9.9.9"}' >"$R/.claude-plugin/plugin.json"; git -C "$R" commit -qam pinned
  run rt
  [ "$status" -eq 0 ]
  [ "$output" = "tagged v0.1.0" ]
}

@test "the workflow runs on broker changes to main and by hand, with contents write, pinned" {
  on=$(awk '/^on:/ { f = 1; next } f && /^[^ #]/ { exit } f' "$WF")
  [[ "$on" == *$'  push:\n    branches: [main]\n    paths:\n      - \'actions/app-broker/**\''* ]]
  [[ "$on" == *"  workflow_dispatch:"* ]]
  grep -qx '  contents: write' "$WF"
  grep -qF 'out=$(dev/release-tag.sh --bump "$BUMP")' "$WF"
  grep -qF 'gh release create "$tag" --verify-tag' "$WF"
  grep -qF 'gh release view "$tag"' "$WF"            # a re-run still creates a missing release
  grep -qF "if: github.ref == 'refs/heads/main'" "$WF"   # tags only on main
  grep -qF 'fetch-depth: 0' "$WF"
  # Every action pinned to a commit (waaagh requires it).
  ! grep -E '^\s*-?\s*uses:' "$WF" | grep -vE '@[0-9a-f]{40}( |$)'
}
