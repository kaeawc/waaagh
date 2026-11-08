#!/usr/bin/env bash
# Long-lived campaign loops (merge loop, tick, review snapshot) live in the state dir, not in a
# session scratchpad, and beat a heartbeat each pass, so a new orchestrator can tell "loop dead"
# from "loop idle" with one read and restart a dead loop in its own session.
#
# Usage: loops.sh <install|heartbeat|status> [--repo OWNER/REPO] [options]
#   install NAME FILE
#     Copy FILE (e.g. a merge-loop script written in a scratchpad) to <state dir>/bin/NAME,
#     executable, replacing any older copy; prints the installed path. Run loops from there.
#   heartbeat NAME [--pid PID] [--every SECONDS] | heartbeat NAME --end REASON
#     Write <state dir>/loops/NAME.heartbeat: `beat=<epoch> pid=<pid> host=<host> every=<s>`.
#     Call it once per pass; --every is the loop's sleep between passes (stale after 3x it, or
#     after --stale). --end records why the loop stopped (e.g. `--end bound`).
#   status [NAME...] [--stale SECONDS]
#     Every loop with a script in bin/ or a heartbeat in loops/ (plus each NAME given), then:
#       loops ok | loops none | loops act <state>=<name>,<name> ...
#       loop <name> <alive|stale|dead|ended:REASON|never> last_pass=<N>m|- script=<path>|missing
#     alive: beat within the stale window (--stale, else 3x its --every, else 1800s) and its PID,
#     when recorded on this host, still runs. stale: no beat inside the window. dead: the PID is
#     gone. never: a script with no heartbeat yet. script=missing: the loop beat, but its script
#     is not in <state dir>/bin/ (it ran from a scratchpad; install it before restarting it).
# Exit: 0 ok (or no loops) | 2 usage | 3 a loop is not running (stale, dead, ended or never) |
#       4 a loop's script is missing from <state dir>/bin/ (takes precedence over 3)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { sed -n '2,23p' "$0"; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
case "$cmd" in -h | --help) usage; exit 0 ;; esac
repo="" pid="" every="" end="" stale=""
args=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --pid) pid=$2; shift 2 ;;
    --every) every=$2; shift 2 ;;
    --end) end=$2; shift 2 ;;
    --stale) stale=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "loops.sh: unknown argument: $1" >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
bad() { echo "loops.sh: $1" >&2; exit 2; }
name_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || bad "NAME is letters, digits, '.', '_' and '-': $1"; }
n=${#args[@]}
case "$cmd" in
  install) ((n == 2)) || bad "install needs NAME FILE"; name_ok "${args[0]}"
    [[ -f "${args[1]}" ]] || bad "no such file: ${args[1]}" ;;
  heartbeat) ((n == 1)) || bad "heartbeat needs one NAME"; name_ok "${args[0]}"
    [[ -z "$pid" || "$pid" =~ ^[0-9]+$ ]] || bad "--pid is a number"
    [[ -z "$every" || "$every" =~ ^[0-9]+$ ]] || bad "--every is seconds" ;;
  status) for a in ${args[@]+"${args[@]}"}; do name_ok "$a"; done
    [[ -z "$stale" || "$stale" =~ ^[0-9]+$ ]] || bad "--stale is seconds" ;;
  *) usage >&2; exit 2 ;;
esac
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
now=$(orch_now)
host=$(hostname 2>/dev/null || echo unknown)

case "$cmd" in
  install)
    mkdir -p "$state/bin"
    dst="$state/bin/${args[0]}"
    cp "${args[1]}" "$dst.tmp.$$" && chmod +x "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"
    echo "installed $dst"
    exit 0 ;;
  heartbeat)
    f="$state/loops/${args[0]}.heartbeat"
    if [[ -n "$end" ]]; then
      line="ended=${end// /_} at=$now"
      [[ ! -f "$f" ]] || line="$line $(tr '\n' ' ' <"$f" | sed -E 's/(^| )(ended|at)=[^ ]*//g; s/  +/ /g; s/^ //; s/ $//')"
    else
      line="beat=$now pid=${pid:-$PPID} host=$host every=${every:-0}"
    fi
    orch_journal "$f" "$line"
    echo "$line"
    exit 0 ;;
esac

# ---- status ------------------------------------------------------------------------------------
names=$({
  for a in ${args[@]+"${args[@]}"}; do echo "$a"; done
  if [[ -d "$state/bin" ]]; then for f in "$state/bin"/*; do [[ -f "$f" ]] && echo "${f##*/}"; done; fi
  if [[ -d "$state/loops" ]]; then for f in "$state/loops"/*.heartbeat; do [[ -f "$f" ]] && basename "$f" .heartbeat; done; fi
} | grep -vE '\.tmp\.[0-9]+$' | sort -u) || true
if [[ -z "$names" ]]; then echo "loops none"; exit 0; fi

out=() acts=() rc=0
add_act() {   # add_act STATE NAME: group names per state, in first-seen order
  local i
  for i in ${acts[@]+"${!acts[@]}"}; do
    if [[ "${acts[$i]%%=*}" == "$1" ]]; then acts[i]="${acts[$i]},$2"; return; fi
  done
  acts+=("$1=$2")
}
while IFS= read -r nm; do
  hb="$state/loops/$nm.heartbeat" script="$state/bin/$nm"
  st=never last="-"
  if [[ -f "$hb" ]]; then
    b=$(cat "$hb")
    kv() { tr ' ' '\n' <<<"$b" | sed -n "s/^$1=//p" | sed -n '1p'; }
    bt=$(kv beat) bp=$(kv pid) bh=$(kv host) ev=$(kv every) en=$(kv ended)
    win=${stale:-}
    if [[ -z "$win" ]]; then
      if [[ "$ev" =~ ^[0-9]+$ ]] && ((ev > 0)); then win=$((ev * 3)); else win=1800; fi
    fi
    if [[ -n "$en" ]]; then st="ended:$en"
    elif [[ ! "$bt" =~ ^[0-9]+$ ]] || ((now - bt > win)); then st=stale
    elif [[ "$bh" == "$host" && "$bp" =~ ^[0-9]+$ ]] && ((bp > 0)) && ! kill -0 "$bp" 2>/dev/null; then st=dead
    else st=alive; fi
    [[ ! "$bt" =~ ^[0-9]+$ ]] || last="$(((now - bt) / 60))m"
  fi
  sp=$script
  if [[ ! -f "$script" ]]; then sp=missing; add_act missing "$nm"; rc=4; fi
  if [[ "$st" != alive ]]; then add_act "${st%%:*}" "$nm"; ((rc == 4)) || rc=3; fi
  out+=("loop $nm $st last_pass=$last script=$sp")
done <<<"$names"

if ((${#acts[@]})); then echo "loops act ${acts[*]}"; else echo "loops ok"; fi
printf '%s\n' "${out[@]}"
exit "$rc"
