#!/usr/bin/env bash
# Relay ledger: every message the orchestrator sends a peer session, tracked as queued -> delivered
# -> acked -> done, so "sent" is never reported as "done". Doctrine: session-topology.md.
#
# Usage: relay.sh <command> [--repo OWNER/REPO] [options]
#   send --to PEER --text PLAN [--owner-quote WORDS] [--date YYYY-MM-DD] [--ref N]
#             record a new message (state queued), print its id on the first line and then the
#             body to pass to the messaging tool: the owner's words verbatim as a dated quote (when
#             given), the plan, and the reply contract "ACK <id>" / "DONE <id> <evidence>".
#   mark --id ID --state delivered|acked|done|failed [--evidence E] [--note N]
#             move a message forward. delivered: the peer started a turn that includes it (seen in
#             its events or reply); acked: the peer said it took it on; done: needs --evidence (a
#             PR, comment or commit URL, or a file:line); failed: it expired, was refused or the
#             peer ended without it. States only move forward.
#   reply --from PEER --text REPLY
#             read a peer's reply and apply every "ACK <id>" and "DONE <id> <evidence>" line in it
#             for messages sent to PEER; prints one "<id> <state>" line per change
#   say --id ID       one line for the owner, in exact words ("queued to triage, no receipt yet")
#   status [--open] [--to PEER]
#             id, peer, state, age in minutes, ref, summary per message (--open: not done/failed)
#   check [--ack-within MIN] [--done-within MIN]
#             open messages past their window: "overdue-ack" (queued or delivered longer than
#             --ack-within, default 30) or "overdue-done" (acked longer than --done-within, default
#             240), one line each
# State: <state dir>/relay.tsv (id, peer, state, sent_at, updated_at, ref, summary, evidence),
#        <state dir>/relay/<id>.txt (the body as sent), <state dir>/relay.log (every transition).
# Exit: 0 ok | 2 usage | 3 refused (unknown id, backward move, done without evidence, a reply
#       naming an id sent to another peer) | 4 check found overdue messages | 5 reply had no
#       ACK/DONE line for an open message of that peer
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  send | mark | reply | say | status | check) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  *) usage ;;
esac
repo="" to="" text="" quote="" date="" ref="" id="" new="" evidence="" note="" from="" open=no
ack_within=30 done_within=240
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --to) to=$2; shift 2 ;;
    --from) from=$2; shift 2 ;;
    --text) text=$2; shift 2 ;;
    --owner-quote) quote=$2; shift 2 ;;
    --date) date=$2; shift 2 ;;
    --ref) ref=${2#\#}; shift 2 ;;
    --id) id=$2; shift 2 ;;
    --state) new=$2; shift 2 ;;
    --evidence) evidence=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    --open) open=yes; shift ;;
    --ack-within) ack_within=$2; shift 2 ;;
    --done-within) done_within=$2; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "relay.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
peer_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; }
case "$cmd" in
  send) peer_ok "$to" && [[ -n "$text" ]] || usage
    [[ -z "$date" || "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    [[ -z "$ref" || "$ref" =~ ^[0-9]+$ ]] || usage ;;
  mark) [[ -n "$id" ]] || usage
    case "$new" in delivered | acked | done | failed) ;; *) usage ;; esac ;;
  reply) peer_ok "$from" && [[ -n "$text" ]] || usage ;;
  say) [[ -n "$id" ]] || usage ;;
  status) [[ -z "$to" ]] || peer_ok "$to" || usage ;;
  check) [[ "$ack_within" =~ ^[0-9]+$ && "$done_within" =~ ^[0-9]+$ ]] || usage ;;
esac
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
ledger=$state/relay.tsv
now=$(orch_now)
touch "$ledger"

flat() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-"${2:-200}"; }
rank() { case "$1" in queued) echo 1 ;; delivered) echo 2 ;; acked) echo 3 ;; done | failed) echo 4 ;; *) echo 0 ;; esac; }
row() { awk -F'\t' -v id="$1" '$1 == id' "$ledger"; }
field() { cut -f"$2" <<<"$1"; }
log() { printf '%s\t%s\t%s\t%s\t%s\n' "$(orch_iso "$now")" "$1" "$2" "$3" "$(flat "${4:-}" 300)" >>"$state/relay.log"; }

# transition ID STATE EVIDENCE NOTE: rewrite the row; refuses unknown ids and backward moves.
transition() {
  local r cur
  r=$(row "$1")
  [[ -n "$r" ]] || { echo "relay.sh: unknown id: $1" >&2; return 3; }
  cur=$(field "$r" 3)
  if [[ "$2" == "done" && -z "$3" ]]; then echo "relay.sh: done needs --evidence ($1)" >&2; return 3; fi
  if (($(rank "$2") < $(rank "$cur"))) || [[ "$cur" == "done" || "$cur" == failed ]]; then
    if [[ "$2" == "$cur" ]]; then echo "$1 $cur"; return 0; fi
    echo "relay.sh: $1 is $cur; refusing to move it to $2" >&2; return 3
  fi
  if [[ "$2" == "$cur" ]]; then echo "$1 $cur"; return 0; fi
  awk -F'\t' -v OFS='\t' -v id="$1" -v s="$2" -v t="$now" -v e="$(flat "$3" 300)" \
    '$1 == id { $3 = s; $5 = t; if (e != "") $8 = e } { print }' "$ledger" >"$ledger.tmp.$$" &&
    mv "$ledger.tmp.$$" "$ledger"
  log "$1" "$cur>$2" "$(field "$r" 2)" "${3:-$4}"
  echo "$1 $2"
}

send() {
  local n body
  n=$(awk -F'\t' '$1 ~ /^r[0-9]+$/ { v = substr($1, 2) + 0; if (v > m) m = v } END { print m + 1 }' "$ledger")
  id="r$n"
  [[ -n "$date" ]] || date=$(orch_iso "$now" | cut -c1-10)
  body=""
  if [[ -n "$quote" ]]; then
    body+="Owner ($date), verbatim:"$'\n'
    while IFS= read -r line || [[ -n "$line" ]]; do body+="> $line"$'\n'; done <<<"$quote"
    body+=$'\n'
  fi
  body+="$text"$'\n\n'
  body+="Reply \"ACK $id\" when you take this on and \"DONE $id <evidence: PR, comment or commit URL>\" when it is finished. [relay $id]"
  mkdir -p "$state/relay"
  printf '%s\n' "$body" >"$state/relay/$id.txt"
  printf '%s\t%s\tqueued\t%s\t%s\t%s\t%s\t\n' "$id" "$to" "$now" "$now" "${ref:+#$ref}" \
    "$(flat "${quote:+owner: }$text" 120)" >>"$ledger"
  log "$id" ">queued" "$to" "$text"
  echo "$id"
  printf '%s\n' "$body"
}

reply() {
  local line rid ev r rc=0 seen=0 any
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ (^|[^A-Za-z])(ACK|DONE)[[:space:]]+(r[0-9]+)([[:space:]:]+(.*))?$ ]]; then
      rid=${BASH_REMATCH[3]} ev=${BASH_REMATCH[5]}
      r=$(row "$rid")
      if [[ -z "$r" ]]; then echo "relay.sh: unknown id: $rid" >&2; rc=3; continue; fi
      if [[ "$(field "$r" 2)" != "$from" ]]; then
        echo "relay.sh: $rid was sent to $(field "$r" 2), not $from" >&2; rc=3; continue
      fi
      seen=1
      if [[ "${BASH_REMATCH[2]}" == ACK ]]; then
        transition "$rid" acked "" "reply" || rc=3
      else
        transition "$rid" "done" "$ev" "reply" || rc=3
      fi
    fi
  done <<<"$text"
  if ((seen == 0 && rc == 0)); then
    any=$(awk -F'\t' -v p="$from" '$2 == p && $3 != "done" && $3 != "failed"' "$ledger")
    if [[ -n "$any" ]]; then echo "no ACK/DONE line from $from; its open messages stay as they were"; return 5; fi
  fi
  return "$rc"
}

say() {
  local r st peer upd ev age
  r=$(row "$id")
  [[ -n "$r" ]] || { echo "relay.sh: unknown id: $id" >&2; exit 3; }
  st=$(field "$r" 3) peer=$(field "$r" 2) upd=$(field "$r" 5) ev=$(field "$r" 8)
  age=$(((now - upd) / 60))
  case "$st" in
    queued) echo "$id queued to $peer ${age}m ago; no receipt yet, not started" ;;
    delivered) echo "$id delivered to $peer (a turn started on it ${age}m ago); not acknowledged, not done" ;;
    acked) echo "$id acknowledged by $peer ${age}m ago; in progress, not done" ;;
    done) echo "$id done by $peer: $ev" ;;
    failed) echo "$id failed ($peer): not delivered or not acted on; resend or reroute" ;;
  esac
}

status() {
  awk -F'\t' -v OFS='\t' -v now="$now" -v open="$open" -v p="$to" '
    NF >= 7 && (p == "" || $2 == p) && (open == "no" || ($3 != "done" && $3 != "failed")) {
      print $1, $2, $3, int((now - $4) / 60) "m", ($6 == "" ? "-" : $6), $7; n++
    }
    END { if (n == 0) print "no relayed messages" }' "$ledger"
}

check() {
  local out
  out=$(awk -F'\t' -v OFS='\t' -v now="$now" -v a="$ack_within" -v d="$done_within" '
    ($3 == "queued" || $3 == "delivered") && now - $4 > a * 60 { print "overdue-ack", $1, $2, $3, int((now - $4) / 60) "m", $7 }
    $3 == "acked" && now - $5 > d * 60 { print "overdue-done", $1, $2, $3, int((now - $5) / 60) "m", $7 }' "$ledger")
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; return 4; fi
  echo "no overdue messages"
}

case "$cmd" in
  send) send ;;
  mark) transition "$id" "$new" "$evidence" "$note" ;;
  reply) reply ;;
  say) say ;;
  status) status ;;
  check) check ;;
esac
