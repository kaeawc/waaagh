#!/usr/bin/env bash
# One-call campaign snapshot for a recurring triage tick, plus the tick's few bookkeeping writes.
# The tick reads one compact verdict instead of five raw outputs (see roles/triage-tick.md).
#
# Usage: triage-tick.sh <snapshot|rerun|beat|cron> [--repo OWNER/REPO] [options]
#   snapshot [--branch B] [--ignore-workflow NAME]... [--classifier CMD] [--ready-label L]...
#            [--exclude-label L]... [--device-slots TYPE=N,...] [--loop-stale SECONDS] [--hold-hours H]
#     Refreshes main health (main-health.sh, so MAIN_RED is set or cleared as usual), classifies
#     each red run with CMD (run as `CMD --repo R --run ID`; the first word of its first line is the
#     verdict: flake, known-flake, infra, rerun or rerun-dont-fix are known, anything else is not;
#     any case, `_` = `-`; the shared orch_verdict_rerunnable in _lib.sh), and prints:
#       verdict ok | verdict act <reason>,...
#       main green ... | main red <sha> runs=<id>:<class>,... action=<rerun|fix-lane>
#            | main held rerun-pending runs=<id>,... | main unknown <reason>
#       prs open=<n|300+|unknown> [reviews=head:<n>,stale:<n>,none:<n> [changes-requested=#a,...]
#            | reviews=unknown]   last review per open PR from one gh-snapshot.sh call (which also
#            refreshes the per-head cache review-gate.sh check reads); omitted with no open PR.
#            The count comes from the open-PR read dispatch needs (gh-issues.sh prs-open, over REST
#            where GraphQL is refused); should that read fail there, from the snapshot.
#       reviewed-draft #<pr> review=<verdict|none> rollup=<state>: <mark ready?|held (until:<event>)
#                  |marked ready|mark-ready failed (why)>
#                  one line per draft PR whose latest internal review verdict (review-ledger.sh) is
#                  ship or whose checks are green (#205): pr-ready.sh skips drafts, so nothing else
#                  merges them. "held" when a hold or the release freeze names it (hold.sh). In
#                  autonomous mode (campaign.sh mode autonomous) a ship draft that no hold names, its
#                  verdict on the current head or on none named, is marked ready here (`gh pr ready`,
#                  or REST where GraphQL is refused; read back) and logged to <state dir>/drafts.log.
#       merge_loop <absent|alive|stale|dead|expired|ended:REASON> [beat_age=<s>] [deadline=<iso>]
#                  last_merge=<iso|-> pr=<n|-> merges_24h=<n>
#       shipped-blocked #<pr> verdict=<BLOCK|WAIT|BEHIND|SKIP|unlisted> reason=<detail>
#                  | shipped-blocked unknown
#                  one line per open, non-draft PR whose latest internal review verdict is ship
#                  (review-ledger.sh shipped) but whose pr-ready.sh row is not READY
#                  (shipped-blocked.sh, #269): the merge loop selects only READY rows, so an
#                  approved PR blocked by e.g. an unresolved thread (reason=threads=1) is named
#                  here. pr-ready.sh runs only when such a PR is open; flags for it (--author ...)
#                  come from ORCHESTRATE_PR_READY_ARGS. "unknown" when readiness could not be read.
#       dispatch <n|unknown> next=#a,#b,#c [list=truncated@1000]     open issues (any --ready-label;
#                  none of --exclude-label, default "blocked"; never the verify-on-main label,
#                  verify-on-main.sh) with no open PR closing them, no active
#                  lane and no live cloud dispatch (cloud-dispatch.sh ledger; over REST a PR closes
#                  what its body names with a closing keyword; see gh-issues.sh). list=truncated: the
#                  issue read hit its limit, so the count may be short (#259).
#       dispatch-stale redispatch=#a,...|- capped=#b,...|- unknown=#c,...|-   live cloud dispatches
#                  past ORCHESTRATE_DISPATCH_STALE_HOURS (6) whose issue is open with no PR
#                  (cloud-dispatch.sh stale): redispatch ones may be expired and sent again, capped
#                  ones reached ORCHESTRATE_DISPATCH_CAP (3) dispatches. Omitted with none.
#       slots <type>=<busy>/<n>,... | slots none
#       cron <none|age=<h>h expires_in=<h>h>
#       threads none | threads unknown
#             | threads unresolved=<n> answered=<n> resolve-now=#a,...|- repair=#b,...|- [stalled=#c,...]
#                  review threads on open PRs (thread-sweep.sh scan --summary): resolve-now PRs have
#                  every unresolved thread answered (an issue link or a pushed fix in the last reply);
#                  stalled PRs have a thread our own account answered after the head commit without
#                  naming a fix or an issue ("agreed", nothing pushed, #209)
#       host <ADMIT|HOLD|BACKOFF> cause=<indexing|lanes|other|-> free_gb=<g|unknown> load=<l> limit=<x>
#            | host unknown      lane admission on this host (host-load.sh --top 3; the command is
#                  ORCHESTRATE_HOST_LOAD, default host-load.sh beside this script)
#       orphans <n> worktrees=<name>(<n>)[,...]|- | orphans unknown
#                  leftover processes under the lane worktrees (spectra orphans --root <worktree
#                  root>, #332): parent gone, cwd in a worktree; by-design daemons left out. A
#                  removed worktree is named <name>(removed:<n>). Evidence only: nothing here kills.
#                  Omitted with no worktree root; "unknown" when spectra is missing or fails.
#       slot-stalled <pool> pid=<p> held=<m>m label=<l> | slot-stalled unknown pids=<p>,...
#                  one line per held gate, heavy or boot slot older than
#                  ORCHESTRATE_SLOT_STALL_MINUTES (10) whose holder and all its descendants are idle
#                  (spectra idle --pids, #333): a holder waiting on itself, or on nothing, holds every
#                  other lane's build back while kill -0 still calls it alive. "unknown" when spectra
#                  is missing or fails. Nothing is released or killed here.
#       holds n=<k> stale=<m>      merge-loop holds in <state dir>/holds (hold.sh); omitted with none.
#                  Then one line per hold older than --hold-hours (default
#                  ORCHESTRATE_HOLD_STALE_HOURS, 12) or of unknown age (an old-format line):
#       hold-stale #<pr> age=<h>h|unknown until:<event> reason=<text>
#       repairs inflight=#a,...|- settled=#b,...|- unknown=#c,...|-
#                  repair sessions in flight (review-ledger.sh settle, #212): settled ones posted
#                  their closing comment and now need a review of the final head; omitted with
#                  none in flight. Then one line per repair in flight longer than --hold-hours:
#       repair-stale #<pr> session:<id> since:<iso>
#       rounds #<pr>=<n>,...   fix rounds per open PR (review-ledger.sh rounds, #257); omitted with
#                  none. Then one line per PR at or past ORCHESTRATE_REVIEW_ROUND_CAP (default 2):
#       review-loop #<pr> rounds=<n> since=<iso> hours=<h> reviewed=<sha|->
#                  Then one line per repair in flight with a second writer since its dispatch, or
#                  whose commits could not be read (repair-writer.sh check, #214):
#       repair-writers two-writers|force-push|unknown #<pr> session:<id> ...
#     Reasons: main-red, flake-rerun, rerun-pending, main-unknown, merge-loop-<state> (only while PRs
#     are open), dispatch=<n> (only with a free device slot, or with no slot types configured),
#     issue-list-truncated, dispatch-stale=<n> (`cloud-dispatch.sh expire --issue N`, then dispatch
#     it again), dispatch-capped=<m> (route it to a local lane, or read why its sessions ended),
#     slot-stalled=<n> (an idle holder keeps a slot: message the lane named by its label to stop
#     that PID or say what it waits on; release nothing yourself),
#     orphans=<n> (leftover lane processes: tell the lane that started them to stop the PIDs it
#     recorded, or report them; kill nothing yourself),
#     host-hold (in place of dispatch=<n> while the host line is HOLD or BACKOFF; "host unknown"
#     holds nothing), cron-expiring (under 24h left), resolve-now=<n> (PRs whose threads only need
#     resolving: the local orchestrator resolves them, they are not repair targets), stalled=<n> (PRs
#     with an agreed but unpushed thread: dispatch a repair now, no session is still on it),
#     reviewed-draft=<n> (reviewed-draft lines not marked ready: mark them ready, or say why not),
#     shipped-blocked=<n> (shipped-blocked PR lines: clear each reason, e.g. resolve or repair its
#     threads, or report why it cannot merge),
#     hold-stale=<m> (holds past --hold-hours: check their release condition, `hold.sh check`),
#     repaired=<n> (repairs that ended: review the final head, then record the verdict),
#     repair-stale=<m> (check the session; if its run ended, `review-ledger.sh repaired --pr N`),
#     repair-writers=<n> (PRs under repair with another writer: stop the other session, read the
#     branch history, re-review the head),
#     review-loop=<m> (PRs past the round cap: decline the optional findings, file the rest, review
#     the delta from reviewed= at once; no further fix round, ../review-rounds.md). A part that
#     could not be read says "unknown"; never a guess.
#     Device slots: an active lanes.tsv row whose agent column reads "<type>:<agent>" holds one
#     <type> slot. Types and sizes: --device-slots or ORCHESTRATE_DEVICE_SLOTS (e.g.
#     android=2,ios=2,xcode=2). A rerun that is still running holds merges (MAIN_RED is rewritten),
#     even when main-health.sh judged an older completed run green.
#   rerun --run ID [--issue N] [--log FILE] [--check NAME] [--needs-only]
#     Re-runs the failed jobs of red run ID once (`gh run rerun --failed`), notes it on tracking
#     issue N, writes MAIN_RED (merges stay held until main is green) and logs to reruns.log. A run
#     already in reruns.log is never re-run again: a known flake that fails twice is a real red.
#     First it reads the run's failed-job log (FILE, else `gh run view ID --log-failed`) for a needs
#     dependency that did not succeed (`failure-triage.sh needs`, signatures for NAME, default the
#     run's workflow name). One found re-runs the whole run (`gh run rerun ID`, outcome `full-...`
#     in reruns.log) once per head SHA, even after a failed-jobs rerun of it; a second one on that
#     head is refused (exit 3): look at the runner pool. A log that cannot be read changes nothing.
#     --needs-only (for a main-red run, not a flake): only that full rerun; any other failure is
#     not re-run (exit 1) and goes to a fix lane.
#   beat --deadline EPOCH [--pid PID] | beat --end REASON
#     The merge-loop wrapper's heartbeat (<state dir>/merge-loop.beat): call it every iteration,
#     and with --end when the loop stops (e.g. --end bound when its time bound ends).
#   cron [--created EPOCH]
#     Record when the session cron for the tick was (re)created (default now); session crons expire
#     after 7 days (ORCHESTRATE_CRON_DAYS).
# Exit: 0 ok | 1 --needs-only and no needs dependency in the log | 2 usage | 3 rerun refused
#       (already re-run once; or re-run in full once on this head) | 5 GitHub refused the rerun |
#       9 unverified (a full rerun is due but the run's head SHA could not be read) |
#       6 rerun requested but the issue note failed
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal
# shellcheck source=_slots.sh
source "$here/_slots.sh"

usage() { orch_usage; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
case "$cmd" in -h | --help) usage; exit 0 ;; esac
repo="" branch="" classifier=${ORCHESTRATE_CLASSIFIER_CMD:-} device=${ORCHESTRATE_DEVICE_SLOTS:-}
loop_stale=1800 hold_hours=${ORCHESTRATE_HOLD_STALE_HOURS:-12} run_id="" issue="" deadline="" pid="" end="" created=""
log="" check="" needs_only=no
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
    --hold-hours) hold_hours=$2; shift 2 ;;
    --run) run_id=$2; shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --log) log=$2; shift 2 ;;
    --check) check=$2; shift 2 ;;
    --needs-only) needs_only=yes; shift ;;
    --deadline) deadline=$2; shift 2 ;;
    --pid) pid=$2; shift 2 ;;
    --end) end=$2; shift 2 ;;
    --created) created=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "triage-tick.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$hold_hours" =~ ^[0-9]+$ ]] || { echo "triage-tick.sh: --hold-hours must be a whole number" >&2; exit 2; }
# Issues whose fix merged without closing them wait for a check on main, not a lane (#258).
((${#exclude[@]})) || exclude=(blocked)
exclude+=("${ORCHESTRATE_VERIFY_ON_MAIN_LABEL:-verify-on-main}")
case "$cmd" in
  snapshot | cron) ;;
  rerun)
    [[ "$run_id" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
    [[ -z "$log" || -r "$log" ]] || { echo "triage-tick.sh: --log $log is not readable" >&2; exit 2; } ;;
  beat) [[ -n "$end" || "$deadline" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
orch_gh_api triage-tick.sh >/dev/null || exit 2
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
now=$(orch_now)
reruns="$state/reruns.log"
beatf="$state/merge-loop.beat"
cronf="$state/triage-cron"
json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }

# rerun_seen ID: the run's latest reruns.log record is anything but a refused rerun. An `intent`
# with no outcome (the answer was lost) counts as re-run: reconciled by the snapshot, never replayed.
rerun_seen() { orch_rerun_seen "$1"; }
# full_seen SHA: the latest full rerun on head SHA (either SHA a prefix of the other) was not refused.
full_seen() {
  [[ -f "$reruns" ]] && awk -F'\t' -v s="$1" '$NF ~ /^full-/ { for (i = 5; i < NF; i++) if ($i ~ /^head=/) {
      h = substr($i, 6); if (h != "" && (index(h, s) == 1 || index(s, h) == 1)) last = $NF } }
    END { exit !(last != "" && last !~ /^full-failed/) }' "$reruns"
}
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
    orch_run loops.sh heartbeat merge-loop --repo "$repo" ${end:+--end "$end"} --pid "${pid:-$PPID}" --every 600 >/dev/null || true
    echo "$line"
    exit 0 ;;
  cron)
    orch_journal "$cronf" "${created:-$now}"
    echo "cron created $(orch_iso "${created:-$now}")"
    exit 0 ;;
  rerun)
    # A needs dependency that did not succeed (failure-triage.sh needs, #230): a failed-jobs rerun
    # reads the same dependency result and fails again, so the whole run is re-run, once per head.
    logf=$log dep="" sha=""
    if [[ -z "$logf" ]]; then
      logf=$(mktemp "${TMPDIR:-/tmp}/triage-tick-log.XXXXXX")
      trap 'rm -f "$logf"' EXIT
      orch_run gh-read.sh -- run view "$run_id" --repo "$repo" --log-failed >"$logf" 2>/dev/null || : >"$logf"
    fi
    if [[ -s "$logf" ]]; then
      meta=$(orch_run gh-read.sh --json -- run view "$run_id" --repo "$repo" --json headSha,workflowName 2>/dev/null) || meta='{}'
      sha=$(jq -r '.headSha // empty' <<<"$meta" 2>/dev/null) || sha=""
      [[ -n "$check" ]] || check=$(jq -r '.workflowName // empty' <<<"$meta" 2>/dev/null) || check=""
      dep=$(orch_run failure-triage.sh needs --repo "$repo" --check "${check:-*}" --log "$logf" 2>/dev/null) || dep=""
    fi
    mode="" args=(--failed) headf=""
    if [[ -n "$dep" ]]; then
      dep=${dep#needs }
      [[ -n "$sha" ]] || { echo "unverified: run $run_id needs a full rerun (needs=${dep% *} result=${dep#* }) but its head SHA could not be read"; exit 9; }
      if full_seen "$sha"; then
        echo "refused: head ${sha:0:9} was already re-run in full and needs=${dep% *} still did not succeed (result=${dep#* }): a runner-pool question, not a rerun (failure-triage.md)"
        exit 3
      fi
      mode=full- args=() headf="head=$sha"$'\t'
    elif [[ "$needs_only" == yes ]]; then
      if [[ -s "$logf" ]]; then echo "none: run $run_id's failed-job log shows no needs dependency that did not succeed; not re-run"
      else echo "none: run $run_id's failed-job log could not be read; not re-run"; fi
      exit 1
    elif rerun_seen "$run_id"; then
      echo "refused: run $run_id was already re-run once; a second failure is a real red (fix lane)"
      exit 3
    fi
    rec() { printf '%s\trun=%s\tissue=%s\tat=%s\t%s%s\n' "$(orch_iso "$now")" "$run_id" "${issue:--}" "$now" "$headf" "$mode$1" >>"$reruns"; }
    rec intent
    if ! out=$(gh run rerun "$run_id" ${args[@]+"${args[@]}"} --repo "$repo" 2>&1); then
      rec "failed: ${out//$'\n'/ }"
      echo "failed: gh run rerun $run_id: ${out:0:200}"
      exit 5
    fi
    rec rerun-requested
    hold "red - rerun-pending run=$run_id"
    what="the failed jobs of run $run_id"
    if [[ -n "$mode" ]]; then
      what="every job of run $run_id (needs=${dep% *} result=${dep#* }: a failed-jobs rerun reads the same dependency result)"
      echo "rerun requested (full): run $run_id head ${sha:0:9}; needs=${dep% *} result=${dep#* }; merges held until main is green"
    else
      echo "rerun requested: run $run_id; merges held until main is green"
    fi
    if [[ -n "$issue" ]]; then
      body="Triage tick: re-ran $what (https://github.com/$repo/actions/runs/$run_id). Merges stay held until the default branch is green; a second failure of this run is treated as a real red."
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
mh=$(orch_run main-health.sh "${mh_args[@]}" 2>/dev/null) || true
mh=$(printf '%s\n' "$mh" | sed -n '$p')
case "$mh" in green\ *) mh_state=green ;; red\ *) mh_state=red ;; *) mh_state=unknown ;; esac

# Reruns requested in the last day that have not completed yet keep the hold.
pending=()
if [[ -f "$reruns" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    st=$(orch_run gh-read.sh --json -- run view "$id" --repo "$repo" --json status 2>/dev/null | jq -r '.status // empty') || st=""
    [[ "$st" == completed ]] || pending+=("$id")
  done < <(awk -F'\t' -v cut="$((now - 86400))" '$NF ~ /^(full-)?(intent$|rerun-requested$|note-failed)/ {
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
        cls=$(bash -c "$classifier"' "$@"' _ --repo "$repo" --run "$id" 2>/dev/null | awk 'NR == 1 { v = tolower($1); gsub(/_/, "-", v); gsub(/[^a-z-]/, "", v); print v }') || cls=""
        [[ -n "$cls" ]] || cls=unclassified
      else cls=unclassified; fi
      orch_verdict_rerunnable "$cls" || known=no
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
# issue read, both through gh-issues.sh: GraphQL, or REST where it is refused). Should the PR read fail
# where GraphQL is refused, the count is the snapshot's.
open=unknown dispatch=unknown next="-" reviews="" suspect=""
lanes_tsv=""
[[ ! -f "$state/lanes.tsv" ]] || lanes_tsv=$(cat "$state/lanes.tsv")
snap_rc=0
snap=$(orch_run gh-snapshot.sh --repo "$repo" --limit 300 --json 2>/dev/null) || snap_rc=$?
((snap_rc <= 1)) && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$snap" || snap=""
pr_rc=0
prs=$(orch_run gh-issues.sh prs-open --repo "$repo" --limit 300 --fields number,closingIssuesReferences 2>/dev/null) || pr_rc=$?
if ((pr_rc != 0)) && [[ -n "$snap" ]] && [[ "$(orch_gh_api triage-tick.sh)" == rest ]]; then
  open=$(jq -r --argjson t "$snap_rc" 'if $t == 1 or length >= 300 then "300+" else length end' <<<"$snap")
fi
if ((pr_rc == 0)); then
  open=$(jq -r 'if length >= 300 then "300+" else length end' <<<"$prs")
  ((${#exclude[@]})) || exclude=(blocked)
  # Cloud dispatches still live in cloud-dispatch.sh's ledger (issue, run_at): in flight, so not
  # waiting; one past ORCHESTRATE_DISPATCH_STALE_HOURS with no PR closing it is checked below (#259).
  cloud_live=""
  [[ ! -f "$state/cloud-sessions.tsv" ]] || cloud_live=$(awk -F'\t' -v OFS='\t' '$1 == "" || $5 == "repair" { next }
    $5 == "expired" { delete r[$1]; next } { r[$1] = $3 } END { for (k in r) print k, r[k] }' "$state/cloud-sessions.tsv")
  stale_cut=$(orch_iso "$((now - ${ORCHESTRATE_DISPATCH_STALE_HOURS:-6} * 3600))")
  # 1000, not 300: a limit under the open count hid the newest issues (#259); a full list says so.
  if issues=$(orch_run gh-issues.sh issues --repo "$repo" --limit 1000 --fields number,labels 2>/dev/null); then
    q=$(jq -r --slurpfile prs <(printf '%s\n' "$prs") --rawfile lanes <(printf '%s' "$lanes_tsv") \
      --rawfile cloud <(printf '%s' "$cloud_live") --arg cut "$stale_cut" \
      --argjson ready "$(json_list ${ready[@]+"${ready[@]}"})" --argjson exclude "$(json_list "${exclude[@]}")" '
      def has_any($set): any(.[]; . as $l | $set | index($l));
      ([$prs[0][] | (.closingIssuesReferences // [])[] | .number]) as $in_pr
      | ([$lanes | split("\n")[] | select(length > 0 and (startswith("#") | not)) | split("\t")
          | select(length >= 6 and (.[5] | IN("done", "merged", "closed", "abandoned") | not))
          | .[2] | split(",")[] | gsub("[^0-9]"; "") | select(length > 0) | tonumber]) as $laned
      | ([$cloud | split("\n")[] | split("\t") | select(length >= 2 and (.[0] | test("^[0-9]+$")))
          | {n: (.[0] | tonumber), at: .[1]}]) as $live
      | (length >= 1000) as $full
      | [.[].number] as $open
      | [$live[] | select(.at < $cut) | .n
         | select(. as $n | ($open | index($n)) and ($in_pr | index($n) | not) and ($laned | index($n) | not))]
        as $suspect
      | [.[] | ([(.labels // [])[].name]) as $l
         | select(($ready | length) == 0 or ($l | has_any($ready)))
         | select($l | has_any($exclude) | not)
         | .number | select(. as $n | ($in_pr | index($n) | not) and ($laned | index($n) | not)
             and ([$live[].n] | index($n) | not))]
      | sort | "\(length) \(if length == 0 then "-" else (.[0:3] | map("#\(.)") | join(",")) end)"
        + (if $full then " list=truncated@1000" else "" end)
        + "\t\($suspect | sort | map(tostring) | join(" "))"' <<<"$issues")
    suspect=${q#*$'\t'} q=${q%%$'\t'*}
    dispatch=${q%% *} next=${q#* }
  fi
fi
[[ "$next" != *" list=truncated@"* ]] || reasons+=("issue-list-truncated")
# Stale cloud dispatches (#259): each suspect above gets cloud-dispatch.sh stale (REST reads).
dstale=""
if [[ -n "${suspect:-}" ]]; then
  st_rc=0
  # shellcheck disable=SC2086 # issue numbers, one word each
  st=$(orch_run cloud-dispatch.sh stale --repo "$repo" $suspect 2>/dev/null) || st_rc=$?
  ((st_rc == 0 || st_rc == 7)) || st=$(printf 'unknown #%s\n' $suspect)
  dstale=$(awk '$1 ~ /^(stale|capped|unknown)$/ { k[$1] = k[$1] (k[$1] == "" ? "" : ",") $2; n[$1]++ }
    END { if (n["stale"] + n["capped"] + n["unknown"] > 0)
      printf "dispatch-stale redispatch=%s capped=%s unknown=%s\t%d %d", (k["stale"] == "" ? "-" : k["stale"]),
        (k["capped"] == "" ? "-" : k["capped"]), (k["unknown"] == "" ? "-" : k["unknown"]), n["stale"], n["capped"] }' <<<"$st")
  if [[ -n "$dstale" ]]; then
    ds_n=${dstale#*$'\t'} dstale=${dstale%%$'\t'*}
    ((${ds_n% *} == 0)) || reasons+=("dispatch-stale=${ds_n% *}")
    ((${ds_n#* } == 0)) || reasons+=("dispatch-capped=${ds_n#* }")
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

# Drafts that look done (#205): pr-ready.sh skips every draft, so a draft with a ship verdict or
# green checks would sit unmerged and unreported. In autonomous mode a ship draft no hold names is
# marked ready: `gh pr ready` (GraphQL), else REST, then read back, since REST may keep the draft.
mark_ready() { # PR -> what the reviewed-draft line says; one drafts.log line either way
  local n=$1 out="" rc=0 via=graphql left
  if [[ "$(orch_gh_api triage-tick.sh)" == graphql ]]; then
    out=$(gh pr ready "$n" --repo "$repo" 2>&1) || rc=$?
    if ((rc != 0)) && orch_gh_refused 5 "$out"; then via=rest rc=0; fi
  else via=rest; fi
  [[ "$via" != rest ]] || out=$(gh api -X PATCH "repos/$repo/pulls/$n" -F draft=false 2>&1) || rc=$?
  if ((rc == 0)); then
    left=$(orch_run gh-read.sh --json -- api "repos/$repo/pulls/$n" 2>/dev/null | jq -r '.draft | if type == "boolean" then tostring else empty end') || left=""
    case "$left" in
      false) out="marked ready" ;;
      true) out="mark-ready failed (still a draft after the $via write: mark it ready elsewhere, e.g. GitHub MCP update_pull_request draft=false)" ;;
      *) out="mark-ready failed (unverified: the $via write returned, the PR could not be read back)" ;;
    esac
  else
    out=${out//$'\n'/ }
    out="mark-ready failed ($via: ${out:0:120})"
  fi
  printf '%s\tpr=%s\tvia=%s\t%s\n' "$(orch_iso "$now")" "$n" "$via" "$out" >>"$state/drafts.log" || true
  echo "$out"
}
drafts="" ndraft=0
if [[ -n "$snap" ]]; then
  mode=$(jq -r '.mode // "attended"' "$state/campaign.json" 2>/dev/null) || mode=attended
  while IFS=$'\t' read -r n head roll; do
    [[ -n "$n" ]] || continue
    row=$(orch_run review-ledger.sh latest --repo "$repo" --pr "$n" 2>/dev/null) || row=""
    IFS=$'\t' read -r _ _ v vhead _ <<<"$row" || true
    [[ "$v" == ship || "$roll" == SUCCESS ]] || continue
    what="mark ready?" hrc=0
    held=$(orch_hold_of "$repo" "$n") || hrc=$?
    if ((hrc == 2)); then what="held (the hold file could not be read)"
    elif ((hrc == 0)); then what="held ($(awk 'NR == 1 { print $2 }' <<<"$held"))"
    elif [[ "$v" == ship && "${vhead:--}" != - && "$head" != "$vhead"* && "$vhead" != "$head"* ]]; then
      what="mark ready? (the ship verdict is for ${vhead:0:9}, not the head)"
    elif [[ "$mode" == autonomous && "$v" == ship ]]; then
      what=$(mark_ready "$n")
    fi
    [[ "$what" == "marked ready" ]] || ndraft=$((ndraft + 1))
    drafts+="reviewed-draft #$n review=${v:-none} rollup=$roll: $what"$'\n'
  done < <(jq -r '.[] | select(.draft == true) | [.number, .head, .rollup] | @tsv' <<<"$snap")
fi
((ndraft == 0)) || reasons+=("reviewed-draft=$ndraft")

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

# Approved PRs the merge loop passes over (#269): open, non-draft, latest verdict ship, but not
# READY. pr-ready.sh runs only when there is such a candidate, so a campaign without one pays nothing.
shipped_lines=""
if [[ -n "$snap" ]] && sh_rows=$(orch_run review-ledger.sh shipped --repo "$repo" 2>/dev/null) && [[ -n "$sh_rows" ]]; then
  cands=$(jq -r --rawfile sh <(printf '%s\n' "$sh_rows") '
    ([$sh | split("\n")[] | select(length > 0) | split("\t")[0]]) as $s
    | [.[] | select(.draft != true) | .number | tostring | select(IN($s[]))] | unique_by(tonumber) | .[]' <<<"$snap")
  if [[ -n "$cands" ]]; then
    sb_args=(--repo "$repo")
    for c in $cands; do sb_args+=(--pr "$c"); done
    read -r -a pr_ready_args <<<"${ORCHESTRATE_PR_READY_ARGS:-}"
    [[ -z "$branch" ]] || pr_ready_args+=(--base "$branch")
    if shipped_lines=$(orch_run shipped-blocked.sh "${sb_args[@]}" -- ${pr_ready_args[@]+"${pr_ready_args[@]}"} 2>/dev/null); then
      [[ -z "$shipped_lines" ]] || reasons+=("shipped-blocked=$(awk 'END { print NR }' <<<"$shipped_lines")")
    else
      shipped_lines="shipped-blocked unknown"
    fi
  fi
fi

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

# Host admission (host-load.sh): refill lanes only while it says ADMIT. A failed read holds nothing.
host="host unknown" hl_rc=0
hl=$("${ORCHESTRATE_HOST_LOAD:-$here/host-load.sh}" --top 3 2>/dev/null) || hl_rc=$?
if ((hl_rc == 0 || hl_rc == 3 || hl_rc == 4)); then
  h=$(awk -F'\t' '$1 == "verdict" { v = $2 } $1 == "load" { l = $2; x = $3; sub(/.*limit /, "", x) }
      $1 == "memory" { g = $2 } $1 == "cause" { c = $2 }
      END { if (v ~ /^(ADMIT|HOLD|BACKOFF)$/) printf "host %s cause=%s free_gb=%s load=%s limit=%s", v, (c == "" ? "-" : c), (g == "" ? "unknown" : g), (l == "" ? "unknown" : l), (x == "" ? "unknown" : x) }' <<<"$hl")
  [[ -z "$h" ]] || host=$h
fi
if [[ "$dispatch" =~ ^[0-9]+$ ]] && ((dispatch > 0)) && [[ -z "$device" || "$free" == yes ]]; then
  case "$host" in "host HOLD "* | "host BACKOFF "*) reasons+=("host-hold") ;; *) reasons+=("dispatch=$dispatch") ;; esac
fi

# Stalled slots (#333): a held slot past the stall age whose holder and descendants are idle.
stalled="" cand=() pids=""
stall_min=${ORCHESTRATE_SLOT_STALL_MINUTES:-10}
for d in "$(slot_root)"/{gate,heavy,boot}/slot-*; do
  [[ -f "$d/holder" ]] && slot_live "$d" || continue
  [[ -n "$(find "$d/holder" -mmin "+$((stall_min - 1))" 2>/dev/null)" ]] || continue
  p=$(sed -n 1p "$d/holder") lbl=$(sed -n 3p "$d/holder")
  m=$(( ($(date +%s) - $(stat -f %m "$d/holder" 2>/dev/null || stat -c %Y "$d/holder")) / 60 ))
  pool=${d%/slot-*}; cand+=("${pool##*/} $p $m ${lbl:--}"); pids="${pids:+$pids,}$p"
done
if ((${#cand[@]})); then
  idle_pids="" irc=1
  if orch_spectra_require idle 2>/dev/null; then
    irc=0; ij=$(orch_spectra idle --pids "$pids" --min-age "${stall_min}m" --json 2>/dev/null) || irc=$?   # 3: some found
    ((irc != 0 && irc != 3)) || idle_pids=$(jq -er '.result.holders | arrays | .[].pid' <<<"$ij" 2>/dev/null) || ((irc == 0 && $? == 4)) || irc=1
  fi
  if ((irc == 0 || irc == 3)); then
    for c in "${cand[@]}"; do
      read -r pool p m lbl <<<"$c"
      grep -qx "$p" <<<"$idle_pids" || continue
      stalled+="slot-stalled $pool pid=$p held=${m}m label=$lbl"$'\n'
    done
    n=$(grep -c . <<<"$stalled" || true)
    ((n == 0)) || reasons+=("slot-stalled=$n")
  else
    stalled="slot-stalled unknown pids=$pids"$'\n'
  fi
fi

# Leftover lane processes (spectra orphans, #332): evidence for the report; nothing here kills.
orphans=""
if wtroot=$(orch_worktree_root); then
  orphans="orphans unknown"
  if orch_spectra_require orphans 2>/dev/null; then
    oj=$(orch_spectra orphans --json --root "$wtroot" 2>/dev/null) || true   # exit 3: some found
    o=$(jq -r '(.groups | arrays) as $g
      | [$g[] | {w: .worktree, rm: (.worktree_removed // false), n: ([.processes[]? | select(.daemon_by_design | not)] | length)} | select(.n > 0)] as $l
      | "orphans \($l | map(.n) | add // 0) worktrees=" + (if ($l | length) == 0 then "-"
          else ($l | map(if .rm then "\(.w)(removed:\(.n))" else "\(.w)(\(.n))" end) | join(",")) end)' <<<"$oj" 2>/dev/null) || o=""
    [[ -z "$o" ]] || orphans=$o
  fi
  case "$orphans" in "orphans 0 "* | "orphans unknown") ;; *) reasons+=("orphans=$(cut -d' ' -f2 <<<"$orphans")") ;; esac
fi

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
  t=$(orch_run thread-sweep.sh scan --summary --repo "$repo" 2>/dev/null) || true
  t=$(printf '%s\n' "$t" | sed -n '$p')
  [[ "$t" != "threads unresolved="* ]] || threads=$t
fi
rn=$(sed -n 's/.* resolve-now=\([^ ]*\).*/\1/p' <<<"$threads")
if [[ -n "$rn" && "$rn" != - ]]; then reasons+=("resolve-now=$(tr ',' '\n' <<<"$rn" | awk 'END { print NR }')"); fi
sp=$(sed -n 's/.* stalled=\([^ ]*\).*/\1/p' <<<"$threads")
if [[ -n "$sp" ]]; then reasons+=("stalled=$(tr ',' '\n' <<<"$sp" | awk 'END { print NR }')"); fi

# Merge-loop holds (hold.sh): count them and name every one past --hold-hours with its reason, so
# a hold whose condition passed but was never released is seen at the next tick (#196).
holds_line="" stale_holds=""
if hold_rows=$(orch_run hold.sh list --repo "$repo" 2>/dev/null) && [[ -n "$hold_rows" ]]; then
  stale_holds=$(orch_run hold.sh stale --repo "$repo" --hours "$hold_hours" 2>/dev/null) || true
  ns=0
  [[ -z "$stale_holds" ]] || ns=$(awk 'END { print NR }' <<<"$stale_holds")
  holds_line="holds n=$(awk 'END { print NR }' <<<"$hold_rows") stale=$ns"
  ((ns == 0)) || reasons+=("hold-stale=$ns")
fi

# Repairs in flight (review-ledger.sh, #212): each is settled against its closing comment, and one
# in flight past --hold-hours is named so its session is checked. Omitted with none in flight.
repairs_line="" stale_repairs="" writers=""
if fl=$(orch_run review-ledger.sh inflight --repo "$repo" 2>/dev/null) && [[ -n "$fl" ]]; then
  # A second writer on a PR under repair (#214), checked before settle ends any of them.
  writers=$(orch_run repair-writer.sh check --repo "$repo" 2>/dev/null | awk '$1 != "clear"') || true
  nw=$(awk '($1 == "two-writers" || $1 == "force-push") && !s[$2]++ { c++ } END { print c + 0 }' <<<"$writers")
  ((nw == 0)) || reasons+=("repair-writers=$nw")
  st=$(orch_run review-ledger.sh settle --repo "$repo" 2>/dev/null) || true
  cut=$(orch_iso "$((now - hold_hours * 3600))")
  repairs_line=$(awk '{ k[$1] = k[$1] (k[$1] == "" ? "" : ",") $2 }
    END { printf "repairs inflight=%s settled=%s unknown=%s", (k["inflight"] == "" ? "-" : k["inflight"]),
      (k["settled"] == "" ? "-" : k["settled"]), (k["unknown"] == "" ? "-" : k["unknown"]) }' <<<"$st")
  stale_repairs=$(awk -v cut="$cut" '$1 == "inflight" { t = $4; sub(/^since:/, "", t); if (t < cut) print $2 " " $3 " " $4 }' <<<"$st")
  ns=$(awk '$1 == "settled" { c++ } END { print c + 0 }' <<<"$st")
  ((ns == 0)) || reasons+=("repaired=$ns")
  [[ -z "$stale_repairs" ]] || reasons+=("repair-stale=$(awk 'END { print NR }' <<<"$stale_repairs")")
fi

# Fix rounds per open PR (#257, review-ledger.sh rounds): one at or past the cap is looping, each
# push drawing a new review round. Omitted when no open PR has had a fix round.
rounds_lines="" cap=${ORCHESTRATE_REVIEW_ROUND_CAP:-2}
if [[ -n "$snap" && "$cap" =~ ^[1-9][0-9]*$ ]] && rr=$(orch_run review-ledger.sh rounds --repo "$repo" 2>/dev/null) && [[ -n "$rr" ]]; then
  rounds_lines=$(jq -r --rawfile rr <(printf '%s\n' "$rr") --argjson cap "$cap" '[.[].number | tostring] as $open
    | [$rr | split("\n")[] | select(length > 0) | split("\t") | select(.[0] | IN($open[]))] as $r
    | select($r | length > 0)
    | ("rounds " + ($r | map("#\(.[0])=\(.[1])") | join(","))),
      ($r[] | select((.[1] | tonumber) >= $cap)
        | "review-loop #\(.[0]) rounds=\(.[1]) since=\(.[2]) hours=\(.[3]) reviewed=\(.[4][0:12])")' <<<"$snap") || rounds_lines=""
  nl=$(grep -c '^review-loop ' <<<"$rounds_lines" || true)
  ((nl == 0)) || reasons+=("review-loop=$nl")
fi

if ((${#reasons[@]})); then echo "verdict act $(IFS=,; echo "${reasons[*]}")"; else echo "verdict ok"; fi
echo "$main_line"
echo "prs open=$open${reviews:+ $reviews}"
[[ -z "$drafts" ]] || printf '%s' "$drafts"
echo "merge_loop $loop$loop_extra $last"
[[ -z "$shipped_lines" ]] || printf '%s\n' "$shipped_lines"
echo "dispatch $dispatch next=$next"
[[ -z "$dstale" ]] || echo "$dstale"
echo "slots $slots"
echo "cron $cron"
echo "$threads"
echo "$host"
[[ -z "$orphans" ]] || echo "$orphans"
[[ -z "$stalled" ]] || printf '%s' "$stalled"
[[ -z "$holds_line" ]] || echo "$holds_line"
[[ -z "$stale_holds" ]] || sed 's/^/hold-stale /' <<<"$stale_holds"
[[ -z "$repairs_line" ]] || echo "$repairs_line"
[[ -z "$stale_repairs" ]] || sed 's/^/repair-stale /' <<<"$stale_repairs"
[[ -z "$rounds_lines" ]] || printf '%s\n' "$rounds_lines"
[[ -z "$writers" ]] || sed 's/^/repair-writers /' <<<"$writers"
