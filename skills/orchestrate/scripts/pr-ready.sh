#!/usr/bin/env bash
# Merge-readiness list: one verdict line per open PR this orchestrator may merge. Read-only.
#
# Usage: pr-ready.sh [--repo OWNER/REPO] [--author LOGIN]... [--base BRANCH]
#                    [--ignore-check NAME]... [--hold PR]... [--hold-label LABEL]
#                    [--min-pass N] [--no-threads]
# Output (TSV): number  verdict  head  mergeable  passed  detail
#   READY  mergeable, no pending check, no failed check, every required check passed, and no
#          unresolved review thread
#   WAIT   checks still pending (detail lists them)
#   BLOCK  detail gives the reasons: conflict | fail:<checks> | missing-required:<checks>
#          | threads=<n> | few-checks=<n>
#   SKIP   draft | fork | hold
# A cancelled check counts as failed unless its workflow started a later run (superseded).
# --author defaults to the authenticated gh user; repeat it to add e.g. app/dependabot.
# --ignore-check drops an advisory check from every count (repeatable). --min-pass (default 1)
# guards against a PR whose checks have not been reported yet. Last line on stderr:
# "open=<n> ready=<n>".
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" base="" hold_label="hold" min_pass=1 threads=yes
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
    -h | --help) sed -n '2,18p' "$0"; exit 0 ;;
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

# Required check names from the rulesets that apply to the base branch (none found -> []).
required=$(gh api "repos/$repo/rules/branches/$base" 2>/dev/null |
  jq -c '[.[]? | select(.type == "required_status_checks")
          | .parameters.required_status_checks[].context] | unique' 2>/dev/null) || required='[]'
[[ -n "$required" ]] || required='[]'

rows=$(gh pr list --repo "$repo" --state open --limit 300 \
  --json number,author,isDraft,isCrossRepository,baseRefName,headRefOid,mergeable,labels,statusCheckRollup |
  jq -r --argjson authors "$authors_json" --argjson ignore "$ignores_json" --argjson holds "$holds_json" \
    --argjson required "$required" --arg base "$base" --arg hold_label "$hold_label" \
    --argjson min_pass "$min_pass" '
    def norm: . as $c | (($c.conclusion // "") | if . == "" then ($c.state // $c.status // "") else . end) | ascii_upcase;
    def kind: if IN("SUCCESS", "SKIPPED", "NEUTRAL") then "pass"
              elif IN("", "PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING", "REQUESTED") then "pending"
              else "fail" end;
    .[] | select(.author.login as $a | $authors | index($a)) | select(.baseRefName == $base)
    # Latest result per check name; a rerun supersedes the earlier run of the same check.
    | ([(.statusCheckRollup // [])[] | {name: (.name // .context), at: (.startedAt // .createdAt // ""),
          wf: (.workflowName // ""), cancelled: ((.conclusion // "") == "CANCELLED"), k: (norm | kind)}]
        | map(select(.name as $n | $ignore | index($n) | not))
        # A cancelled check is a superseded run when its workflow started anything later; drop it.
        | (map(select(.cancelled | not)) | group_by(.wf) | map({key: .[0].wf, value: (map(.at) | max)}) | from_entries) as $newest
        | map(select((.cancelled and (($newest[.wf] // "") > .at)) | not))
        | group_by(.name) | map(sort_by(.at) | last)) as $checks
    | ($checks | map(select(.k == "pass") | .name)) as $pass
    | ($checks | map(select(.k == "pending") | .name)) as $pend
    | ($checks | map(select(.k == "fail") | .name)) as $fail
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
         | if ($block | length) > 0 then ["BLOCK", ($block | join(" "))]
           elif ($pend | length) > 0 or .mergeable != "MERGEABLE" then
             ["WAIT", (if ($pend | length) > 0 then "pending:" + ($pend | join(",")) else "mergeable=" + .mergeable end)]
           else ["READY", "-"] end
       end) as $v
    | [.number, $v[0], .headRefOid[0:9], .mergeable, ($pass | length), $v[1]] | @tsv' | sort -n)

open=0 ready=0
while IFS=$'\t' read -r num verdict head mergeable passed detail; do
  [[ -n "$num" ]] || continue
  open=$((open + 1))
  if [[ "$verdict" == READY && "$threads" == yes ]]; then
    # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
    n=$(gh api graphql -F owner="${repo%%/*}" -F name="${repo##*/}" -F pr="$num" -f query='
      query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){
        pullRequest(number:$pr){reviewThreads(first:100){nodes{isResolved isOutdated}}}}}' |
      jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select((.isResolved | not) and (.isOutdated | not))] | length')
    if [[ "$n" != 0 ]]; then verdict=BLOCK detail="threads=$n"; fi
  fi
  [[ "$verdict" == READY ]] && ready=$((ready + 1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$verdict" "$head" "$mergeable" "$passed" "$detail"
done <<<"$rows"
echo "open=$open ready=$ready" >&2
