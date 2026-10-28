#!/usr/bin/env bash
# Shared helpers for the orchestrate scripts. Source, do not execute.
# Env: ORCHESTRATE_STATE_DIR (default ~/.claude/orchestrate), ORCHESTRATE_AUTHOR (default: the
# authenticated gh user), ORCHESTRATE_NOW (epoch seconds; tests only).

orch_now() { echo "${ORCHESTRATE_NOW:-$(date +%s)}"; }

# orch_repo [OWNER/REPO] -> OWNER/REPO (falls back to the checkout's repository).
orch_repo() {
  if [[ -n "${1:-}" ]]; then echo "$1"; else gh repo view --json nameWithOwner | jq -r .nameWithOwner; fi
}

# The login whose PRs this orchestrator may drive.
orch_author() {
  if [[ -n "${ORCHESTRATE_AUTHOR:-}" ]]; then echo "$ORCHESTRATE_AUTHOR"; else gh api user | jq -r .login; fi
}

# orch_state_dir OWNER/REPO -> the repo's durable campaign directory (created on demand).
orch_state_dir() {
  local d="${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/${1//\//__}"
  mkdir -p "$d"
  echo "$d"
}

orch_default_branch() { gh api "repos/$1" | jq -r .default_branch; }

# orch_iso EPOCH -> 2026-01-02T03:04:05Z
orch_iso() { jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")'; }

# orch_journal FILE JSON: write an operation journal entry atomically (temp file + mv).
orch_journal() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

# orch_read_retry N CMD...: run a read up to N times (ORCHESTRATE_READ_SLEEP seconds apart, default 2);
# prints the first successful output. Only for reads: never wrap a mutation in it.
orch_read_retry() {
  local n=$1 i out
  shift
  for ((i = 1; i <= n; i++)); do
    if out=$("$@" 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
    ((i == n)) || sleep "${ORCHESTRATE_READ_SLEEP:-2}"
  done
  return 1
}
