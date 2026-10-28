#!/usr/bin/env bash
# Cheap candidate lists for the hygiene bot. Candidates are leads to verify, never verdicts.
# Read-only.
#
# Usage: issue-candidates.sh fixed [--repo OWNER/REPO] [--since-days N]
#        issue-candidates.sh dupes [--repo OWNER/REPO] [--since-days N] [--min-score 0.5]
#                                  [--limit 25] [--per-issue 3]
#   fixed  open issues that a PR merged in the window says it closes, fixes or resolves.
#          TSV: issue  pr  merged_at  how(linked|body)  issue_title
#   dupes  open issues (updated in the window) whose titles share most of their words.
#          TSV: score  issue_a  issue_b  title_a  title_b
#          Issues whose titles have the same word set are one cluster row: issue_a is the lowest
#          number, issue_b lists the others (first 10, then +N) and title_b is "(same title words)".
#          Other pairs are ranked by score, then issue numbers; each issue appears in at most
#          --per-issue pair rows, and at most --limit rows are printed. A last "# " line gives the
#          counts and the path of the uncapped results file under <state dir>/candidates/.
# Defaults: --since-days 14.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" days=14 min=0.5 limit=25 per_issue=3
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --since-days) days=$2; shift 2 ;;
    --min-score) min=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --per-issue) per_issue=$2; shift 2 ;;
    *) echo "issue-candidates.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in fixed | dupes) ;; *) sed -n '2,18p' "$0" >&2; exit 2 ;; esac
repo=$(orch_repo "$repo")
since=$(jq -rn --argjson now "$(orch_now)" --argjson d "$days" '$now - $d * 86400 | strftime("%Y-%m-%d")')

case "$cmd" in
  fixed)
    issues=$(gh issue list --repo "$repo" --state open --limit 1000 --json number,title)
    gh pr list --repo "$repo" --state merged --limit 300 --search "merged:>=$since" \
      --json number,mergedAt,body,closingIssuesReferences |
      jq -r --argjson issues "$issues" '
        ($issues | map({key: (.number | tostring), value: .title}) | from_entries) as $open
        | [.[] | . as $pr
           | (([(.closingIssuesReferences // [])[] | {n: .number, how: "linked"}])
              + [(.body // "") | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s+#(\\d+)") | {n: (.[0] | tonumber), how: "body"}])
           | unique_by(.n)[] | select($open[.n | tostring])
           | [.n, $pr.number, $pr.mergedAt, .how, $open[.n | tostring]]]
        | sort_by(.[0])[] | @tsv'
    ;;
  dupes)
    # All leads, uncapped: cluster rows, then every pair of cluster representatives at or above
    # --min-score. Comparing one representative per word set keeps a repetitive cluster linear.
    all=$(gh issue list --repo "$repo" --state open --limit 400 --search "updated:>=$since sort:updated-desc" \
      --json number,title |
      jq -r --argjson min "$min" '
        def words: ascii_downcase | [scan("[a-z0-9]+")]
          | map(select(length > 2 and (IN("the", "and", "for", "with", "when", "not", "does", "from", "that", "this", "into", "after", "are", "but") | not)))
          | unique;
        def others: map(tostring) | if length > 10 then (.[0:10] | join(",")) + ",+\(length - 10)" else join(",") end;
        [.[] | {number, title, w: (.title | words)}] | sort_by(.number)
        | [group_by(.w)[] | sort_by(.number)] as $groups
        | [$groups[] | select(length > 1 and (.[0].w | length) > 0)
           | ["C", 1, .[0].number, (.[1:] | map(.number) | others), .[0].title, "(same title words)"]] as $clusters
        | [$groups[] | .[0]] | sort_by(.number) as $reps
        | [range(0; $reps | length) as $i | range($i + 1; $reps | length) as $j
           | $reps[$i] as $a | $reps[$j] as $b
           | (($a.w - ($a.w - $b.w)) | length) as $both
           | (($a.w + $b.w | unique) | length) as $either
           | select($either > 0) | ($both / $either) as $score | select($score >= $min)
           | ["P", ($score * 100 | round / 100), $a.number, $b.number, $a.title, $b.title]]
        | ($clusters | sort_by(.[2])) + (sort_by(-.[1], .[2], .[3]))
        | .[] | @tsv')
    out="$(orch_state_dir "$repo")/candidates"
    mkdir -p "$out"
    full="$out/dupes-$(orch_iso "$(orch_now)" | tr -d ':').tsv"
    if [[ -n "$all" ]]; then printf '%s\n' "$all" | cut -f2- >"$full"; else : >"$full"; fi
    # Shortlist: clusters first, then pairs in rank order, skipping a pair once either issue has
    # --per-issue pair rows already, until --limit rows.
    awk -F'\t' -v OFS='\t' -v limit="$limit" -v per="$per_issue" -v full="$full" '
      NF == 0 { next }
      { total++ }
      $1 == "C" { clusters++ }
      $1 == "P" { pairs++; if (seen[$3] >= per || seen[$4] >= per) { capped++; next } }
      shown < limit { if ($1 == "P") { seen[$3]++; seen[$4]++ }; shown++; $1 = ""; sub(/^\t/, ""); print; next }
      END {
        printf "# shown %d of %d leads (%d clusters, %d pairs; %d over the per-issue cap); all: %s\n",
          shown, total, clusters, pairs, capped, full
      }' <<<"$all"
    ;;
esac
