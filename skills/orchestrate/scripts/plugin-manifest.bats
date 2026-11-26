#!/usr/bin/env bats
# The plugin manifests set no version (#408). Claude Code detects a plugin update by comparing the
# version it computes for the source with the one it installed, and an explicit `version` wins over
# the commit SHA: a pinned version makes `claude plugin update` and marketplace auto-update report
# "already at the latest version" after every merge. With none set, every commit on main is an
# update. Release tags (dev/release-tag.sh) are separate and do not read the manifest.
# Run: bats plugin-manifest.bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "plugin.json sets no version, so installs are versioned by commit" {
  run jq -e 'has("version") | not' "$ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
}

@test "no marketplace entry sets a version either" {
  run jq -e '[.plugins[] | has("version")] | any | not' "$ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
  # The entry is this repository itself, so a commit to it is what an update installs.
  [ "$(jq -r '.plugins[] | select(.name == "waaagh") | .source' "$ROOT/.claude-plugin/marketplace.json")" = "./" ]
}
