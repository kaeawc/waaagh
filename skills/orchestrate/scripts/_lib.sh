#!/usr/bin/env bash
# Shared helpers for the orchestrate scripts. Source, do not execute.
# Env: ORCHESTRATE_STATE_DIR (default ~/.claude/orchestrate), ORCHESTRATE_AUTHOR (default: the
# authenticated gh user, cached an hour: ORCHESTRATE_AUTHOR_TTL), ORCHESTRATE_NOW (epoch seconds; tests only), ORCHESTRATE_GH_BUDGET=1
# (pace every gh call through gh-budget.sh; see orch_gh_priority below), ORCHESTRATE_GH_API
# (auto|rest|graphql; see orch_gh_api below), SPECTRA (the spectra binary; see orch_spectra_require below).

orch_now() { echo "${ORCHESTRATE_NOW:-${EPOCHSECONDS:-$(date +%s)}}"; }   # EPOCHSECONDS: bash 5

# orch_usage -> the running script's header, its -h text: the comment block after the shebang, up to
# the first line that is not a comment (the rule cli-contract.bats checks). No line range to bump
# when the header grows (#184). Scripts that print usage before sourcing this file inline the awk.
orch_usage() { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; }

# This file's directory, without a dirname process per call (#112).
case "${BASH_SOURCE[0]}" in */*) _orch_lib_dir=${BASH_SOURCE[0]%/*} ;; *) _orch_lib_dir=. ;; esac

# orch_run NAME ARGS...: run the sibling script NAME (hold.sh, pr-merge.sh, ...) with ARGS and
# return its exit code. NAME is looked up in ORCHESTRATE_SCRIPTS_DIR first (tests only; unset by
# default), then in this file's directory, the real tree (#233). A test points the variable at a
# directory holding only the stubs it needs (a failing hold.sh, a pr-merge.sh with a fixed exit
# code): every other NAME still runs from the real tree, so bashcov credits it, where a copy of
# the tree is credited nothing. The helpers below, and the scripts whose siblings tests stub
# (merge-queue.sh, pr-merge.sh, issue-candidates.sh, triage-tick.sh), call their siblings through it.
orch_run() {
  local f="$_orch_lib_dir/$1"
  [[ -z "${ORCHESTRATE_SCRIPTS_DIR:-}" || ! -x "$ORCHESTRATE_SCRIPTS_DIR/$1" ]] || f="$ORCHESTRATE_SCRIPTS_DIR/$1"
  shift
  "$f" "$@"
}

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
  local root host="${GH_HOST:-github.com}"
  root=$(orch_state_root)
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

# orch_state_root -> the root of all durable campaign state: ORCHESTRATE_STATE_DIR, default ~/.claude/orchestrate.
# The one place that default is spelled (#304).
orch_state_root() { echo "${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}"; }

# orch_advisory_checks OWNER/REPO: the repository's advisory checks, one name per line from
# <state dir>/advisory-checks (#412). Blank lines and lines whose first non-blank character is #
# are skipped; a name keeps any # inside it ("C# build"). Read only by callers that ask for it
# (pr-ready.sh and pr-merge.sh --advisory-file), as --ignore-check names.
orch_advisory_checks() {
  local f
  f="$(orch_state_root)/${1//\//__}/advisory-checks"
  [[ -f "$f" ]] || return 0
  sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | grep -v -e '^$' -e '^#' || true
}

# orch_state_dir OWNER/REPO -> the repo's durable campaign directory (created on demand).
orch_state_dir() {
  local d
  d="$(orch_state_root)/${1//\//__}"
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
  memo="$(orch_state_root)/gh-no-graphql"
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
  local root
  root=$(orch_state_root)
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
  rows=$(orch_run hold.sh list --repo "$1" 2>/dev/null) || return 2
  rows=$(awk -F'\t' -v pr="${2#\#}" '$1 == pr { printf "#%s until:%s since:%s %s\n", $1, $2, $3, $5 }' <<<"$rows")
  f="$(orch_state_root)/${1//\//__}/FREEZE"
  if [[ -z "$rows" && -f "$f" ]]; then
    IFS=$'\t' read -r since why <"$f" || true
    rows="#${2#\#} until:freeze-end since:${since:-unknown} release freeze: ${why:--}"
  fi
  [[ -n "$rows" ]] || return 1
  printf '%s\n' "$rows"
}

# orch_review_hold_of OWNER/REPO PR [HEAD [BASE [GITDIR]]]: does PR's latest internal review verdict
# hold it? Read through review-ledger.sh latest. Prints `#N review:<verdict> since:<iso> head:<sha>
# <note>` and returns 0 when the latest verdict is not ship (fix-first, rethink, fixing, repairing,
# repaired), 1 when it is ship or there is none, 2 when the ledger could not be read. The merge
# paths ask it next to orch_hold_of (#206). With HEAD (the PR's full head SHA), a ship recorded
# --head R holds too unless orch_review_covers R HEAD (#210): `#N review:stale since:<iso> head:R
# ship at R does not cover HEAD: <why>`. A ship row with no head is not pinned. BASE defaults to
# the default branch, GITDIR to ORCHESTRATE_GIT_DIR or the current directory.
orch_review_hold_of() {
  local row rc=0 t p v h n s base why
  row=$(orch_run review-ledger.sh latest --repo "$1" --pr "${2#\#}" 2>/dev/null) || rc=$?
  ((rc != 3)) || return 1
  ((rc == 0)) || return 2
  IFS=$'\t' read -r t p v h n s <<<"$row"
  if [[ "$v" == ship ]]; then
    [[ -n "${3:-}" && -n "$h" && "$h" != - && "$3" != "$h"* ]] || return 1
    base=${4:-}
    [[ -n "$base" ]] || base=$(orch_default_branch "$1" 2>/dev/null) || base=""
    why=$(orch_review_covers "${5:-${ORCHESTRATE_GIT_DIR:-.}}" "$p" "$h" "$3" "$base") && return 1
    printf '#%s review:stale since:%s head:%s ship at %s does not cover %s: %s\n' "$p" "$t" "$h" "${h:0:9}" "${3:0:9}" "$why"
    return 0
  fi
  # A repairing or repaired row (#212) names its session.
  printf '#%s review:%s since:%s head:%s %s%s\n' "$p" "$v" "$t" "$h" "$n" "${s:+ session:$s}"
}

# orch_review_covers GITDIR PR REVIEWED HEAD BASE: does a review of REVIEWED still hold at HEAD
# (#210)? Yes (return 0) when they are the same commit, or when REVIEWED is an ancestor of HEAD and
# every commit in `git rev-list REVIEWED..HEAD --not origin/BASE` is a merge GitHub made from
# update-branch: committer GitHub <noreply@github.com>, two parents, one of them on origin/BASE,
# and a tree equal to the clean automatic merge of its parents (`git merge-tree --write-tree`,
# git 2.38+), so it carries nothing beyond the base. Anything else returns 1 and prints why: a
# merge made by hand (an agent's conflict resolution, or a web-editor resolution), a non-merge
# commit, a non-ancestor, or commits GITDIR does not have. Local git only, never the compare API
# (it also lists the base's own squash commits); it first fetches BASE and refs/pull/PR/head
# from origin into GITDIR, quietly, and reads what is there if that fails.
orch_review_covers() {
  local d=$1 pr=$2 r=$3 h=$4 base=$5 c ps cn ce after
  [[ "$r" != "$h" ]] || return 0
  [[ -n "$base" ]] || { echo "cannot verify: no base branch"; return 1; }
  git -C "$d" fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" </dev/null >/dev/null 2>&1 || true
  git -C "$d" cat-file -e "$h^{commit}" 2>/dev/null ||
    git -C "$d" fetch -q origin "refs/pull/$pr/head" </dev/null >/dev/null 2>&1 || true
  r=$(git -C "$d" rev-parse -q --verify "$r^{commit}" 2>/dev/null) || { echo "cannot verify: ${3:0:9} is not in $d"; return 1; }
  h=$(git -C "$d" rev-parse -q --verify "$h^{commit}" 2>/dev/null) || { echo "cannot verify: ${4:0:9} is not in $d"; return 1; }
  [[ "$r" != "$h" ]] || return 0
  git -C "$d" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" >/dev/null 2>&1 ||
    { echo "cannot verify: origin/$base is not in $d"; return 1; }
  git -C "$d" merge-base --is-ancestor "$r" "$h" 2>/dev/null || { echo "${r:0:9} is not an ancestor of ${h:0:9}"; return 1; }
  after=$(git -C "$d" log --format='%H%x09%P%x09%cn%x09%ce' "$h" "^$r" "^refs/remotes/origin/$base") ||
    { echo "cannot verify: git log ${r:0:9}..${h:0:9} failed in $d"; return 1; }
  while IFS=$'\t' read -r c ps cn ce; do
    [[ -n "$c" ]] || continue
    orch_update_merge "$d" "$base" "$c" "$ps" "$cn" "$ce" || return 1
  done <<<"$after"
  return 0
}

# orch_update_merge GITDIR BASE COMMIT "PARENTS" COMMITTER-NAME COMMITTER-EMAIL: is COMMIT a merge
# GitHub made from update-branch (#210)? The test orch_review_covers and orch_last_write share: two
# parents, committer GitHub <noreply@github.com>, one parent on origin/BASE (already fetched), and
# a tree equal to the clean automatic merge of its parents. Returns 0, or 1 and prints why. The
# caller passes the fields from its own `git log --format='%H%x09%P%x09%cn%x09%ce'`.
orch_update_merge() {
  local d=$1 base=$2 c=$3 ps=$4 cn=$5 ce=$6 p ok want tree
  # shellcheck disable=SC2086 # the parent list splits on spaces on purpose
  set -- $ps
  (($# == 2)) || { echo "${c:0:9} is not a merge"; return 1; }
  [[ "$cn" == GitHub && "$ce" == noreply@github.com ]] || { echo "${c:0:9} is a merge made by hand ($cn <$ce>)"; return 1; }
  ok=no
  for p in "$1" "$2"; do
    ! git -C "$d" merge-base --is-ancestor "$p" "refs/remotes/origin/$base" 2>/dev/null || ok=yes
  done
  [[ "$ok" == yes ]] || { echo "${c:0:9} does not merge $base"; return 1; }
  want=$(git -C "$d" merge-tree --write-tree "$1" "$2" 2>/dev/null) || { echo "${c:0:9} is not a clean merge of its parents (or git is older than 2.38)"; return 1; }
  tree=$(git -C "$d" rev-parse "$c^{tree}")
  [[ "${want%%$'\n'*}" == "$tree" ]] || { echo "${c:0:9} changes more than the merge of $base"; return 1; }
}

# orch_last_write GITDIR HEAD BASE: the newest real write on a branch (#242), for "was this PR
# pushed recently" guards. GitHub's update-branch merge gives a PR a fresh head without anyone
# writing to it, so the head's time says nothing about a second writer. Prints
# `<sha><TAB><committer epoch><TAB><merges skipped>` for the commit with the newest committer time
# among those in `git log HEAD --not origin/BASE` that are not such a merge (orch_update_merge; a
# merge made by hand, a conflict resolution, is a write), or `-<TAB>-<TAB><n>` when there is none.
# origin/BASE must be fetched. Returns 1 when git cannot list HEAD's commits.
orch_last_write() {
  local d=$1 h=$2 base=$3 log c ps cn ce ct best=- bt=- skipped=0
  log=$(git -C "$d" log --format='%H%x09%P%x09%cn%x09%ce%x09%ct' "$h" "^refs/remotes/origin/$base" 2>/dev/null) || return 1
  while IFS=$'\t' read -r c ps cn ce ct; do
    [[ -n "$c" ]] || continue
    if orch_update_merge "$d" "$base" "$c" "$ps" "$cn" "$ce" >/dev/null; then skipped=$((skipped + 1)); continue; fi
    if [[ "$bt" == - ]] || ((ct > bt)); then best=$c bt=$ct; fi
  done <<<"$log"
  printf '%s\t%s\t%s\n' "$best" "$bt" "$skipped"
}

# orch_hold_hint HOLD -> what lifts a hold orch_hold_of printed: freeze.sh end, or hold.sh release.
orch_hold_hint() {
  if [[ "$1" == *until:freeze-end* ]]; then echo "freeze.sh end lifts it"; else echo "hold.sh release clears it"; fi
}

# orch_iso EPOCH -> 2026-01-02T03:04:05Z. A non-negative integer EPOCH with no leading zero is
# formatted by bash's printf (4.2+), in UTC, with no process: every log line and journal entry pays
# for it (#112). Anything else goes to jq, which formats or rejects it as before: bash 3.2, a
# fraction, garbage, a negative (printf reads -1 and -2 as "now" and "shell start") and a leading
# zero (printf reads 0123 as octal, and rejects 08).
orch_iso() {
  if [[ "$1" =~ ^(0|[1-9][0-9]{0,14})$ ]] && ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2))); then
    TZ=UTC0 printf '%(%Y-%m-%dT%H:%M:%SZ)T\n' "$1"
  else
    jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")'
  fi
}

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
    orch_run gh-read.sh --tries "$n" --budget "${ORCHESTRATE_READ_BUDGET:-60}" -- "$@" 2>/dev/null
    return
  fi
  for ((i = 1; i <= n; i++)); do
    if out=$("$@" 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
    ((i == n)) || sleep "${ORCHESTRATE_READ_SLEEP:-2}"
  done
  return 1
}

# orch_gql_read N [--json] gh CMD...: a bounded GraphQL read (gh-read.sh, at most N attempts) that
# tells the caller when GitHub refused GraphQL, which orch_read_retry hides (its stderr goes to
# /dev/null). Prints the body and returns 0; returns 1 on any other failure (nothing printed);
# returns 2 and prints `refused` when GraphQL was refused and ORCHESTRATE_GH_API is auto, after
# recording the refusal (orch_gh_refused) so every later read goes to REST. The caller switches to
# its REST path on 2 (and must not treat the printed `refused` as a body). --json asks gh-read.sh
# to check the body is JSON.
orch_gql_read() {
  local n=$1 rc=0 err out jsonflag=()
  shift
  if [[ "${1:-}" == --json ]]; then jsonflag=(--json); shift; fi
  [[ "${1:-}" != gh ]] || shift
  err=$(mktemp "${TMPDIR:-/tmp}/orch-gql-err.XXXXXX")
  out=$(orch_run gh-read.sh "${jsonflag[@]+"${jsonflag[@]}"}" --tries "$n" --budget "${ORCHESTRATE_READ_BUDGET:-60}" -- "$@" 2>"$err") || rc=$?
  if ((rc == 0)); then rm -f "$err"; printf '%s\n' "$out"; return 0; fi
  if orch_gh_refused "$rc" "$(cat "$err" 2>/dev/null || true)"; then rm -f "$err"; echo refused; return 2; fi
  rm -f "$err"
  return 1
}

# orch_rest_pr ARGS...: gh-rest-pr.sh ARGS (through orch_run). Prints its body and returns its
# status; its stderr is shown, prefixed with the calling script and subcommand, only when it fails,
# so the reason behind an exit 3 is not lost and a success stays quiet (#304, #310).
orch_rest_pr() {
  local err rc=0 out
  err=$(mktemp "${TMPDIR:-/tmp}/orch-rest-err.XXXXXX")
  out=$(orch_run gh-rest-pr.sh "$@" 2>"$err") || rc=$?
  if ((rc != 0)); then echo "${0##*/}: gh-rest-pr.sh $1 failed (exit $rc): $(cat "$err" 2>/dev/null || true)" >&2; fi
  rm -f "$err"
  printf '%s' "$out"
  return "$rc"
}

# orch_gh_priorityhigh|normal|low: declare this script's GitHub budget priority (gh-budget.sh):
# high for merges and main health, normal for ticks, repairs and lanes, low for nudges, backfills
# and sweeps. With ORCHESTRATE_GH_BUDGET=1, sourcing this file also puts the gh shim (gh-shim/gh)
# first on PATH, so every gh call, gh-read.sh's and third-party scripts' included, is paced.
orch_gh_priority() { export GH_BUDGET_PRIORITY="$1"; }

# --- spectra (#329): waaagh requires it for every host-level question -------------------------
# Spectra (github.com/kaeawc/spectra) observes the machine: load and its cause, process
# attribution, leftover processes, booted devices, toolchain faults. waaagh decides and coordinates.
# It is a hard dependency: a script that needs spectra calls orch_spectra_require with the
# capabilities it uses, and stops with one named error when spectra or a capability is missing.
# There is no fallback to waaagh's own host inspection.
# SPECTRA: the spectra binary (default `spectra` on PATH; tests point it at a stub).
# A capability is met when `spectra capabilities --json` lists it. Until spectra declares its
# diagnostic commands there (kaeawc/spectra#612), a subcommand that `spectra help` lists also meets it.
# The capabilities JSON's spectra_version must be a release at or above ORCH_SPECTRA_MIN_VERSION
# (a leading v is allowed), or a local source build; anything else is refused.
# Each JSON interface advertises its result schema and major version (result_schema); a field is
# only renamed or dropped with a new major (spectra docs/reference/capabilities.md). For the schemas
# waaagh reads (ORCH_SPECTRA_SCHEMAS, the shapes in spectra-contract.tsv), an interface of a required
# capability (CAP, or CAP.<variant> such as owner.under) at another major is refused, as is a
# capabilities manifest at another major.
ORCH_SPECTRA_MIN_VERSION=0.1.2
ORCH_SPECTRA_SCHEMAS="spectra.capabilities=1 spectra.load=1 spectra.orphans=1 spectra.owner.under=1 spectra.idle=1 spectra.devices=1"
ORCH_SPECTRA_INSTALL="install spectra $ORCH_SPECTRA_MIN_VERSION or newer: brew install kaeawc/tap/spectra, or build it from https://github.com/kaeawc/spectra (make build)"
_orch_spectra_caps="" _orch_spectra_help="" _orch_spectra_schemas=""
# orch_spectra_version_ok V: 0 when V is a source build or a release >= ORCH_SPECTRA_MIN_VERSION,
# 1 when it is an older release, 2 when it is not a version at all. Source builds: `go build`
# stamps dev..., `make build` stamps `git describe`, a bare commit hash when no tag is an ancestor.
# After X.Y.Z, git describe's -N-g<hash>, -dirty and +build metadata keep the release's rank; any
# other suffix is a prerelease (-rc1), which ranks below its release.
orch_spectra_version_ok() {
  local v=${1#v} i a b pre=0
  [[ "$v" == dev* || "$v" =~ ^[0-9a-f]{7,40}(-dirty)?$ ]] && return 0
  [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9]+-g[0-9a-f]+)?(-dirty)?(\+.*)?$ ]] ||
    { pre=1; [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-[0-9A-Za-z.-]+(\+.*)?$ ]] || return 2; }
  local -a have=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}") want
  IFS=. read -r -a want <<<"$ORCH_SPECTRA_MIN_VERSION"
  for i in 0 1 2; do
    a=$((10#${have[i]})) b=$((10#${want[i]}))
    ((a > b)) && return 0
    ((a < b)) && return 1
  done
  return "$pre"
}
orch_spectra_bin() { echo "${SPECTRA:-spectra}"; }
# orch_spectra_require CAP...: 0 when spectra runs and meets every CAP; otherwise one line on
# stderr naming what is missing and how to install it, and 1. Each spectra read happens once per
# process.
orch_spectra_require() {
  local bin cap missing=""
  bin=$(orch_spectra_bin)
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "spectra: not found ($bin). waaagh requires it; $ORCH_SPECTRA_INSTALL" >&2
    return 1
  fi
  if [[ -z "$_orch_spectra_caps" ]]; then
    local json ver rc=0
    json=$("$bin" capabilities --json 2>/dev/null | jq -c 'select(.schema.name == "spectra.capabilities")' 2>/dev/null) || json=""
    _orch_spectra_caps=$(jq -r '.interfaces[]?.name' <<<"$json" 2>/dev/null) || _orch_spectra_caps=""
    if [[ -z "$_orch_spectra_caps" ]]; then
      echo "spectra: $bin capabilities --json gave no capability list; waaagh needs a spectra with the capabilities contract. $ORCH_SPECTRA_INSTALL" >&2
      return 1
    fi
    ver=$(jq -r '.spectra_version // "" | strings' <<<"$json" 2>/dev/null) || ver=""
    orch_spectra_version_ok "$ver" || rc=$?
    # "interface<TAB>schema<TAB>major" for each interface with a result schema; the manifest's own first.
    _orch_spectra_schemas=$(jq -r '["capabilities", .schema.name, .schema.version],
      (.interfaces[]? | select(.result_schema | type == "object") | [.name, .result_schema.name, .result_schema.version])
      | map(tostring) | @tsv' <<<"$json" 2>/dev/null) || _orch_spectra_schemas=""
    if ((rc != 0)); then
      _orch_spectra_caps=""
      if ((rc == 1)); then
        echo "spectra: $bin is ${ver#v}, below the required $ORCH_SPECTRA_MIN_VERSION. $ORCH_SPECTRA_INSTALL" >&2
      else
        echo "spectra: $bin capabilities --json gave no usable version (${ver:-none}). $ORCH_SPECTRA_INSTALL" >&2
      fi
      return 1
    fi
  fi
  local iface sname smajor want e used bad=""
  while IFS=$'\t' read -r iface sname smajor; do
    used=no
    [[ "$iface" != capabilities ]] || used=yes
    for cap in "$@"; do [[ "$iface" != "$cap" && "$iface" != "$cap".* ]] || used=yes; done
    want=""
    for e in $ORCH_SPECTRA_SCHEMAS; do [[ "${e%=*}" != "$sname" ]] || want=${e#*=}; done
    [[ "$used" == no || -z "$want" || "${smajor%%.*}" == "$want" ]] || bad="${bad:+$bad, }$sname v$smajor (waaagh reads v$want)"
  done <<<"$_orch_spectra_schemas"
  if [[ -n "$bad" ]]; then
    echo "spectra: $bin speaks a schema waaagh does not know: $bad. Update waaagh, or install a spectra it supports; $ORCH_SPECTRA_INSTALL" >&2
    return 1
  fi
  for cap in "$@"; do
    grep -qxF -- "$cap" <<<"$_orch_spectra_caps" && continue
    [[ -n "$_orch_spectra_help" ]] || _orch_spectra_help=$("$bin" help 2>&1 | awk '/^Subcommands:/ { on = 1; next } on && /^$/ { exit } on && /^  [a-z]/ { print $1 }' || true)
    grep -qxF -- "$cap" <<<"$_orch_spectra_help" || missing="${missing:+$missing }$cap"
  done
  if [[ -n "$missing" ]]; then
    echo "spectra: $bin lacks: $missing. Update it; $ORCH_SPECTRA_INSTALL" >&2
    return 1
  fi
}
# orch_worktree_home [DIR]: where new lane worktrees of DIR's repository (default the working
# directory's) belong (#394), whether or not it exists yet: ORCHESTRATE_WORKTREE_ROOT, else
# <WAAAGH_WORKTREE_HOME, default ~/worktrees.noindex>/<repo>, <repo> being the main checkout's
# directory name. Spotlight indexes no directory whose name ends in .noindex, nor anything below it.
# Returns 1 when ORCHESTRATE_WORKTREE_ROOT is unset and DIR is outside a git checkout, or neither
# WAAAGH_WORKTREE_HOME nor HOME is set (a hook or cron environment may lack HOME: no /worktrees.noindex).
orch_worktree_home() {
  local common name base=${WAAAGH_WORKTREE_HOME:-}
  if [[ -n "${ORCHESTRATE_WORKTREE_ROOT:-}" ]]; then echo "$ORCHESTRATE_WORKTREE_ROOT"; return; fi
  [[ -n "$base" ]] || { [[ -n "${HOME:-}" ]] && base=$HOME/worktrees.noindex; } || return 1
  common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  name=${common%/}; name=${name%/.git}; name=${name%.git}; name=${name##*/}
  echo "$base/${name:-repo}"
}
# orch_worktree_root: where this checkout's lane worktrees live, resolved: orch_worktree_home when
# it exists, else the legacy <main checkout>/.claude/worktrees when that exists (an
# ORCHESTRATE_WORKTREE_ROOT that does not exist is not looked past); returns 1 when there is none.
orch_worktree_root() {
  local r common
  r=$(orch_worktree_home .) || r=""
  if [[ -z "${ORCHESTRATE_WORKTREE_ROOT:-}" && ! -d "$r" ]] && common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    r=""
    [[ ! -d "$common/../.claude/worktrees" ]] || r="$common/../.claude/worktrees"
  fi
  [[ -n "$r" && -d "$r" ]] || return 1
  (cd "$r" && pwd -P)
}
# proc_cwds DIR...: one "PID<TAB>cwd" line per visible process whose working directory is a DIR or
# below one (spectra owner --under, #331), resolved; nothing when none is. Returns 1 when spectra
# is missing, too old for --under, or fails: callers then remove nothing. Spectra's exit 4 (none
# visible, but other users' processes could not be read) counts as none: only this user's
# processes work in this user's worktrees, as with the lsof listing this replaced.
proc_cwds() {
  local out rc=0 d dirs=()
  for d in "$@"; do [[ ! -d "$d" ]] || dirs+=("$d"); done   # a missing directory has nobody in it
  ((${#dirs[@]})) || return 0
  orch_spectra_require owner 2>/dev/null || return 1
  out=$(orch_spectra owner --under --json "${dirs[@]}" 2>/dev/null) || rc=$?
  case "$rc" in 0 | 3 | 4) ;; *) return 1 ;; esac
  jq -r '(.holders | arrays) | .[] | "\(.pid)\t\(.cwd)"' <<<"$out" 2>/dev/null || return 1
}
# orch_spectra ARGS...: run spectra with ARGS (after orch_spectra_require). Every spectra call in
# the scripts goes through here, so tests stub one place (spectra-lib.bats lints it).
orch_spectra() { "$(orch_spectra_bin)" "$@"; }
if [[ "${ORCHESTRATE_GH_BUDGET:-0}" == 1 ]]; then
  _orch_shim="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-shim"
  case ":$PATH:" in *":$_orch_shim:"*) ;; *) export PATH="$_orch_shim:$PATH" ;; esac
fi

# --- Rerun verdicts and reruns.log (#275): one definition for main-health, triage-tick and
# failure-triage, so they cannot disagree about what a classifier verdict means. ---
# orch_verdict_rerunnable VERDICT: exit 0 when the verdict says "re-run, do not fix". Case-insensitive,
# `_` read as `-`.
orch_verdict_rerunnable() {
  local v
  v=$(printf '%s' "${1-}" | tr '[:upper:]_' '[:lower:]-')
  case "$v" in flake | known-flake | infra | rerun | rerun-dont-fix) return 0 ;; esac
  return 1
}
# orch_mirror_sig FILE -> kind (apt, pip, npm or maven) when FILE shows a package install that could
# not reach its public mirror (#217, #297): infrastructure, so a rerun is right and a code fix is not.
# The one definition, shared by failure-triage.sh and main-health.sh.
orch_mirror_sig() {
  local kind=""
  if grep -Eqi -e 'Failed to fetch https?://|Temporary failure resolving|Unable to connect to [^ ]*(ubuntu|debian|archive|security)|Could not resolve .(archive|security|deb)[^ ]*|Hash Sum mismatch|Could not get lock /var/lib/(apt|dpkg)|Some index files failed to download|Connection failed \[IP' "$1"; then kind=apt
  elif grep -Eqi -e 'Could not fetch URL https://pypi|(Read timed out|Connection (to|aborted)|Max retries exceeded).*(pypi|files\.pythonhosted)' "$1"; then kind=pip
  elif grep -Eqi -e 'npm (ERR!|error) (code )?(ETIMEDOUT|ECONNRESET|EAI_AGAIN|ENOTFOUND)|npm (ERR!|error) network' "$1"; then kind=npm
  elif grep -Eqi -e 'Could not transfer artifact|Could not (GET|HEAD) .https://(repo|plugins)\.(maven|gradle)' "$1"; then kind=maven
  fi
  [[ -n "$kind" ]] || return 1
  echo "$kind"
}
# orch_rerun_seen RUN_ID: exit 0 when the run's latest record in the log file named by the caller's
# $reruns (its state dir's reruns.log) is anything but a refused rerun. An `intent` with no outcome
# (the answer was lost) counts as re-run: reconciled by the snapshot, never replayed.
orch_rerun_seen() {
  [[ -f "${reruns:-}" ]] && awk -F'\t' -v r="run=$1" '$2 == r { last = $NF } END { exit !(last != "" && last !~ /^(full-)?failed/) }' "$reruns"
}
