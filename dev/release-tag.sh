#!/usr/bin/env bash
# Cut waaagh's next release tag (vX.Y.Z) on HEAD, locally (#359). Consumers pin the App broker
# action as `kaeawc/waaagh/actions/app-broker@<sha> # vX.Y.Z` (app-broker.sh workflow), so their
# Dependabot (github-actions) bumps the pin to each new tag. The Release tag workflow runs this when
# actions/app-broker changes on main, then pushes the tag and creates its GitHub release.
#
# Usage: dev/release-tag.sh [--bump patch|minor|major]
#   The first tag is v0.1.0; later ones bump the newest vX.Y.Z tag (default patch). HEAD already
#   carrying a vX.Y.Z tag cuts nothing. The plugin manifest sets no version on purpose (#408):
#   Claude Code then versions an install by commit, so every merge to main is an update.
# Output: `tagged vX.Y.Z` (exit 0), or `already vX.Y.Z` (exit 0, nothing cut).
# Exit: 0 | 2 usage | 3 the tag already exists elsewhere
set -euo pipefail
bump="patch"
while (($#)); do
  case "$1" in
    --bump) bump=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "release-tag.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$bump" in patch | minor | major) ;; *) echo "release-tag.sh: --bump must be patch, minor or major" >&2; exit 2 ;; esac

semver='^v[0-9]+\.[0-9]+\.[0-9]+$'
here=$(git tag --points-at HEAD | grep -E "$semver" | sort -V | tail -1 || true)
if [[ -n "$here" ]]; then echo "already $here"; exit 0; fi

last=$(git tag -l 'v*' | grep -E "$semver" | sort -V | tail -1 || true)
if [[ -z "$last" ]]; then
  next="v0.1.0"
else
  IFS=. read -r ma mi pa <<<"${last#v}"
  case "$bump" in
    major) next="v$((ma + 1)).0.0" ;;
    minor) next="v$ma.$((mi + 1)).0" ;;
    patch) next="v$ma.$mi.$((pa + 1))" ;;
  esac
fi
git tag -a "$next" -m "waaagh $next" HEAD 2>/dev/null || { echo "release-tag.sh: tag $next already exists" >&2; exit 3; }
echo "tagged $next"
