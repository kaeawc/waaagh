#!/usr/bin/env bash
# Local GitHub API pacer shared by every caller on this host. Reads /rate_limit (free; cached about
# 20 s in the state root and shared by all callers), keeps a per-priority floor of the remaining
# budget, and spaces calls evenly until the reset, so the hour's budget lasts the hour.
#
# Usage: gh-budget.sh run <high|normal|low> -- GH_ARGS...   run one gh command under the budget
#        gh-budget.sh status                                  budget, floors and endpoint backoffs
# Floors (for a 5,000-call resource; scaled to each resource's limit): a call may spend down to
#   high 150 (merges, main health) | normal 1000 (ticks, repairs, lanes) | low 2500 (review nudges,
#   backfills, sweeps). Above its floor a call takes the next slot, min gap = seconds_to_reset /
#   (remaining - floor); slots are reserved per priority under a lock, shared by every caller.
# Resource (approximate): `api graphql` and pr/issue/repo/label/project commands count against
#   graphql, `search` against search, everything else (REST `api`, run, workflow, release) core.
# Local-only (never paced, no /rate_limit read, no state touched): `api rate_limit`, version,
#   --version, help, --help, config, alias, completion, `extension list`, and auth except
#   `auth status` (which calls the API). The list is explicit; anything else is paced.
# Out of budget: high waits for the reset (at most GH_BUDGET_HIGH_MAX_WAIT, default 3900 s); normal
#   and low wait at most GH_BUDGET_MAX_WAIT (default 60 s), else exit 75 and the caller skips the
#   pass. Refusals log "gh-budget: out-of-budget priority=<p> resource=<r> remaining=<n>
#   floor=<f> retry-at=<iso>" on stderr.
# A rate-limit 403/429 while /rate_limit still shows headroom on that resource is endpoint-scoped
#   (per-endpoint or secondary): only that endpoint backs off (GH_BUDGET_ENDPOINT_BACKOFF, default
#   300 s), logged "gh-budget: endpoint-limit endpoint=<e> resource=<r> remaining=<n> retry-at=<iso>".
#   With no headroom it logs "gh-budget: exhausted resource=<r> retry-at=<iso>".
# An unreadable /rate_limit fails open: the call runs unpaced ("gh-budget: unpaced ...").
# Governs local callers only: cloud sessions use their own GitHub auth and budget.
# Exit: gh's own status | 75 out of budget, or the endpoint is backing off | 2 usage
# Env: ORCHESTRATE_STATE_DIR (state root; state in <root>/gh-budget), GH_BUDGET_TTL (cache seconds,
#   20), GH_BUDGET_FAKE_SLEEP=1 (tests: waits logged as "gh-budget: wait <s>"), ORCHESTRATE_NOW.
set -euo pipefail

usage() { sed -n '2,29p' "$0"; }
cmd=${1:-}
case "$cmd" in
  -h | --help) usage; exit 0 ;;
  run)
    prio=${2:-}
    [[ "${3:-}" == -- ]] || { usage >&2; exit 2; }
    shift 3 ;;
  status) shift ;;
  *) usage >&2; exit 2 ;;
esac

# --- local-only gh commands: straight to gh, before any state is read or written ---------------
local_only() { # GH_ARGS...: 0 when the command makes no budgeted API call
  case "${1:-}" in
    "" | --version | version | help | --help | -h | config | alias | completion) return 0 ;;
    auth) [[ "${2:-}" != status ]] ;;
    extension | extensions | ext) [[ "${2:-}" == list || "${2:-}" == ls ]] ;;
    api) [[ "${2:-}" == rate_limit || "${2:-}" == /rate_limit ]] ;;
    *) return 1 ;;
  esac
}
if [[ "$cmd" == run ]] && (($#)) && local_only "$@"; then
  case "$prio" in
    high | normal | low) exec gh "$@" ;;
    *) echo "gh-budget: unknown priority: $prio (high|normal|low)" >&2; exit 2 ;;
  esac
fi

state_root=${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}
dir="$state_root/gh-budget"
mkdir -p "$dir"
cache="$dir/rate_limit.json"
ttl=${GH_BUDGET_TTL:-20}
fake=${GH_BUDGET_FAKE_SLEEP:-0}
clock_base=${ORCHESTRATE_NOW:-$(date +%s)}
waited=0
# Our own gh calls (and anything they spawn) go straight to gh, never back through the shim.
export GH_BUDGET_ACTIVE=1

now() { if [[ "$fake" == 1 ]]; then echo $((clock_base + waited)); else date +%s; fi; }
iso() { jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")'; }
wait_for() {
  if [[ "$fake" == 1 ]]; then echo "gh-budget: wait $1" >&2; else sleep "$1"; fi
  waited=$((waited + $1))
}
floor_base() { case "$1" in high) echo 150 ;; normal) echo 1000 ;; low) echo 2500 ;; *) return 1 ;; esac; }
max_wait() { if [[ "$1" == high ]]; then echo "${GH_BUDGET_HIGH_MAX_WAIT:-3900}"; else echo "${GH_BUDGET_MAX_WAIT:-60}"; fi; }

# --- a small mkdir lock (bash 3.2, no flock); a holder that died is reclaimed ------------------
lock() {
  local i
  for ((i = 0; i < 200; i++)); do
    if mkdir "$dir/lock" 2>/dev/null; then echo $$ >"$dir/lock/pid"; return 0; fi
    local p
    p=$(cat "$dir/lock/pid" 2>/dev/null || true)
    if [[ -n "$p" ]] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$dir/lock"; continue; fi
    sleep 0.05
  done
  return 1   # contention past ~10 s: proceed unlocked rather than stall the caller
}
unlock() { rm -rf "$dir/lock"; }

# --- the shared /rate_limit snapshot ----------------------------------------------------------
refresh() { # fetch /rate_limit into the cache; 1 when unreadable
  local raw
  raw=$(gh api rate_limit 2>/dev/null) || return 1
  jq -ce --argjson at "$(now)" '{at: $at, resources: (.resources | map_values({limit, remaining, reset}))}' \
    <<<"$raw" >"$cache.tmp.$$" 2>/dev/null || { rm -f "$cache.tmp.$$"; return 1; }
  mv "$cache.tmp.$$" "$cache"
}
fresh() { # make sure the cache is younger than the TTL
  local at
  at=$(jq -r '.at // 0' "$cache" 2>/dev/null || echo 0)
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  (($(now) - at < ttl)) || refresh
}
field() { jq -r --arg r "$1" --arg f "$2" '.resources[$r][$f] // empty' "$cache" 2>/dev/null; }

# --- classify the gh command ------------------------------------------------------------------
endpoint_of() { # api: the path (query dropped, numeric segments as N); otherwise "<cmd> <sub>"
  if [[ "$1" == api ]]; then
    local i a skip=no
    for ((i = 2; i <= $#; i++)); do
      a=${!i}
      if [[ "$skip" == yes ]]; then skip=no; continue; fi
      case "$a" in
        -X | --method | -H | --header | -f | -F | --field | --raw-field | --input | -q | --jq | -t | \
          --template | --hostname | --cache | -p | --preview) skip=yes ;;
        -*) ;;
        *) a=${a#/}; a=${a%%\?*}
           printf '%s\n' "$a" | sed -E 's#(^|/)[0-9]+(/|$)#\1N\2#g; s#(^|/)[0-9]+(/|$)#\1N\2#g'
           return ;;
      esac
    done
    echo api
  elif [[ -n "${2:-}" && "$2" != -* ]]; then echo "$1 $2"
  else echo "$1"
  fi
}
resource_of() { # COMMAND ENDPOINT
  case "$1" in
    api) if [[ "$2" == graphql ]]; then echo graphql; else echo core; fi ;;
    pr | issue | repo | label | project | discussion) echo graphql ;;
    search) echo search ;;
    *) echo core ;;
  esac
}
endpoint_file() { printf '%s/endpoint-%s' "$dir" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }

# --- status -----------------------------------------------------------------------------------
if [[ "$cmd" == status ]]; then
  fresh || { echo "gh-budget: /rate_limit unreadable"; exit 1; }
  for r in core graphql search; do
    lim=$(field "$r" limit); rem=$(field "$r" remaining); rst=$(field "$r" reset)
    [[ -n "$lim" ]] || continue
    printf '%s remaining=%s/%s reset=%s floors high=%s normal=%s low=%s\n' "$r" "$rem" "$lim" "$(iso "$rst")" \
      $((150 * lim / 5000)) $((1000 * lim / 5000)) $((2500 * lim / 5000))
  done
  for f in "$dir"/endpoint-*; do
    [[ -f "$f" ]] || continue
    until_=$(sed -n 1p "$f"); name=$(sed -n 2p "$f")
    [[ "$until_" =~ ^[0-9]+$ ]] && ((until_ > $(now))) && echo "endpoint-limit endpoint=$name retry-at=$(iso "$until_")"
  done
  exit 0
fi

# --- run --------------------------------------------------------------------------------------
base=$(floor_base "$prio") || { echo "gh-budget: unknown priority: $prio (high|normal|low)" >&2; exit 2; }
(($#)) || { usage >&2; exit 2; }
endpoint=$(endpoint_of "$@")
resource=$(resource_of "$1" "$endpoint")
limit_wait=$(max_wait "$prio")

# An endpoint that answered with a scoped limit: wait it out within the bound, or skip.
ef=$(endpoint_file "$endpoint")
if [[ -f "$ef" ]]; then
  until_=$(sed -n 1p "$ef")
  if [[ "$until_" =~ ^[0-9]+$ ]] && ((until_ > $(now))); then
    delay=$((until_ - $(now)))
    if ((delay > limit_wait)); then
      echo "gh-budget: endpoint-backoff endpoint=$endpoint priority=$prio retry-at=$(iso "$until_")" >&2
      exit 75
    fi
    wait_for "$delay"
  fi
fi

reset_waited=no
while :; do
  locked=no
  lock && locked=yes
  if ! fresh || [[ -z "$(field "$resource" remaining)" ]]; then
    [[ "$locked" == no ]] || unlock
    echo "gh-budget: unpaced resource=$resource (rate_limit unreadable)" >&2
    break
  fi
  lim=$(field "$resource" limit); rem=$(field "$resource" remaining); rst=$(field "$resource" reset)
  floor=$((base * lim / 5000))
  spare=$((rem - floor))
  t=$(now)
  if ((spare <= 0)); then
    [[ "$locked" == no ]] || unlock
    if [[ "$reset_waited" == yes ]]; then
      echo "gh-budget: unpaced resource=$resource (still at the floor after the reset)" >&2
      break
    fi
    delay=$((rst - t + 1)); ((delay > 0)) || delay=1
    if ((delay > limit_wait)); then
      echo "gh-budget: out-of-budget priority=$prio resource=$resource remaining=$rem floor=$floor retry-at=$(iso "$((t + delay))")" >&2
      exit 75
    fi
    wait_for "$delay"
    reset_waited=yes
    rm -f "$cache"
    continue
  fi
  gap=0
  ((rst <= t)) || gap=$(((rst - t) / spare))
  last=$(cat "$dir/last-$resource-$prio" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  slot=$((last + gap > t ? last + gap : t))
  delay=$((slot - t))
  if ((delay > limit_wait)); then
    [[ "$locked" == no ]] || unlock
    echo "gh-budget: out-of-budget priority=$prio resource=$resource remaining=$rem floor=$floor retry-at=$(iso "$slot")" >&2
    exit 75
  fi
  echo "$slot" >"$dir/last-$resource-$prio"
  # Count this call against the cached snapshot, so callers between refreshes see it spent.
  jq -c --arg r "$resource" '.resources[$r].remaining -= 1' "$cache" >"$cache.tmp.$$" && mv "$cache.tmp.$$" "$cache"
  [[ "$locked" == no ]] || unlock
  ((delay == 0)) || wait_for "$delay"
  break
done

err=$(mktemp)
trap 'rm -f "$err"' EXIT
rc=0
gh "$@" 2>"$err" || rc=$?
cat "$err" >&2
if ((rc != 0)) && grep -qiE 'rate limit|HTTP 429' "$err"; then
  if refresh && rem=$(field "$resource" remaining) && [[ "$rem" =~ ^[0-9]+$ ]] && ((rem > 0)); then
    until_=$(($(now) + ${GH_BUDGET_ENDPOINT_BACKOFF:-300}))
    printf '%s\n%s\n' "$until_" "$endpoint" >"$ef.tmp.$$" && mv "$ef.tmp.$$" "$ef"
    echo "gh-budget: endpoint-limit endpoint=$endpoint resource=$resource remaining=$rem retry-at=$(iso "$until_")" >&2
  else
    rst=$(field "$resource" reset)
    echo "gh-budget: exhausted resource=$resource retry-at=$(iso "${rst:-$(now)}")" >&2
  fi
fi
exit "$rc"
