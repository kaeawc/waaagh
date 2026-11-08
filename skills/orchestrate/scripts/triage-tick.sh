#!/usr/bin/env bash
# One-call campaign snapshot for a recurring triage tick, plus the tick's few bookkeeping writes.
# The tick reads one compact verdict instead of five raw outputs (see roles/triage-tick.md).
#
# Usage: triage-tick.sh <snapshot|rerun|beat|cron> [--repo OWNER/REPO] [options]
#   snapshot [--branch B] [--ignore-workflow NAME]... [--classifier CMD] [--ready-label L]...
#            [--exclude-label L]... [--device-slots TYPE=N,...] [--loop-stale SECONDS]
#     Refreshes main health (main-health.sh, so MAIN_RED is set or cleared as usual), classifies
#     each red run with CMD (run as `CMD --repo R --run ID`; the first word of its first line is the
#     verdict: flake, known-flake or infra are known, anything else is not), and prints:
#       verdict ok | verdict act <reason>,...
#       main green ... | main red <sha> runs=<id>:<class>,... action=<rerun|fix-lane>
#            | main held rerun-pending runs=<id>,... | main unknown <reason>
#       prs open=<n|300+|unknown> [reviews=head:<n>,stale:<n>,none:<n> [changes-requested=#a,...]
#            | reviews=unknown]   last review per open PR from one gh-snapshot.sh call (which also
#            refreshes the per-head cache review-gate.sh check reads); omitted with no open PR.
#            The count comes from the `gh pr list` read that dispatch needs, or from the snapshot
#            (REST) when GraphQL is refused (dispatch is then unknown).
#       merge_loop <absent|alive|stale|dead|expired|ended:REASON> [beat_age=<s>] [deadline=<iso>]
#                  last_merge=<iso|-> pr=<n|-> merges_24h=<n>
#       dispatch <n|unknown> next=#a,#b,#c     open issues (any --ready-label; none of
#                  --exclude-label, default "blocked") with no open PR closing them and no active lane
#       slots <type>=<busy>/<n>,... | slots none
#       cron <none|age=<h>h expires_in=<h>h>
#       threads none | threads unknown
#             | threads unresolved=<n> answered=<n> resolve-now=#a,...|- repair=#b,...|-
#                  review threads on open PRs (thread-sweep.sh scan --summary): resolve-now PRs have
#                  every unresolved thread answered (an issue link or a pushed fix in the last reply)
#     Reasons: main-red, flake-rerun, rerun-pending, main-unknown, merge-loop-<state> (only while PRs
#     are open), dispatch=<n> (only with a free device slot, or with no slot types configured),
#     cron-expiring (under 24h left), resolve-now=<n> (PRs whose threads only need resolving: the
#     local orchestrator resolves them, they are not repair targets). A part that could not be read
#     says "unknown"; never a guess.
#     Device slots: an active lanes.tsv row whose agent column reads "<type>:<agent>" holds one
#     <type> slot. Types and sizes: --device-slots or ORCHESTRATE_DEVICE_SLOTS (e.g.
#     android=2,ios=2,xcode=2). A rerun that is still running holds merges (MAIN_RED is rewritten),
#     even when main-health.sh judged an older completed run green.
#   rerun --run ID [--issue N]
#     Re-runs the failed jobs of red run ID once (`gh run rerun --failed`), notes it on tracking
#     issue N, writes MAIN_RED (merges stay held until main is green) and logs to reruns.log. A run
#     already in reruns.log is never re-run again: a known flake that fails twice is a real red.
#   beat --deadline EPOCH [--pid PID] | beat --end REASON
#     The merge-loop wrapper's heartbeat (<state dir>/merge-loop.beat): call it every iteration,
#     and with --end when the loop stops (e.g. --end bound when its time bound ends).
#   cron [--created EPOCH]
#     Record when the session cron for the tick was (re)created (default now); session crons expire
#     after 7 days (ORCHESTRATE_CRON_DAYS).
# Exit: 0 ok | 2 usage | 3 rerun refused (already re-run once) | 5 GitHub refused the rerun |
#       6 rerun requested but the issue note failed
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal
# shellcheck source=_slots.sh
source "$here/_slots.sh"

usage() { sed -n '2,49p' "$0"; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
case "$cmd" in -h | --help) usage; exit 0 ;; esac
repo="" branch="" classifier=${ORCHESTRATE_CLASSIFIER_CMD:-} device=${ORCHESTRATE_DEVICE_SLOTS:-}
loop_stale=1800 run_id="" issue="" deadline="" pid="" end="" created=""
ignore=() ready=() exclude=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --ignore-workflow) ignore+=("$2"); shift 2 ;;
    --classifier) classifier=$2; shift 2 ;;
    --ready-label) ready+=("$2"); shift 2 ;;
    --exclude-label) exclude+=("$2"); shift 2 ;;
    --device-slots) device=$2; shift 2 ;;
    --loop-stale) loop_stale=$2; shift 2 ;;
    --run) run_id=$2; shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --deadline) deadline=$2; shift 2 ;;
    --pid) pid=$2; shift 2 ;;
    --end) end=$2; shift 2 ;;
    --created) created=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "triage-tick.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  snapshot | cron) ;;
  rerun) [[ "$run_id" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; } ;;
  beat) [[ -n "$end" || "$deadline" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
api=$(orch_gh_api triage-tick.sh) || exit 2
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
now=$(orch_now)
reruns="$state/reruns.log"
beatf="$state/merge-loop.beat"
cronf="$state/triage-cron"
json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }

# rerun_seen ID: the run's latest reruns.log record is anything but a refused rerun. An `intent`
# with no outcome (the answer was lost) counts as re-run: reconciled by the snapshot, never replayed.
rerun_seen() { [[ -f "$reruns" ]] && awk -F'\t' -v r="run=$1" '$2 == r { last = $NF } END { exit !(last != "" && last !~ /^failed/) }' "$reruns"; }
hold() { [[ -f "$state/MAIN_RED" ]] || printf '%s\n%s\n' "$1" "$(orch_iso "$now")" >"$state/MAIN_RED"; }

case "$cmd" in
  beat)
    if [[ -n "$end" ]]; then
      line="ended=$end at=$now"
      [[ ! -f "$beatf" ]] || line="$line $(tr '\n' ' ' <"$beatf" | sed -E 's/(^| )(ended|at)=[^ ]*//g; s/  +/ /g; s/^ //; s/ $//')"
    else
      line="beat=$now deadline=$deadline pid=${pid:-$PPID}"
    fi
    orch_journal "$beatf" "$line"
    "$here/loops.sh" heartbeat merge-loop --repo "$repo" ${end:+--end "$end"} --pid "${pid:-$PPID}" --every 600 >/dev/null || true
    echo "$line"
    exit 0 ;;
  cron)
    orch_journal "$cronf" "${created:-$now}"
    echo "cron created $(orch_iso "${created:-$now}")"
    exit 0 ;;
  rerun)
    if rerun_seen "$run_id"; then
      echo "refused: run $run_id was already re-run once; a second failure is a real red (fix lane)"
      exit 3
    fi
    rec() { printf '%s\trun=%s\tissue=%s\tat=%s\t%s\n' "$(orch_iso "$now")" "$run_id" "${issue:--}" "$now" "$1" >>"$reruns"; }
    rec intent
    if ! out=$(gh run rerun "$run_id" --failed --repo "$repo" 2>&1); then
      rec "failed: ${out//$'\n'/ }"
      echo "failed: gh run rerun $run_id: ${out:0:200}"
      exit 5
    fi
    rec rerun-requested
    hold "red - rerun-pending run=$run_id"
    echo "rerun requested: run $run_id; merges held until main is green"
    if [[ -n "$issue" ]]; then
      body="Triage tick: re-ran the failed jobs of run $run_id (https://github.com/$repo/actions/runs/$run_id), classified as a known flake. Merges stay held until the default branch is green; a second failure of this run is treated as a real red."
      if ! out=$(gh issue comment "$issue" --repo "$repo" --body "$body" 2>&1); then
        rec "note-failed issue=$issue"
        echo "note failed on issue $issue: ${out:0:200}"
        exit 6
      fi
      echo "noted on issue $issue"
    fi
    exit 0 ;;
esac

# ---- snapshot ----------------------------------------------------------------------------------
reasons=()

# Main health and the classifier verdict.
mh_args=(--repo "$repo")
[[ -z "$branch" ]] || mh_args+=(--branch "$branch")
for w in ${ignore[@]+"${ignore[@]}"}; do mh_args+=(--ignore-workflow "$w"); done
mh=$("$here/main-health.sh" "${mh_args[@]}" 2>/dev/null) || true
mh=$(printf '%s\n' "$mh" | sed -n '$p')
case "$mh" in green\ *) mh_state=green ;; red\ *) mh_state=red ;; *) mh_state=unknown ;; esac

# Reruns requested in the last day that have not completed yet keep the hold.
pending=()
if [[ -f "$reruns" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    st=$("$here/gh-read.sh" --json -- run view "$id" --repo "$repo" --json status 2>/dev/null | jq -r '.status // empty') || st=""
    [[ "$st" == completed ]] || pending+=("$id")
  done < <(awk -F'\t' -v cut="$((now - 86400))" '$NF == "intent" || $NF == "rerun-requested" || $NF ~ /^note-failed/ {
      at = $4; sub(/^at=/, "", at); if (at + 0 >= cut + 0) { r = $2; sub(/^run=/, "", r); if (!(r in s)) { s[r] = 1; print r } } }' "$reruns")
fi
pend_csv=$(IFS=,; echo "${pending[*]-}")

case "$mh_state" in
  red)
    sha=$(awk '{ print $2 }' <<<"$mh")
    runs="" known=yes
    for id in $(grep -oE '=[a-z_]+\([0-9]+\)' <<<"$mh" | tr -dc '0-9\n'); do
      if rerun_seen "$id"; then cls=rerun-failed
      elif [[ -n "$classifier" ]]; then
        cls=$(bash -c "$classifier"' "$@"' _ --repo "$repo" --run "$id" 2>/dev/null | awk 'NR == 1 { v = tolower($1); gsub(/[^a-z-]/, "", v); print v }') || cls=""
        [[ -n "$cls" ]] || cls=unclassified
      else cls=unclassified; fi
      case "$cls" in flake | known-flake | infra) ;; *) known=no ;; esac
      runs="${runs:+$runs,}$id:$cls"
    done
    if [[ -z "$runs" ]]; then known=no; fi
    if [[ "$known" == yes ]]; then action=rerun; reasons+=("flake-rerun"); else action=fix-lane; reasons+=("main-red"); fi
    main_line="main red $sha runs=${runs:--} action=$action${pend_csv:+ rerun-pending=$pend_csv}" ;;
  *)
    if [[ -n "$pend_csv" ]]; then
      hold "red - rerun-pending run=$pend_csv"
      main_line="main held rerun-pending runs=$pend_csv"
      reasons+=("rerun-pending")
    elif [[ "$mh_state" == green ]]; then
      main_line="main $mh"
    else
      main_line="main unknown ${mh#unknown }"
      [[ -n "$mh" ]] || main_line="main unknown main-health.sh gave no verdict"
      reasons+=("main-unknown")
    fi ;;
esac

# Open PRs: their last reviews from one gh-snapshot.sh call (it also refreshes the per-head cache
# review-gate.sh check reads), and the dispatch queue (one PR read for closing references, one
# issue read). Where GraphQL is refused the PR read cannot be made; the count is the snapshot's.
open=unknown dispatch=unknown next="-" reviews=""
lanes_tsv=""
[[ ! -f "$state/lanes.tsv" ]] || lanes_tsv=$(cat "$state/lanes.tsv")
snap_rc=0
snap=$("$here/gh-snapshot.sh" --repo "$repo" --limit 300 --json 2>/dev/null) || snap_rc=$?
((snap_rc <= 1)) && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$snap" || snap=""
pr_rc=0 pr_err=$(mktemp)
if [[ "$api" == rest ]]; then
  pr_rc=5
else
  prs=$("$here/gh-read.sh" --json -- pr list --repo "$repo" --state open --limit 300 --json number,closingIssuesReferences 2>"$pr_err") || pr_rc=$?
  ((pr_rc == 0)) || ! orch_gh_refused "$pr_rc" "$(cat "$pr_err")" || api=rest
fi
if [[ "$api" == rest && -n "$snap" ]]; then
  open=$(jq -r --argjson t "$snap_rc" 'if $t == 1 or length >= 300 then "300+" else length end' <<<"$snap")
fi
rm -f "$pr_err"
if ((pr_rc == 0)); then
  open=$(jq -r 'if length >= 300 then "300+" else length end' <<<"$prs")
  ((${#exclude[@]})) || exclude=(blocked)
  if issues=$("$here/gh-read.sh" --json -- issue list --repo "$repo" --state open --limit 300 --json number,labels 2>/dev/null); then
    q=$(jq -r --argjson prs "$prs" --arg lanes "$lanes_tsv" \
      --argjson ready "$(json_list ${ready[@]+"${ready[@]}"})" --argjson exclude "$(json_list "${exclude[@]}")" '
      def has_any($set): any(.[]; . as $l | $set | index($l));
      ([$prs[] | (.closingIssuesReferences // [])[] | .number]) as $in_pr
      | ([$lanes | split("\n")[] | select(length > 0 and (startswith("#") | not)) | split("\t")
          | select(length >= 6 and (.[5] | IN("done", "merged", "closed", "abandoned") | not))
          | .[2] | split(",")[] | gsub("[^0-9]"; "") | select(length > 0) | tonumber]) as $laned
      | [.[] | ([.labels[].name]) as $l
         | select(($ready | length) == 0 or ($l | has_any($ready)))
         | select($l | has_any($exclude) | not)
         | .number | select(. as $n | ($in_pr | index($n) | not) and ($laned | index($n) | not))]
      | sort | "\(length) \(if length == 0 then "-" else (.[0:3] | map("#\(.)") | join(",")) end)"' <<<"$issues")
    dispatch=${q%% *} next=${q#* }
  fi
fi
if [[ "$open" != unknown && "$open" != 0 ]]; then
  reviews="reviews=unknown"
  [[ -z "$snap" ]] || reviews=$(jq -r 'if length == 0 then "" else
      "reviews=head:\(map(select(.reviewed == "head")) | length),stale:\(map(select(.reviewed == "stale")) | length)"
      + ",none:\(map(select(.reviewed == "none")) | length)"
      + ([.[] | select(.review == "CHANGES_REQUESTED") | "#\(.number)"] | if length > 0 then " changes-requested=" + join(",") else "" end)
    end' <<<"$snap")
fi

# Merge-loop liveness and the last merges.
loop=absent loop_extra=""
if [[ -f "$beatf" ]]; then
  b=$(cat "$beatf")
  kv() { tr ' ' '\n' <<<"$b" | sed -n "s/^$1=//p" | sed -n '1p'; }
  bt=$(kv beat) dl=$(kv deadline) bp=$(kv pid) en=$(kv ended)
  if [[ -n "$en" ]]; then loop="ended:$en"
  elif [[ "$dl" =~ ^[0-9]+$ ]] && ((now >= dl)); then loop=expired
  elif [[ "$bt" =~ ^[0-9]+$ ]] && ((now - bt > loop_stale)); then loop=stale
  elif [[ "$bp" =~ ^[0-9]+$ ]] && ((bp > 0)) && ! kill -0 "$bp" 2>/dev/null; then loop=dead
  else loop=alive; fi
  [[ ! "$bt" =~ ^[0-9]+$ ]] || loop_extra=" beat_age=$((now - bt))"
  [[ ! "$dl" =~ ^[0-9]+$ ]] || loop_extra="$loop_extra deadline=$(orch_iso "$dl")"
fi
last="last_merge=- pr=- merges_24h=0"
if [[ -f "$state/merges.log" ]]; then
  since=$(orch_iso "$((now - 86400))")
  last=$(awk -F'\t' -v since="$since" '$4 ~ /^merged/ { t = $1; p = $2; sub(/^pr=/, "", p); if ($1 >= since) n++ }
    END { printf "last_merge=%s pr=%s merges_24h=%d", (t == "" ? "-" : t), (p == "" ? "-" : p), n }' "$state/merges.log")
fi
if [[ "$loop" != alive && "$open" != unknown && "$open" != 0 ]]; then reasons+=("merge-loop-${loop%%:*}"); fi

# Free device slots by type.
slots="none" free=no
if [[ -n "$device" ]]; then
  slots=""
  IFS=, read -r -a types <<<"$device"
  for t in "${types[@]}"; do
    name=${t%%=*} n=${t#*=}
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "triage-tick.sh: bad --device-slots entry: $t" >&2; exit 2; }
    busy=$(awk -F'\t' -v ty="$name" '!/^#/ && NF >= 6 && $NF !~ /^(done|merged|closed|abandoned)$/ && index($5, ty ":") == 1 { c++ }
      END { print c + 0 }' <<<"$lanes_tsv")
    ((busy >= n)) || free=yes
    slots="${slots:+$slots,}$name=$busy/$n"
  done
fi
if [[ "$dispatch" =~ ^[0-9]+$ ]] && ((dispatch > 0)) && [[ -z "$device" || "$free" == yes ]]; then reasons+=("dispatch=$dispatch"); fi

# Session cron age (session crons expire after 7 days).
cron=none
if [[ -f "$cronf" ]] && c=$(sed -n 1p "$cronf") && [[ "$c" =~ ^[0-9]+$ ]]; then
  left=$((c + ${ORCHESTRATE_CRON_DAYS:-7} * 86400 - now))
  cron="age=$(((now - c) / 3600))h expires_in=$((left > 0 ? left / 3600 : 0))h"
  ((left >= 86400)) || reasons+=("cron-expiring")
fi

# Review threads on open PRs: all answered means resolve now, not a repair target (#70).
threads="threads unknown"
if [[ "$open" == 0 ]]; then
  threads="threads none"
elif [[ "$open" != unknown ]]; then
  t=$("$here/thread-sweep.sh" scan --summary --repo "$repo" 2>/dev/null) || true
  t=$(printf '%s\n' "$t" | sed -n '$p')
  [[ "$t" != "threads unresolved="* ]] || threads=$t
fi
rn=$(sed -n 's/.* resolve-now=\([^ ]*\).*/\1/p' <<<"$threads")
if [[ -n "$rn" && "$rn" != - ]]; then reasons+=("resolve-now=$(tr ',' '\n' <<<"$rn" | awk 'END { print NR }')"); fi

if ((${#reasons[@]})); then echo "verdict act $(IFS=,; echo "${reasons[*]}")"; else echo "verdict ok"; fi
echo "$main_line"
echo "prs open=$open${reviews:+ $reviews}"
echo "merge_loop $loop$loop_extra $last"
echo "dispatch $dispatch next=$next"
echo "slots $slots"
echo "cron $cron"
echo "$threads"
