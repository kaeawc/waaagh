#!/usr/bin/env bash
# Merge-readiness list: one verdict line per open PR this orchestrator may merge. Read-only.
#
# Usage: pr-ready.sh [--repo OWNER/REPO] [--author LOGIN]... [--base BRANCH]
#                    [--ignore-check NAME]... [--hold PR]... [--hold-label LABEL]
#                    [--exclude-label LABEL]... [--head-match REGEX]
#                    [--min-pass N] [--no-threads] [--delta] [--pr N]
# Output (TSV): number  verdict  head  mergeable  passed  detail
#   READY  mergeable, no pending check, no failed check, every required check passed, and no
#          unresolved review thread
#   WAIT   checks still pending (detail lists them)
#   BLOCK  detail gives EVERY reason, space separated: conflict | fail:<checks>
#          | missing-required:<checks> | few-checks=<n> | pending:<checks> | mergeable=<state>
#          | threads=<n> | threads=unknown (a page of review threads was unreadable)
#          | policy=unknown (required checks could not be read)
#          | checks=unknown (REST path: the PR's checks or mergeable state could not be read)
#          Review threads and policy are checked for BLOCK rows too, so a row whose only blocker
#          is a failed check really has no other: the admin path depends on that.
#   SKIP   draft | fork | hold | label:<label> | branch, then " ready-but-skipped" when the PR
#          would otherwise be READY (checks, review threads and policy are judged for it too)
# Selection is by author and base, never by branch name: a lane that names its branches
# differently is still judged. Exclusions are explicit and visible as SKIP rows: --hold PR,
# --hold-label (default hold), --exclude-label (repeatable; e.g. `dependencies` when dependabot
# PRs have their own lane) and --head-match REGEX (a jq regex the head branch must match;
# discouraged). A skipped PR that is otherwise READY is counted on the summary line, so a filter
# that hides ready work is seen every pass.
# Check identity is (provider type, workflow, name), with the Actions run and job ids taken from
# the details URL. Only a proven replacement supersedes an earlier result: within one run, a newer
# job id (a rerun attempt); across runs of the same workflow and check, only a CANCELLED result,
# by a newer run; a legacy status context, by its own newer status. Without a run id nothing is
# superseded, so every instance counts. A cancelled check otherwise counts as failed.
# --author defaults to the authenticated gh user; repeat it to add e.g. app/dependabot.
# --ignore-check drops an advisory check from every count (repeatable). --min-pass (default 1)
# guards against a PR whose checks have not been reported yet. --pr limits the output to one PR.
# Review threads of every READY or BLOCK PR are read in one batched GraphQL call (50 PRs per call), following every further page.
# Required checks come from rulesets and classic branch protection; a failed or malformed read of
# either blocks every otherwise READY PR. Read problems are written to
# <state dir>/diagnostics/pr-ready-<time>.log, named on the summary line.
# --delta prints only rows that differ from this invocation's previous run (same arguments; kept
# under <state dir>/snapshots/), a "<n> GONE" row for a PR no longer listed, or one "no-change"
# line. Everything is still fetched fresh; the delta only trims output. A snapshot is never
# authority to merge: pr-merge.sh re-checks the live PR.
# Every GitHub read goes through gh-read.sh (bounded retries, typed errors; read failures are
# recorded in the diagnostics file). The open-PR list (with statusCheckRollup) is heavy: when a
# page of 300 times out or returns a 5xx, it is retried with limits 120, 60 and 30, each fallback
# logged to stderr. Only when every limit fails, or on a non-transient error (auth, forbidden,
# not found), does it exit 3 with no verdicts.
# PR_READY_EXTRA="<n> <n>..." (and the --pr number) name PRs that must be classified even when a
# full page left them out, e.g. an old PR at the front of a serialized merge line: each one
# missing from a full page is read with `gh pr view` and classified like the rest.
# Last line on stderr: "open=<n> ready=<n>" (+ " ready-but-skipped=<n> skipped-by=<reason>:<n>,..."
# when a skipped PR is otherwise READY, + " changed=<n>" with --delta, + " truncated=yes"
# when the PR list hit its row limit, + " page=<limit>" when a smaller page was used,
# + " extra-unreadable=<n,...>", + " policy=unknown", + " api=rest", + " diagnostics=<path>").
# GraphQL refused (Claude Code cloud sessions answer it with HTTP 403): ORCHESTRATE_GH_API=auto
# (default) reads the PR list over GraphQL and, on a 403 that names GraphQL, does the whole pass
# over REST through gh-rest-pr.sh (summary " api=rest"); =rest skips the GraphQL attempt, =graphql
# never falls back. REST reads: the open list in pages of 100, then only for candidates (author
# and base match, not draft or fork, hold/label skips included) pulls/<n> for mergeable, the head's
# check-runs and status, actions/runs for workflow names when a check names an Actions run, and
# ccr/review_threads for each READY or BLOCK PR, PR_READY_REST_JOBS (default 4) PRs at a time. Draft and fork rows are not read: they show
# mergeable UNKNOWN and 0 passed. Verdicts are otherwise the same as over GraphQL.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

repo="" base="" hold_label="hold" head_match="" min_pass=1 threads=yes delta=no only_pr=""
all_args=("$@")
authors=() ignores=() holds=() excludes=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --author) authors+=("$2"); shift 2 ;;
    --base) base=$2; shift 2 ;;
    --ignore-check) ignores+=("$2"); shift 2 ;;
    --hold) holds+=("$2"); shift 2 ;;
    --hold-label) hold_label=$2; shift 2 ;;
    --exclude-label) excludes+=("$2"); shift 2 ;;
    --head-match) head_match=$2; shift 2 ;;
    --min-pass) min_pass=$2; shift 2 ;;
    --no-threads) threads=no; shift ;;
    --delta) delta=yes; shift ;;
    --pr) only_pr=$2; shift 2 ;;
    -h | --help) sed -n '2,62p' "$0"; exit 0 ;;
    *) echo "pr-ready.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
api=${ORCHESTRATE_GH_API:-auto}
case "$api" in auto | rest | graphql) ;; *) echo "pr-ready.sh: ORCHESTRATE_GH_API must be auto, rest or graphql" >&2; exit 2 ;; esac
repo=$(orch_repo "$repo")
((${#authors[@]})) || authors=("$(orch_author)")
[[ -n "$base" ]] || base=$(orch_default_branch "$repo")

json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }
authors_json=$(json_list "${authors[@]}")
ignores_json=$(json_list ${ignores[@]+"${ignores[@]}"})
holds_json=$(json_list ${holds[@]+"${holds[@]}"})
excludes_json=$(json_list ${excludes[@]+"${excludes[@]}"})
if [[ -n "$head_match" ]] && ! jq -en --arg re "$head_match" '"x" | test($re) | . or true' >/dev/null 2>&1; then
  echo "pr-ready.sh: --head-match is not a valid regex: $head_match" >&2; exit 2
fi

diag_dir="$(orch_state_dir "$repo")/diagnostics"
diag="$diag_dir/pr-ready-$(orch_iso "$(orch_now)" | tr -d ':')-$$.log"
mkdir -p "$diag_dir"
note() { # record a read problem in a diagnostics file; the verdicts carry only its category
  mkdir -p "$diag_dir"
  printf '%s\n' "$*" >>"$diag"
}

# Required check names from both protection mechanisms: repository rulesets and classic branch
# protection (the branch endpoint shows it to anyone with read access). A read that fails or
# returns something malformed is "unknown", never "none": the PR cannot be judged READY.
policy=known required='[]'
ghr() { "$here/gh-read.sh" --json -- "$@"; }   # bounded, typed, read-only
if out=$(ghr api "repos/$repo/rules/branches/$base" 2>>"$diag") &&
  r=$(jq -ce 'if type == "array" then [.[] | select(.type == "required_status_checks")
              | .parameters.required_status_checks[].context] else error("not an array") end' <<<"$out" 2>/dev/null); then
  required=$r
else
  policy=unknown; note "rulesets read failed for $base: ${out:0:500}"
fi
if out=$(ghr api "repos/$repo/branches/$base" 2>>"$diag") &&
  r=$(jq -ce 'if type == "object" and has("protected") then
                ((.protection.required_status_checks // {}) | [(.contexts // [])[], ((.checks // [])[] | .context)])
              else error("no protected field") end' <<<"$out" 2>/dev/null); then
  required=$(jq -cn --argjson a "$required" --argjson b "$r" '$a + $b | unique')
else
  policy=unknown; note "branch protection read failed for $base: ${out:0:500}"
fi

fields=number,author,isDraft,isCrossRepository,baseRefName,headRefName,headRefOid,mergeable,labels,statusCheckRollup
# Large pages of statusCheckRollup time out (HTTP 502/504) on busy repositories; smaller pages
# usually succeed. Only a transient (7) or malformed (8) read falls back; anything else is final.
limits=(300 120 60 30)
prs="" list_limit=""
for ((li = 0; li < ${#limits[@]}; li++)); do
  [[ "$api" != rest ]] || break
  lim=${limits[li]}
  tries=2; ((li < ${#limits[@]} - 1)) || tries=4   # the same size rarely recovers; the last gets more
  rc=0
  prs=$("$here/gh-read.sh" --json --tries "$tries" -- pr list --repo "$repo" --state open --limit "$lim" \
    --json "$fields" 2>"$diag_dir/.prlist-$$") || rc=$?
  err=$(cat "$diag_dir/.prlist-$$" 2>/dev/null || true); rm -f "$diag_dir/.prlist-$$"
  if ((rc == 0)); then list_limit=$lim; break; fi
  if ((rc == 5)) && [[ "$api" == auto && "$err" == *GraphQL* ]]; then api=rest; break; fi
  note "PR list at limit $lim unreadable (exit $rc): ${err:0:500}"
  if ((rc != 7 && rc != 8)) || ((li == ${#limits[@]} - 1)); then
    echo "pr-ready: the open PR list could not be read; no verdicts (diagnostics: $diag)" >&2
    exit 3
  fi
  echo "pr-ready: open PR list at limit $lim failed (exit $rc); retrying with limit ${limits[li + 1]}" >&2
done
rest="$here/gh-rest-pr.sh"
if [[ "$api" == rest ]]; then
  list_limit=300
  prs=$("$rest" list --repo "$repo" --limit "$list_limit" 2>"$diag_dir/.prlist-$$") || {
    note "REST PR list unreadable: $(awk 'NR<=3' "$diag_dir/.prlist-$$" 2>/dev/null)"; rm -f "$diag_dir/.prlist-$$"
    echo "pr-ready: the open PR list could not be read; no verdicts (diagnostics: $diag)" >&2
    exit 3
  }
  rm -f "$diag_dir/.prlist-$$"
fi
truncated=no
[[ "$(jq length <<<"$prs")" -lt "$list_limit" ]] || truncated=yes

# Named PRs a full page may have left out: read each one on its own and add it to the list.
extra_bad=""
if [[ "$truncated" == yes ]]; then
  for n in ${PR_READY_EXTRA:-} $only_pr; do
    [[ "$n" =~ ^[0-9]+$ ]] || { note "PR_READY_EXTRA: not a PR number: $n"; continue; }
    [[ "$(jq --argjson n "$n" 'any(.[]; .number == $n)' <<<"$prs")" == false ]] || continue
    if if [[ "$api" == rest ]]; then one=$("$rest" view --repo "$repo" --pr "$n" 2>"$diag_dir/.prview-$$")
       else one=$(ghr pr view "$n" --repo "$repo" --json "$fields,state" 2>"$diag_dir/.prview-$$"); fi &&
      jq -e 'type == "object" and has("number")' >/dev/null 2>&1 <<<"$one"; then
      prs=$(jq -c --argjson one "$one" 'if $one.state == "OPEN" then . + [$one | del(.state)] else . end' <<<"$prs")
    else
      note "PR $n (extra): unreadable: $(cat "$diag_dir/.prview-$$" 2>/dev/null | awk 'NR<=3')"
      extra_bad+="${extra_bad:+,}$n"
    fi
    rm -f "$diag_dir/.prview-$$"
  done
fi
# REST: the list carries neither checks nor mergeable. Read both for each candidate only (the PRs
# the verdict loop judges); a candidate whose reads fail becomes a BLOCK row "checks=unknown".
# rest_each SUBCOMMAND NUMBERS...: run `gh-rest-pr.sh SUBCOMMAND --pr N` for each number,
# PR_READY_REST_JOBS (default 4) at a time, into $restdir/<subcommand>-<n>.out|.err|.bad.
rest_each() {
  local sub=$1
  shift
  (($#)) || return 0
  printf '%s\n' "$@" | xargs -P "${PR_READY_REST_JOBS:-4}" -I{} sh -c \
    '"$1" "$2" --repo "$3" --pr "$4" $5 >"$6/$2-$4.out" 2>"$6/$2-$4.err" || : >"$6/$2-$4.bad"' \
    sh "$rest" "$sub" "$repo" {} "$( [[ "$sub" == view ]] && echo --checks)" "$restdir"
}
unread=""
if [[ "$api" == rest ]]; then
  restdir="$diag_dir/.rest-$$"; mkdir -p "$restdir"
  trap 'rm -rf "$restdir"' EXIT
  cands=()
  while IFS= read -r n; do [[ -z "$n" ]] || cands+=("$n"); done < <(jq -r --argjson authors "$authors_json" \
    --arg base "$base" --arg only_pr "$only_pr" '.[] | select($only_pr == "" or (.number | tostring) == $only_pr)
      | select((.author.login as $a | $authors | index($a)) and .baseRefName == $base
               and (.isDraft | not) and (.isCrossRepository | not)) | .number' <<<"$prs")
  rest_each view ${cands[@]+"${cands[@]}"}
  for n in ${cands[@]+"${cands[@]}"}; do
    [[ -f "$restdir/view-$n.bad" ]] || continue
    note "PR $n: REST checks or mergeable unreadable: $(awk 'NR<=3' "$restdir/view-$n.err")"
    unread+="$n "
  done
  prs=$(cat "$restdir"/view-*.out 2>/dev/null | jq -sc --argjson prs "$prs" '
    (map(select(type == "object" and has("number")) | {key: (.number | tostring), value: del(.state)}) | from_entries) as $by
    | $prs | map($by[.number | tostring] // .)')
fi
rows=$(jq -r --argjson authors "$authors_json" --argjson ignore "$ignores_json" --argjson holds "$holds_json" \
    --argjson required "$required" --arg base "$base" --arg hold_label "$hold_label" \
    --argjson excludes "$excludes_json" --arg head_match "$head_match" \
    --argjson min_pass "$min_pass" --arg only_pr "$only_pr" '
    def norm: . as $c | (($c.conclusion // "") | if . == "" then ($c.state // $c.status // "") else . end) | ascii_upcase;
    def kind: if IN("SUCCESS", "SKIPPED", "NEUTRAL") then "pass"
              elif IN("", "PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING", "REQUESTED") then "pending"
              else "fail" end;
    .[] | select($only_pr == "" or (.number | tostring) == $only_pr)
    | select(.author.login as $a | $authors | index($a)) | select(.baseRefName == $base)
    # Check identity: provider type, workflow and name, plus the Actions run and job ids from the
    # details URL. Only a proven replacement supersedes an earlier result (see the header).
    | ([(.statusCheckRollup // [])[]
        | ((.detailsUrl // .targetUrl // "") | (capture("/actions/runs/(?<r>[0-9]+)(/job/(?<j>[0-9]+))?") // {})) as $id
        | {name: (.name // .context), at: (.startedAt // .createdAt // ""),
           type: (.__typename // (if has("context") then "StatusContext" else "CheckRun" end)),
           wf: (.workflowName // ""), run: ($id.r // null | if . == null then null else tonumber end),
           job: ($id.j // null | if . == null then null else tonumber end),
           cancelled: ((.conclusion // "") == "CANCELLED"), k: (norm | kind)}]
        | map(select(.name as $n | $ignore | index($n) | not))
        # Newest Actions run per workflow, for superseding cancelled checks.
        | (map(select(.run != null)) | group_by(.wf) | map({key: .[0].wf, value: (map(.run) | max)}) | from_entries) as $newest_run
        | group_by([.type, .wf, .name])
        | map(if .[0].type == "StatusContext" then [sort_by(.at) | last]   # a status context is overwritten
              else
                # Same run: the newest job id is a rerun attempt and replaces the older ones.
                (map(select(.run != null)) | group_by(.run) | map(sort_by(.job // 0, .at) | last)) as $per_run
                | ($per_run | map(.run) | max) as $last_run
                # Across runs only a cancellation is superseded, by a newer run of the same check.
                | ($per_run | map(select((.cancelled and .run < $last_run) | not)))
                  + map(select(.run == null))   # no run identity: nothing proves a replacement
              end)
        | flatten
        # A cancelled matrix template ("job (${{ matrix.x }})") is replaced by a newer run of its workflow.
        | map(select((.cancelled and (.name | contains("${{")) and .run != null
                      and (($newest_run[.wf] // 0) > .run)) | not))) as $checks
    | ($checks | map(select(.k == "pass") | .name) | unique) as $pass
    | ($checks | map(select(.k == "pending") | .name) | unique) as $pend
    | ($checks | map(select(.k == "fail") | .name) | unique) as $fail
    | ($required - $ignore - $pass - $pend - $fail) as $missing
    # An explicit exclusion; the PR is still judged so a ready one can be reported.
    | ([.labels[].name] as $l
       | if (.number as $n | $holds | map(tonumber) | index($n)) or ($l | index($hold_label)) then "hold"
         elif ([$l[] | select(. as $x | $excludes | index($x))] | first) != null then
           "label:" + ([$l[] | select(. as $x | $excludes | index($x))] | first)
         elif $head_match != "" and ((.headRefName // "") | test($head_match) | not) then "branch"
         else null end) as $skip
    | (([ (if .mergeable == "CONFLICTING" then "conflict" else empty end),
            (if ($fail | length) > 0 then "fail:" + ($fail | join(",")) else empty end),
            (if ($missing | length) > 0 and ($pend | length) == 0 then "missing-required:" + ($missing | join(",")) else empty end),
            (if ($pass | length) < $min_pass and ($pend | length) == 0 then "few-checks=\($pass | length)" else empty end)
          ]) as $block
         | if ($block | length) > 0 then
             # Keep the other dimensions next to the blockers instead of hiding them.
             ["BLOCK", ($block + [(if ($pend | length) > 0 then "pending:" + ($pend | join(",")) else empty end),
                                   (if IN(.mergeable; "MERGEABLE", "CONFLICTING") then empty else "mergeable=" + .mergeable end)]
                       | join(" "))]
           elif ($pend | length) > 0 or .mergeable != "MERGEABLE" then
             ["WAIT", (if ($pend | length) > 0 then "pending:" + ($pend | join(",")) else "mergeable=" + .mergeable end)]
           else ["READY", "-"] end) as $judged
    | (if .isDraft then ["SKIP", "draft", "-"]
       elif .isCrossRepository then ["SKIP", "fork", "-"]
       elif $skip != null then ["SKIP", $skip, $judged[0]]
       else $judged + ["-"] end) as $v
    # Column 7 (internal): the verdict a SKIP row would have had without its exclusion.
    | [.number, $v[0], .headRefOid[0:9], .mergeable, ($pass | length), $v[1], $v[2]] | @tsv' <<<"$prs" | sort -n)
if [[ -n "$unread" ]]; then
  rows=$(awk -F'\t' -v OFS='\t' -v bad=" $unread" 'index(bad, " " $1 " ") {
      if ($2 == "SKIP") $7 = "-"; else { $2 = "BLOCK"; $6 = "checks=unknown" } } { print }' <<<"$rows")
fi

# Unresolved, current review threads per READY or BLOCK PR, in batched GraphQL calls; a PR with
# more than one page is followed page by page through its cursor. Prints "number<TAB>count", where
# count is "unknown" when any page of that PR could not be read.
thread_counts() {
  local q n
  q='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){'
  for n in "$@"; do
    q+=" p$n: pullRequest(number:$n){reviewThreads(first:100){pageInfo{hasNextPage endCursor} nodes{isResolved isOutdated}}}"
  done
  q+='}}'
  # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
  { ghr api graphql -F owner="${repo%%/*}" -F name="${repo##*/}" -f query="$q" 2>>"$diag" || echo '{}'; } |
    jq -r --args '
      (.data.repository // {}) as $r
      | $ARGS.positional[] as $n | ($r["p" + $n] // null) as $pr
      | if $pr == null or $pr.reviewThreads == null then [$n, "unknown", ""]
        else [$n, ([$pr.reviewThreads.nodes[] | select((.isResolved | not) and (.isOutdated | not))] | length),
              (if $pr.reviewThreads.pageInfo.hasNextPage then ($pr.reviewThreads.pageInfo.endCursor // "?") else "" end)]
        end | @tsv' "$@" 2>/dev/null || printf '%s\tunknown\t\n' "$@"
}

# more_threads N COUNT CURSOR: add the unresolved threads on the pages after CURSOR.
more_threads() {
  local n=$1 count=$2 cursor=$3 page
  while [[ -n "$cursor" ]]; do
    [[ "$cursor" != "?" ]] || { note "PR $n: thread page without a cursor"; echo unknown; return; }
    # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
    page=$(ghr api graphql -F owner="${repo%%/*}" -F name="${repo##*/}" -F pr="$n" -f cursor="$cursor" -f query='
      query($owner:String!,$name:String!,$pr:Int!,$cursor:String!){repository(owner:$owner,name:$name){
        pullRequest(number:$pr){reviewThreads(first:100,after:$cursor){pageInfo{hasNextPage endCursor}
        nodes{isResolved isOutdated}}}}}' 2>>"$diag" |
      jq -r '.data.repository.pullRequest.reviewThreads
        | [([.nodes[] | select((.isResolved | not) and (.isOutdated | not))] | length),
           (if .pageInfo.hasNextPage then (.pageInfo.endCursor // "?") else "" end)] | @tsv' 2>/dev/null) ||
      { note "PR $n: review thread page after $cursor unreadable"; echo unknown; return; }
    [[ -n "$page" ]] || { note "PR $n: empty review thread page"; echo unknown; return; }
    count=$((count + ${page%%$'\t'*}))
    cursor=${page#*$'\t'}
  done
  echo "$count"
}

# Bash 3.2 compatible (macOS): no associative arrays or mapfile.
tcounts=""
if [[ "$threads" == yes ]]; then
  ready_nums=()
  while IFS= read -r n; do ready_nums+=("$n"); done < <(awk -F'\t' '$2 == "READY" || $2 == "BLOCK" || $7 == "READY" { print $1 }' <<<"$rows")
  if [[ "$api" == rest ]]; then
    rest_each threads ${ready_nums[@]+"${ready_nums[@]}"}
    for n in ${ready_nums[@]+"${ready_nums[@]}"}; do
      count=$(cat "$restdir/threads-$n.out" 2>/dev/null)
      if [[ -f "$restdir/threads-$n.bad" || ! "$count" =~ ^[0-9]+$ ]]; then
        note "PR $n: review threads unreadable over REST: $(awk 'NR<=3' "$restdir/threads-$n.err" 2>/dev/null)"; count=unknown
      fi
      tcounts+="$n"$'\t'"$count"$'\n'
    done
    ready_nums=()
  fi
  for ((i = 0; i < ${#ready_nums[@]}; i += 50)); do
    while IFS=$'\t' read -r n count cursor; do
      [[ -n "$n" ]] || continue
      if [[ "$count" == unknown ]]; then note "PR $n: review threads not returned"
      elif [[ -n "$cursor" ]]; then count=$(more_threads "$n" "$count" "$cursor"); fi
      tcounts+="$n"$'\t'"$count"$'\n'
    done < <(thread_counts "${ready_nums[@]:i:50}")
  done
fi

open=0 ready=0 skipped_ready=0 skipped_by=""
out=""
# Each row gains its review-thread count (column 8, empty when not read) in one awk pass, so the
# loop below starts no process per PR.
rows=$(awk -F'\t' -v OFS='\t' 'FNR == NR { if ($1 != "" && !($1 in c)) c[$1] = $2; next }
  { print $0, (($1 in c) ? c[$1] : "") }' <(printf '%s\n' "$tcounts") <(printf '%s\n' "$rows"))
while IFS=$'\t' read -r num verdict head mergeable passed detail inner tcount; do
  [[ -n "$num" ]] || continue
  open=$((open + 1))
  if [[ "$inner" == READY ]]; then   # excluded, but would be READY: same thread and policy rules
    n=0
    [[ "$threads" == no ]] || n=$tcount
    if [[ "$policy" == known && "${n:-unknown}" == 0 ]]; then
      detail+=" ready-but-skipped"
      skipped_ready=$((skipped_ready + 1))
      reason=${detail%% *}; skipped_by+="${reason%%:*}"$'\n'
    fi
  fi
  if [[ "$verdict" == READY || "$verdict" == BLOCK ]]; then
    extra=""
    [[ "$policy" == known ]] || extra+=" policy=unknown"
    if [[ "$threads" == yes ]]; then
      n=${tcount:-unknown}
      [[ "$n" == 0 ]] || extra+=" threads=$n"
    fi
    if [[ -n "$extra" ]]; then
      if [[ "$verdict" == READY ]]; then detail=${extra# }; else detail+=$extra; fi
      verdict=BLOCK
    fi
  fi
  [[ "$verdict" == READY ]] && ready=$((ready + 1))
  printf -v line '%s\t%s\t%s\t%s\t%s\t%s' "$num" "$verdict" "$head" "$mergeable" "$passed" "$detail"
  out+=$line$'\n'
done <<<"$rows"

summary="open=$open ready=$ready"
if ((skipped_ready)); then
  by=$(printf '%s' "$skipped_by" | sort | uniq -c | awk '{ printf "%s%s:%s", (NR > 1 ? "," : ""), $2, $1 }')
  summary+=" ready-but-skipped=$skipped_ready skipped-by=$by"
fi
if [[ "$delta" == yes ]]; then
  snaps="$(orch_state_dir "$repo")/snapshots"
  mkdir -p "$snaps"
  key=$(printf '%s\0' "$base" ${all_args[@]+"${all_args[@]}"} | git hash-object --stdin)
  snap="$snaps/pr-ready-${key:0:12}.tsv"
  [[ -f "$snap" ]] || : >"$snap"
  # Rows that are new or changed, then PRs that left the list.
  changes=$(awk -F'\t' 'FILENAME == ARGV[1] { old[$1] = $0; next }
    { seen[$1] = 1; if (old[$1] != $0) print }
    END { for (n in old) if (!(n in seen)) print n "\tGONE\t-\t-\t-\t-" }' "$snap" - <<<"${out%$'\n'}" | sort -n)
  printf '%s' "$out" >"$snap.tmp" && mv "$snap.tmp" "$snap"
  if [[ -n "$changes" ]]; then
    printf '%s\n' "$changes"
    summary+=" changed=$(wc -l <<<"$changes" | tr -d ' ')"
  else
    echo "no-change"
    summary+=" changed=0"
  fi
else
  printf '%s' "$out"
fi
[[ "$truncated" == no ]] || summary+=" truncated=yes"
[[ "$list_limit" == "${limits[0]}" ]] || summary+=" page=$list_limit"
[[ -z "$extra_bad" ]] || summary+=" extra-unreadable=$extra_bad"
[[ "$policy" == known ]] || summary+=" policy=unknown"
[[ "$api" != rest ]] || summary+=" api=rest"
if [[ -s "$diag" ]]; then summary+=" diagnostics=$diag"; else rm -f "$diag"; fi
echo "$summary" >&2
