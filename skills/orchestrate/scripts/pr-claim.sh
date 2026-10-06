#!/usr/bin/env bash
# Cross-session ownership claim for one PR, so two orchestrators never drive the same PR.
# The claim is an atomic mkdir; a claim whose heartbeat is older than the TTL is stale and can be
# taken over (atomic rename of the stale claim, then mkdir). The PR's state.json checkpoint lives
# beside the claim and survives owner changes.
#
# Usage: pr-claim.sh <claim|heartbeat|release|status|path> --repo OWNER/REPO --pr N
#                    [--owner ID] [--ttl SECONDS]
#   claim      exit 0 when this owner holds the claim, 3 when another owner holds a fresh one
#   heartbeat  exit 0 when refreshed, 3 when this owner does not hold the claim
#   release    exit 0 (no-op when not held by this owner)
#   status     prints: unclaimed | held owner=<id> age=<s> fresh=<yes|no> mine=<yes|no>
#   path       prints the PR's state directory (state.json checkpoint lives there)
# Env: ORCHESTRATE_STATE_DIR (default ~/.claude/orchestrate), ORCHESTRATE_NOW (tests only).
set -euo pipefail

cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" pr="" ttl=1800
owner=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --owner) owner=$2; shift 2 ;;
    --ttl) ttl=$2; shift 2 ;;
    *) echo "pr-claim.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$repo" && -n "$pr" ]] || { sed -n '2,16p' "$0" >&2; exit 2; }

state_root=${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}
dir="$state_root/prs/${repo//\//__}__${pr}"
claim="$dir/claim"
now() { echo "${ORCHESTRATE_NOW:-$(date +%s)}"; }

write_claim() {
  printf '%s\n' "$owner" >"$claim/owner.tmp" && mv "$claim/owner.tmp" "$claim/owner"
  now >"$claim/heartbeat.tmp" && mv "$claim/heartbeat.tmp" "$claim/heartbeat"
}

# Sets holder / age. A claim dir whose files are not written yet counts as a fresh claim.
read_claim() {
  holder=$(cat "$claim/owner" 2>/dev/null || echo "<initializing>")
  local hb
  hb=$(cat "$claim/heartbeat" 2>/dev/null || now)
  age=$(($(now) - hb))
}

mkdir -p "$dir"

case "$cmd" in
  path) echo "$dir" ;;
  status)
    if [[ ! -d "$claim" ]]; then echo unclaimed; exit 0; fi
    read_claim
    fresh=yes; ((age > ttl)) && fresh=no
    mine=no; [[ "$holder" == "$owner" ]] && mine=yes
    echo "held owner=$holder age=$age fresh=$fresh mine=$mine"
    ;;
  claim)
    if mkdir "$claim" 2>/dev/null; then write_claim; echo "claimed"; exit 0; fi
    read_claim
    if [[ "$holder" == "$owner" ]]; then write_claim; echo "claimed (already held)"; exit 0; fi
    if ((age <= ttl)); then echo "held by $holder (heartbeat ${age}s ago)"; exit 3; fi
    # Stale: only one contender's rename succeeds; the loser sees the winner's fresh claim.
    if mv "$claim" "$dir/stale.$$.$RANDOM" 2>/dev/null && mkdir "$claim" 2>/dev/null; then
      write_claim
      echo "claimed (took over stale claim from $holder, ${age}s old)"
      exit 0
    fi
    read_claim
    echo "held by $holder (heartbeat ${age}s ago)"
    exit 3
    ;;
  heartbeat)
    [[ -d "$claim" ]] || { echo "not held"; exit 3; }
    read_claim
    [[ "$holder" == "$owner" ]] || { echo "held by $holder"; exit 3; }
    write_claim
    echo "heartbeat"
    ;;
  release)
    if [[ -d "$claim" ]]; then
      read_claim
      [[ "$holder" == "$owner" ]] && rm -rf "$claim" && echo "released" && exit 0
    fi
    echo "not held by $owner"
    ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
