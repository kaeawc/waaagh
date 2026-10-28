#!/usr/bin/env bash
# Run one validation command and keep a compact receipt, or check whether an earlier receipt may be
# reused. Logs and receipts live OUTSIDE the checkout, so writing them never changes the measured
# tree.
#
# Usage: validate.sh run   --dir P --cmd CMD --runner NAME [--independent] [ENV...] [--store DIR]
#        validate.sh check --dir P --cmd CMD [ENV...] [--max-age SECONDS] [--store DIR]
#   ENV          the declared environment, passed to fingerprint.sh --key: --env NAME,
#                --tool CMD, --input PATH, --env-manifest FILE (see fingerprint.sh)
#   --runner     who ran it (role or agent name); recorded in the receipt
#   --independent  the runner is not the author of the change under test (a validator, the lane
#                wrapper re-running codex's work). Only independent receipts are reusable; a
#                receipt is never written from an implementer's own report.
#   --store      receipt store (default $ORCHESTRATE_VALIDATE_DIR, else
#                $ORCHESTRATE_STATE_DIR/validate, else ~/.claude/orchestrate/validate);
#                refused if it lies inside the checkout
#   --max-age    reuse window in seconds (default 86400)
# run   prints "PASS|FAIL|VOID exit=<n> key=<key> receipt=<path>", then a bounded excerpt of the log
#       for FAIL and VOID. VOID: the tree changed while the command ran; the result proves nothing.
#       Exit: 0 PASS | 1 FAIL | 3 VOID | 2 usage.
# check prints "reuse <receipt> runner=<name> age=<s>" (exit 0) or "fresh-needed: <reason>" (exit 1).
#       A missing, partial, failed, self-reported, stale or mismatched receipt needs a fresh run.
# Receipt (JSON, schema 1): key, command, env_signature, fingerprint_before, fingerprint_after,
#   exit, result, log, excerpt, runner, verification, started_at, finished_at, finished_epoch.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

usage() { sed -n '2,26p' "$0" >&2; exit 2; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
dir="" vcmd="" runner="" independent=no max_age=86400
store=${ORCHESTRATE_VALIDATE_DIR:-${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/validate}
envargs=()
while (($#)); do
  case "$1" in
    --dir) dir=$2; shift 2 ;;
    --cmd) vcmd=$2; shift 2 ;;
    --runner) runner=$2; shift 2 ;;
    --independent) independent=yes; shift ;;
    --env | --tool | --input | --env-manifest) envargs+=("$1" "$2"); shift 2 ;;
    --store) store=$2; shift 2 ;;
    --max-age) max_age=$2; shift 2 ;;
    -h | --help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "validate.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in run | check) ;; *) usage ;; esac
[[ -n "$dir" && -n "$vcmd" ]] || usage
[[ "$cmd" == check || -n "$runner" ]] || { echo "validate.sh: run needs --runner" >&2; exit 2; }
[[ "$max_age" =~ ^[0-9]+$ ]] || { echo "validate.sh: bad --max-age: $max_age" >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)
inside() { case "$1/" in "$dir"/*) echo "validate.sh: store $1 is inside the checkout; it would change the fingerprint" >&2; exit 2 ;; esac; }
[[ "$store" == /* ]] || store="$PWD/$store"
inside "$store"
mkdir -p "$store"
store=$(cd "$store" && pwd -P)
inside "$store"

key_of() { "$here/fingerprint.sh" --dir "$dir" --key "$vcmd" ${envargs[@]+"${envargs[@]}"}; }
key=$(key_of)
id=$(printf '%s' "$key" | git hash-object --stdin)
id=${id:0:16}
receipt="$store/receipts/$id.json"

if [[ "$cmd" == check ]]; then
  fresh() { echo "fresh-needed: $*"; exit 1; }
  [[ -f "$receipt" ]] || fresh "no receipt for $key"
  jq -e 'type == "object"' "$receipt" >/dev/null 2>&1 || fresh "unreadable receipt $receipt"
  why=$(jq -r --arg key "$key" '
    if .schema != 1 then "receipt schema \(.schema // "missing")"
    elif .key != $key then "key mismatch"
    elif (.finished_epoch | type) != "number" or (.exit | type) != "number" then "partial receipt"
    elif .fingerprint_before != .fingerprint_after then "tree changed during that run"
    elif .verification != "independent" then "self-reported result"
    elif .result != "pass" or .exit != 0 then "last result was \(.result) (exit \(.exit))"
    else "" end' "$receipt")
  [[ -z "$why" ]] || fresh "$why"
  age=$(($(orch_now) - $(jq -r .finished_epoch "$receipt")))
  ((age >= 0 && age <= max_age)) || fresh "receipt is ${age}s old (max $max_age)"
  echo "reuse $receipt runner=$(jq -r .runner "$receipt") age=${age}s"
  exit 0
fi

mkdir -p "$store/receipts" "$store/logs"
started=$(orch_now)
log="$store/logs/$id-$started.log"
rc=0
(cd "$dir" && bash -c "$vcmd") >"$log" 2>&1 </dev/null || rc=$?
after=$(key_of)
finished=$(orch_now)

if [[ "$after" != "$key" ]]; then result=void
elif ((rc == 0)); then result=pass
else result=fail; fi
excerpt=""
[[ "$result" == pass ]] || excerpt=$("$here/excerpt.sh" "$log" 2 40 4096)

tmp=$(mktemp "$store/receipts/.$id.XXXXXX")
jq -n --arg key "$key" --arg command "$vcmd" --arg after "$after" --argjson exit "$rc" \
  --arg result "$result" --arg log "$log" --arg excerpt "$excerpt" --arg runner "$runner" \
  --arg verification "$([[ "$independent" == yes ]] && echo independent || echo self)" \
  --arg started "$(orch_iso "$started")" --arg finished "$(orch_iso "$finished")" \
  --argjson finished_epoch "$finished" '
  {schema: 1, key: $key, command: $command,
   env_signature: ($key | split("|")[4]),
   fingerprint_before: ($key | split("|")[1]), fingerprint_after: ($after | split("|")[1]),
   exit: $exit, result: $result, log: $log, excerpt: $excerpt, runner: $runner,
   verification: $verification, started_at: $started, finished_at: $finished,
   finished_epoch: $finished_epoch}' >"$tmp"
mv "$tmp" "$receipt"

echo "$(tr '[:lower:]' '[:upper:]' <<<"$result") exit=$rc key=$key receipt=$receipt"
[[ -z "$excerpt" ]] || printf '%s\n' "$excerpt"
case "$result" in pass) exit 0 ;; fail) exit 1 ;; *) exit 3 ;; esac
