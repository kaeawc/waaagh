#!/usr/bin/env bash
# Shared helpers for the orchestrate scripts. Source, do not execute.
# Env: ORCHESTRATE_STATE_DIR (default ~/.claude/orchestrate), ORCHESTRATE_AUTHOR (default: the
# authenticated gh user, cached an hour: ORCHESTRATE_AUTHOR_TTL), ORCHESTRATE_NOW (epoch seconds; tests only), ORCHESTRATE_GH_BUDGET=1
# (pace every gh call through gh-budget.sh; see orch_gh_priority below), ORCHESTRATE_GH_API
# (auto|rest|graphql; see orch_gh_api below).

orch_now() { echo "${ORCHESTRATE_NOW:-${EPOCHSECONDS:-$(date +%s)}}"; }   # EPOCHSECONDS: bash 5

# orch_usage -> the running script's header, its -h text: the comment block after the shebang, up to
# the first line that is not a comment (the rule cli-contract.bats checks). No line range to bump
# when the header grows (#184). Scripts that print usage before sourcing this file inline the awk.
orch_usage() { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; }

# This file's directory, without a dirname process per call (#112).
case "${BASH_SOURCE[0]}" in */*) _orch_lib_dir=${BASH_SOURCE[0]%/*} ;; *) _orch_lib_dir=. ;; esac

# orch_repo [OWNER/REPO] -> OWNER/REPO (falls back to the checkout's repository). A checkout with
# exactly one remote, on github.com, and no `gh repo set-default` choice is read from git with no
# API call; anything else (several remotes, a chosen default, another host) is left to gh, which
# knows how to pick among remotes.
orch_repo() {
  if [[ -n "${1:-}" ]]; then echo "$1"; return; fi
  local urls slug
  if urls=$(git config --get-regexp '^remote\..*\.url$' 2>/dev/null) && [[ -n "$urls" && "$urls" != *$'\n'* ]] &&
    ! git config --get-regexp '^remote\..*\.gh-resolved$' >/dev/null 2>&1; then
    slug=$(sed -nE 's#^[^ ]+ (https://|ssh://)?(git@)?github\.com[:/]([^/]+/[^/]+)$#\3#p' <<<"$urls")
    slug=${slug%.git}
    if [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then echo "$slug"; return; fi
  fi
  gh repo view --json nameWithOwner | jq -r .nameWithOwner
}

# orch_author -> the login whose PRs this orchestrator may drive: ORCHESTRATE_AUTHOR, else the
# authenticated gh user. The `gh api user` answer is cached in <state root>/.author (one line:
# written-at epoch, host, account key, login) and reused for ORCHESTRATE_AUTHOR_TTL seconds
# (default 3600; 0 = always ask) while the host (GH_HOST, default github.com) and the account key
# match. The key is read offline, not from `gh auth status` (which validates over the network):
# the active user in gh's hosts.yml plus a checksum of GH_TOKEN/GITHUB_TOKEN, so `gh auth switch`
# or a different token misses the cache; any other account change waits out the TTL. A failed
# lookup is never cached.
orch_author() {
  if [[ -n "${ORCHESTRATE_AUTHOR:-}" ]]; then echo "$ORCHESTRATE_AUTHOR"; return; fi
  local root="${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}" host="${GH_HOST:-github.com}"
  local ttl="${ORCHESTRATE_AUTHOR_TTL:-3600}" now key login t h k l
  local cache="$root/.author" hosts="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
  now=$(orch_now)
  key=$(awk -v h="$host:" '$0 == h { in_host = 1; next } /^[^ ]/ { in_host = 0 }
    in_host && $1 == "user:" { print $2 }' "$hosts" 2>/dev/null) || key=""
  key="${key:--}/$(printf '%s' "${GH_TOKEN:-${GITHUB_TOKEN:-}}" | cksum | tr ' ' .)"
  if [[ "$ttl" =~ ^[0-9]+$ ]] && ((ttl > 0)) && read -r t h k l 2>/dev/null <"$cache" &&
    [[ "$t" =~ ^[0-9]+$ && "$h" == "$host" && "$k" == "$key" && -n "$l" ]] && ((now - t < ttl)); then
    echo "$l"
    return
  fi
  login=$(gh api user | jq -r .login) || return 1
  [[ -n "$login" && "$login" != null ]] || return 1
  if mkdir -p "$root" 2>/dev/null && printf '%s %s %s %s\n' "$now" "$host" "$key" "$login" >"$cache.tmp.$$" 2>/dev/null; then
    mv "$cache.tmp.$$" "$cache" 2>/dev/null || rm -f "$cache.tmp.$$"
  fi
  echo "$login"
}

# orch_state_dir OWNER/REPO -> the repo's durable campaign directory (created on demand).
orch_state_dir() {
  local d="${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/${1//\//__}"
  [[ -d "$d" ]] || mkdir -p "$d"
  echo "$d"
}

# GraphQL or REST (#108, #109, #123). Claude Code cloud sessions answer every GraphQL call
# (`gh pr list`, `gh issue list`, `gh api graphql`) with an HTTP 403 that names GraphQL; scripts
# with a REST path (gh-issues.sh, gh-rest-pr.sh) then read over REST. ORCHESTRATE_GH_API=auto
# (default: GraphQL first, REST after a refusal) | rest (never try GraphQL) | graphql (never fall
# back). A refusal is remembered in <state root>/gh-no-graphql (its epoch) for 12 hours, so every
# later read on this state root, issue side and PR side, goes straight to REST until it expires.
#
# orch_gh_api NAME -> graphql | rest: what to try first. Exit 2, with a message naming NAME, when
# ORCHESTRATE_GH_API is not auto, rest or graphql (callers: `api=$(orch_gh_api x.sh) || exit 2`).
orch_gh_api() {
  local mode="${ORCHESTRATE_GH_API:-auto}" at memo
  case "$mode" in
    rest | graphql) echo "$mode"; return ;;
    auto) ;;
    *) echo "$1: ORCHESTRATE_GH_API must be auto, rest or graphql" >&2; return 2 ;;
  esac
  memo="${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/gh-no-graphql"
  if read -r at 2>/dev/null <"$memo" && [[ "$at" =~ ^[0-9]+$ ]] && (($(orch_now) - at < 43200)); then
    echo rest
  else
    echo graphql
  fi
}

# orch_gh_refused RC STDERR: true when a failed gh-read.sh call (its exit code and stderr text) is
# GitHub refusing GraphQL (exit 5, forbidden, and the message names "GraphQL"; the lower-case
# graphql in gh's "(https://api.github.com/graphql)" suffix does not count) and ORCHESTRATE_GH_API
# allows the fallback (auto). Then it records the refusal for orch_gh_api. Any other failure is
# the caller's to report.
orch_gh_refused() {
  local root="${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}"
  [[ "${ORCHESTRATE_GH_API:-auto}" == auto && "$1" == 5 && "$2" == *GraphQL* ]] || return 1
  if mkdir -p "$root" 2>/dev/null && orch_now >"$root/gh-no-graphql.tmp.$$" 2>/dev/null; then
    mv "$root/gh-no-graphql.tmp.$$" "$root/gh-no-graphql" 2>/dev/null || rm -f "$root/gh-no-graphql.tmp.$$"
  fi
  return 0
}

orch_default_branch() { gh api "repos/$1" | jq -r .default_branch; }

# orch_hold_of OWNER/REPO PR: is PR in the merge loop's hold file? Read through hold.sh list, never
# by parsing <state dir>/holds again. Prints `#N until:<event> since:<iso> <reason>` and returns 0
# when held, 1 when not, 2 when hold.sh could not read the file. Every merge path asks this before
# it merges (pr-merge.sh exit 14, merge-queue.sh outcome `held`; #202), so a hold set at any time,
# by hand or automatically, stops the merge. While a release freeze is on (<state dir>/FREEZE,
# freeze.sh; #208) every PR is held: `#N until:freeze-end since:<iso> release freeze: <reason>`.
orch_hold_of() {
  local rows since why f
  rows=$("$_orch_lib_dir/hold.sh" list --repo "$1" 2>/dev/null) || return 2
  rows=$(awk -F'\t' -v pr="${2#\#}" '$1 == pr { printf "#%s until:%s since:%s %s\n", $1, $2, $3, $5 }' <<<"$rows")
  f="${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/${1//\//__}/FREEZE"
  if [[ -z "$rows" && -f "$f" ]]; then
    IFS=$'\t' read -r since why <"$f" || true
    rows="#${2#\#} until:freeze-end since:${since:-unknown} release freeze: ${why:--}"
  fi
  [[ -n "$rows" ]] || return 1
  printf '%s\n' "$rows"
}

# orch_review_hold_of OWNER/REPO PR: does PR's latest internal review verdict hold it? Read through
# review-ledger.sh latest. Prints `#N review:<verdict> since:<iso> head:<sha> <note>` and returns 0
# when the latest verdict is not ship (fix-first, rethink, fixing), 1 when it is ship or there is
# none, 2 when the ledger could not be read. The merge paths ask it next to orch_hold_of (#206).
orch_review_hold_of() {
  local row rc=0 t p v h n
  row=$("$_orch_lib_dir/review-ledger.sh" latest --repo "$1" --pr "${2#\#}" 2>/dev/null) || rc=$?
  ((rc != 3)) || return 1
  ((rc == 0)) || return 2
  IFS=$'\t' read -r t p v h n <<<"$row"
  [[ "$v" != ship ]] || return 1
  printf '#%s review:%s since:%s head:%s %s\n' "$p" "$v" "$t" "$h" "$n"
}

# orch_hold_hint HOLD -> what lifts a hold orch_hold_of printed: freeze.sh end, or hold.sh release.
orch_hold_hint() {
  if [[ "$1" == *until:freeze-end* ]]; then echo "freeze.sh end lifts it"; else echo "hold.sh release clears it"; fi
}

# orch_iso EPOCH -> 2026-01-02T03:04:05Z
orch_iso() { jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")'; }

# orch_journal FILE JSON: write an operation journal entry atomically (temp file + mv).
orch_journal() {
  [[ "$1" != */* || -d "${1%/*}" ]] || mkdir -p "${1%/*}"
  printf '%s\n' "$2" >"$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

# orch_read_retry N CMD...: a bounded read. A `gh ...` read goes through gh-read.sh (typed errors,
# backoff, rate-limit handling, at most N attempts, refuses writes); anything else is run up to N
# times, ORCHESTRATE_READ_SLEEP seconds apart (default 2). Never wrap a mutation in it.
orch_read_retry() {
  local n=$1 i out
  shift
  if [[ "$1" == gh ]]; then
    shift
    "$_orch_lib_dir/gh-read.sh" --tries "$n" --budget "${ORCHESTRATE_READ_BUDGET:-60}" -- "$@" 2>/dev/null
    return
  fi
  for ((i = 1; i <= n; i++)); do
    if out=$("$@" 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
    ((i == n)) || sleep "${ORCHESTRATE_READ_SLEEP:-2}"
  done
  return 1
}

# orch_gh_priority high|normal|low: declare this script's GitHub budget priority (gh-budget.sh):
# high for merges and main health, normal for ticks, repairs and lanes, low for nudges, backfills
# and sweeps. With ORCHESTRATE_GH_BUDGET=1, sourcing this file also puts the gh shim (gh-shim/gh)
# first on PATH, so every gh call, gh-read.sh's and third-party scripts' included, is paced.
orch_gh_priority() { export GH_BUDGET_PRIORITY="$1"; }
if [[ "${ORCHESTRATE_GH_BUDGET:-0}" == 1 ]]; then
  _orch_shim="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-shim"
  case ":$PATH:" in *":$_orch_shim:"*) ;; *) export PATH="$_orch_shim:$PATH" ;; esac
fi
