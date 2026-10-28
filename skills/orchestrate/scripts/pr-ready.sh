#!/usr/bin/env bash
# Merge-readiness list: one verdict line per open PR this orchestrator may merge. Read-only.
#
# Usage: pr-ready.sh [--repo OWNER/REPO] [--author LOGIN]... [--base BRANCH]
#                    [--ignore-check NAME]... [--hold PR]... [--hold-label LABEL]
#                    [--min-pass N] [--no-threads] [--delta] [--pr N]
# Output (TSV): number  verdict  head  mergeable  passed  detail
#   READY  mergeable, no pending check, no failed check, every required check passed, and no
#          unresolved review thread
#   WAIT   checks still pending (detail lists them)
#   BLOCK  detail gives EVERY reason, space separated: conflict | fail:<checks>
#          | missing-required:<checks> | few-checks=<n> | pending:<checks> | mergeable=<state>
#          | threads=<n> | threads=unknown (a page of review threads was unreadable)
#          | policy=unknown (required checks could not be read)
#          Review threads and policy are checked for BLOCK rows too, so a row whose only blocker
#          is a failed check really has no other: the admin path depends on that.
#   SKIP   draft | fork | hold
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
# recorded in the diagnostics file). An unreadable PR list exits 3 with no verdicts.
# Last line on stderr: "open=<n> ready=<n>" (+ " changed=<n>" with --delta, + " truncated=yes"
# when the PR list hit its 300-row limit, + " policy=unknown", + " diagnostics=<path>").
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" base="" hold_label="hold" min_pass=1 threads=yes delta=no only_pr=""
all_args=("$@")
authors=() ignores=() holds=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --author) authors+=("$2"); shift 2 ;;
    --base) base=$2; shift 2 ;;
    --ignore-check) ignores+=("$2"); shift 2 ;;
    --hold) holds+=("$2"); shift 2 ;;
    --hold-label) hold_label=$2; shift 2 ;;
    --min-pass) min_pass=$2; shift 2 ;;
    --no-threads) threads=no; shift ;;
    --delta) delta=yes; shift ;;
    --pr) only_pr=$2; shift 2 ;;
    -h | --help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "pr-ready.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo=$(orch_repo "$repo")
((${#authors[@]})) || authors=("$(orch_author)")
[[ -n "$base" ]] || base=$(orch_default_branch "$repo")

json_list() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi; }
authors_json=$(json_list "${authors[@]}")
ignores_json=$(json_list ${ignores[@]+"${ignores[@]}"})
holds_json=$(json_list ${holds[@]+"${holds[@]}"})

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
if out=$(ghr api "repos/$repo/rules/branches/$base" 2>&1) &&
  r=$(jq -ce 'if type == "array" then [.[] | select(.type == "required_status_checks")
              | .parameters.required_status_checks[].context] else error("not an array") end' <<<"$out" 2>/dev/null); then
  required=$r
else
  policy=unknown; note "rulesets read failed for $base: ${out:0:500}"
fi
if out=$(ghr api "repos/$repo/branches/$base" 2>&1) &&
  r=$(jq -ce 'if type == "object" and has("protected") then
                ((.protection.required_status_checks // {}) | [(.contexts // [])[], ((.checks // [])[] | .context)])
              else error("no protected field") end' <<<"$out" 2>/dev/null); then
  required=$(jq -cn --argjson a "$required" --argjson b "$r" '$a + $b | unique')
else
  policy=unknown; note "branch protection read failed for $base: ${out:0:500}"
fi

list_limit=300
if ! prs=$(ghr pr list --repo "$repo" --state open --limit "$list_limit" \
  --json number,author,isDraft,isCrossRepository,baseRefName,headRefOid,mergeable,labels,statusCheckRollup 2>&1); then
  note "PR list unreadable: ${prs:0:500}"
  echo "pr-ready: the open PR list could not be read; no verdicts (diagnostics: $diag)" >&2
  exit 3
fi
truncated=no
[[ "$(jq length <<<"$prs")" -lt "$list_limit" ]] || truncated=yes
rows=$(jq -r --argjson authors "$authors_json" --argjson ignore "$ignores_json" --argjson holds "$holds_json" \
    --argjson required "$required" --arg base "$base" --arg hold_label "$hold_label" \
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
    | (if .isDraft then ["SKIP", "draft"]
       elif .isCrossRepository then ["SKIP", "fork"]
       elif (.number as $n | $holds | map(tonumber) | index($n)) or ([.labels[].name] | index($hold_label)) then ["SKIP", "hold"]
       else
         ([ (if .mergeable == "CONFLICTING" then "conflict" else empty end),
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
           else ["READY", "-"] end
       end) as $v
    | [.number, $v[0], .headRefOid[0:9], .mergeable, ($pass | length), $v[1]] | @tsv' <<<"$prs" | sort -n)

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
  while IFS= read -r n; do ready_nums+=("$n"); done < <(awk -F'\t' '$2 == "READY" || $2 == "BLOCK" { print $1 }' <<<"$rows")
  for ((i = 0; i < ${#ready_nums[@]}; i += 50)); do
    while IFS=$'\t' read -r n count cursor; do
      [[ -n "$n" ]] || continue
      if [[ "$count" == unknown ]]; then note "PR $n: review threads not returned"
      elif [[ -n "$cursor" ]]; then count=$(more_threads "$n" "$count" "$cursor"); fi
      tcounts+="$n"$'\t'"$count"$'\n'
    done < <(thread_counts "${ready_nums[@]:i:50}")
  done
fi

open=0 ready=0
out=""
while IFS=$'\t' read -r num verdict head mergeable passed detail; do
  [[ -n "$num" ]] || continue
  open=$((open + 1))
  if [[ "$verdict" == READY || "$verdict" == BLOCK ]]; then
    extra=""
    [[ "$policy" == known ]] || extra+=" policy=unknown"
    if [[ "$threads" == yes ]]; then
      n=$(awk -F'\t' -v n="$num" '$1 == n { print $2; exit }' <<<"$tcounts")
      n=${n:-unknown}
      [[ "$n" == 0 ]] || extra+=" threads=$n"
    fi
    if [[ -n "$extra" ]]; then
      if [[ "$verdict" == READY ]]; then detail=${extra# }; else detail+=$extra; fi
      verdict=BLOCK
    fi
  fi
  [[ "$verdict" == READY ]] && ready=$((ready + 1))
  out+=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$num" "$verdict" "$head" "$mergeable" "$passed" "$detail")$'\n'
done <<<"$rows"

summary="open=$open ready=$ready"
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
[[ "$policy" == known ]] || summary+=" policy=unknown"
if [[ -s "$diag" ]]; then summary+=" diagnostics=$diag"; else rm -f "$diag"; fi
echo "$summary" >&2
