#!/usr/bin/env bash
# Bounded, typed GitHub READS. Runs one read-only gh command with a per-call timeout, retries
# network and server failures with capped exponential backoff inside a total time budget, honours
# Retry-After and rate-limit reset times, and reports a typed outcome instead of a bare failure.
# It refuses anything that could write: mutations are reconciled by their callers, never retried.
#
# Usage: gh-read.sh [--budget SECONDS] [--timeout SECONDS] [--tries N] [--json] -- GH_ARGS...
#   --budget   total time for all attempts and waits (default 60: one pass, not a watcher)
#   --timeout  per attempt (default 30)
#   --tries    attempts at most (default 4)
#   --json     the output must parse as JSON; malformed output is retried, then reported
# Reads allowed: `api` (GET; `api graphql` with a query, never a mutation), `pr list|view|checks|
# diff`, `issue list|view`, `run list|view`, `repo view`, `label list`, `release list|view`,
# `search ...`. Anything else exits 2 without running.
# Output: the command's stdout on success. On failure, one line on stderr:
#   gh-read: <class> status=<http|-> request-id=<id|-> retry-at=<iso|-> msg=<sanitized message>
# Exit: 0 ok | 2 not a read / usage | 3 not-found (404, 410) | 4 auth (401) | 5 forbidden (403
#   without a rate limit) | 6 rate-limited (wait longer than the budget; see retry-at) |
#   7 transient (5xx, network, timeout; budget or tries exhausted) | 8 malformed (not JSON)
# A rate limit is recorded in <state root>/gh-cooldown, so other lanes on this host wait for the
# same reset instead of each probing GitHub. Env: ORCHESTRATE_STATE_DIR (state root),
# GH_READ_FAKE_SLEEP=1 (tests: waits are logged to stderr as "gh-read: wait <s>", not slept),
# GH_READ_JITTER=0 (no jitter), ORCHESTRATE_NOW (clock).
set -euo pipefail

budget=60 timeout=30 tries=4 want_json=no
while (($#)); do
  case "$1" in
    --budget) budget=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    --tries) tries=$2; shift 2 ;;
    --json) want_json=yes; shift ;;
    --) shift; break ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "gh-read: unknown argument: $1 (put gh arguments after --)" >&2; exit 2 ;;
  esac
done
(($#)) || { sed -n '2,23p' "$0" >&2; exit 2; }

# --- only reads -------------------------------------------------------------------------------
not_read() { echo "gh-read: refused: not a read: gh $*" >&2; exit 2; }
case "$1 ${2:-}" in
  "pr list" | "pr view" | "pr checks" | "pr diff" | "issue list" | "issue view" | "run list" | \
    "run view" | "repo view" | "label list" | "release list" | "release view" | "search "*) ;;
  "api "*)
    # gh api sends POST when fields are given without -X; only GET (and GraphQL queries) read.
    method="" fields=no graphql=no
    [[ "${2:-}" == graphql ]] && graphql=yes
    for ((i = 2; i <= $#; i++)); do
      a=${!i} j=$((i + 1))
      case "$a" in
        -X | --method) method=${!j:-} ;;
        -X?*) method=${a#-X} ;;
        --method=*) method=${a#--method=} ;;
        -f | -F | --field | --raw-field | --input)
          fields=yes
          [[ "$graphql" == no || "${!j:-}" != *mutation* ]] || not_read "$@" ;;
      esac
    done
    method=$(tr '[:lower:]' '[:upper:]' <<<"$method")
    if [[ "$graphql" == no ]]; then
      [[ -n "$method" ]] || { [[ "$fields" == yes ]] && method=POST || method=GET; }
      [[ "$method" == GET ]] || not_read "$@"
    elif [[ -n "$method" && "$method" != POST ]]; then
      not_read "$@"
    fi ;;
  *) not_read "$@" ;;
esac

state_root=${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}
cooldown="$state_root/gh-cooldown"
fake=${GH_READ_FAKE_SLEEP:-0}
clock_base=${ORCHESTRATE_NOW:-$(date +%s)}
waited=0
now() { if [[ "$fake" == 1 ]]; then echo $((clock_base + waited)); else date +%s; fi; }
start=$(now)
elapsed() { echo $(($(now) - start)); }
iso() { jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")'; }
wait_for() { # seconds
  if [[ "$fake" == 1 ]]; then echo "gh-read: wait $1" >&2; else sleep "$1"; fi
  waited=$((waited + $1))
}
sanitize() { # strip tokens, keep one short line
  sed -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/[REDACTED]/g' | tr '\n\r' '  ' | cut -c1-300
}
fail() { # class status request-id retry-at message exit
  printf 'gh-read: %s status=%s request-id=%s retry-at=%s msg=%s\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | sanitize)" >&2
  exit "$6"
}

# A rate limit another lane already hit: wait for it inside the budget, or report it at once.
if [[ -f "$cooldown" ]]; then
  until=$(cat "$cooldown" 2>/dev/null || echo 0)
  if [[ "$until" =~ ^[0-9]+$ ]] && ((until > $(now))); then
    delay=$((until - $(now)))
    ((delay <= budget)) || fail rate-limited - - "$(iso "$until")" "shared cooldown from an earlier rate limit" 6
    wait_for "$delay"
  fi
fi

is_api=no
[[ "$1" == api ]] && is_api=yes
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

attempt=0 backoff=1
while :; do
  attempt=$((attempt + 1))
  args=("$@")
  # Response headers carry the status, request id and rate-limit timing (not with --paginate,
  # where they would interleave with the pages).
  [[ "$is_api" == no || " $* " == *" --paginate "* ]] || args+=(--include)
  rc=0
  # In a subshell with its own stderr, so the shell's "Alarm clock" notice stays out of the output.
  (perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$timeout" gh "${args[@]}" >"$work/out" 2>"$work/err"; exit $?) 2>/dev/null || rc=$?

  # Split headers (api --include) from the body.
  status="" reqid="-" retry_after="" remaining="" reset=""
  if [[ "$is_api" == yes ]] && head -1 "$work/out" | grep -qE '^HTTP/[0-9.]+ [0-9]{3}'; then
    status=$(head -1 "$work/out" | awk '{print $2}')
    awk 'NR > 1 && /^\r?$/ { exit } NR > 1 { print }' "$work/out" | tr -d '\r' >"$work/headers"
    awk 'found { print; next } NR > 1 && /^\r?$/ { found = 1 }' "$work/out" >"$work/body"
    hdr() { awk -v k="$1" 'index(tolower($0), tolower(k) ":") == 1 { sub(/^[^:]*: */, ""); print; exit }' "$work/headers"; }
    reqid=$(hdr X-GitHub-Request-Id); reqid=${reqid:--}
    retry_after=$(hdr Retry-After)
    remaining=$(hdr X-RateLimit-Remaining)
    reset=$(hdr X-RateLimit-Reset)
  else
    cp "$work/out" "$work/body"
  fi
  [[ -n "$status" ]] || status=$({ grep -oE 'HTTP [0-9]{3}' "$work/err" || true; } | tail -1 | cut -c6-)
  msg=$(cat "$work/err" "$work/body" 2>/dev/null | grep -v '^$' | head -3 || true)

  if ((rc == 0)); then
    if [[ "$want_json" == yes ]] && ! jq -e . "$work/body" >/dev/null 2>&1; then
      class=malformed
    else
      cat "$work/body"
      exit 0
    fi
  elif ((rc == 142)); then class=timeout
  else
    case "$status" in
      404 | 410) fail not-found "$status" "$reqid" - "$msg" 3 ;;
      401) fail auth 401 "$reqid" - "$msg" 4 ;;
      403 | 429)
        if [[ "$status" == 429 || -n "$retry_after" || "$remaining" == 0 ]] || grep -qi 'rate limit' "$work/err" "$work/body"; then
          class=rate-limited
        else
          fail forbidden 403 "$reqid" - "$msg" 5
        fi ;;
      5??) class=transient ;;
      "") if grep -qiE 'timeout|timed out|connection (reset|refused)|could not resolve|EOF|TLS|network' "$work/err"; then
            class=transient
          elif grep -qiE 'authentication|auth login|bad credentials' "$work/err"; then
            fail auth - "$reqid" - "$msg" 4
          else
            class=transient
          fi ;;
      *) fail error "$status" "$reqid" - "$msg" 7 ;;
    esac
  fi

  # Retryable: decide how long to wait, within the budget.
  if [[ "$class" == rate-limited ]]; then
    if [[ "$retry_after" =~ ^[0-9]+$ ]]; then delay=$retry_after
    elif [[ "$remaining" == 0 && "$reset" =~ ^[0-9]+$ ]]; then delay=$((reset - $(now))); ((delay > 0)) || delay=1
    else delay=60   # secondary limit without headers: GitHub asks for at least a minute
    fi
    until=$(($(now) + delay))
    mkdir -p "$state_root"
    printf '%s\n' "$until" >"$cooldown.tmp.$$" && mv "$cooldown.tmp.$$" "$cooldown"
    if (($(elapsed) + delay > budget)) || ((attempt >= tries)); then
      fail rate-limited "${status:--}" "$reqid" "$(iso "$until")" "$msg" 6
    fi
  else
    jitter=0
    [[ "${GH_READ_JITTER:-1}" == 0 ]] || jitter=$((RANDOM % (backoff / 2 + 1)))
    delay=$((backoff + jitter))
    backoff=$((backoff * 2 > 30 ? 30 : backoff * 2))
    if ((attempt >= tries)) || (($(elapsed) + delay > budget)); then
      if [[ "$class" == malformed ]]; then fail malformed "${status:-200}" "$reqid" - "output is not JSON" 8; fi
      fail transient "${status:--}" "$reqid" - "$class after $attempt attempts: $msg" 7
    fi
  fi
  wait_for "$delay"
done
