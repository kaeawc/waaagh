#!/usr/bin/env bash
# Cheap candidate lists for the hygiene bot. Candidates are leads to verify, never verdicts.
# Read-only.
#
# Usage: issue-candidates.sh fixed [--repo OWNER/REPO] [--since-days N]
#        issue-candidates.sh dupes [--repo OWNER/REPO] [--since-days N] [--min-score 0.5]
#   fixed  open issues that a PR merged in the window says it closes, fixes or resolves.
#          TSV: issue  pr  merged_at  how(linked|body)  issue_title
#   dupes  pairs of open issues (updated in the window) whose titles share most of their words.
#          TSV: score  issue_a  issue_b  title_a  title_b
# Defaults: --since-days 14.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

cmd=${1:-}
[[ -n "$cmd" ]] && shift || true
repo="" days=14 min=0.5
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --since-days) days=$2; shift 2 ;;
    --min-score) min=$2; shift 2 ;;
    *) echo "issue-candidates.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in fixed | dupes) ;; *) sed -n '2,11p' "$0" >&2; exit 2 ;; esac
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
    gh issue list --repo "$repo" --state open --limit 400 --search "updated:>=$since sort:updated-desc" \
      --json number,title |
      jq -r --argjson min "$min" '
        def words: ascii_downcase | [scan("[a-z0-9]+")]
          | map(select(length > 2 and (IN("the", "and", "for", "with", "when", "not", "does", "from", "that", "this", "into", "after", "are", "but") | not)))
          | unique;
        [.[] | {number, title, w: (.title | words)}] as $all
        | [range(0; $all | length) as $i | range($i + 1; $all | length) as $j
           | $all[$i] as $a | $all[$j] as $b
           | (($a.w - ($a.w - $b.w)) | length) as $both
           | (($a.w + $b.w | unique) | length) as $either
           | select($either > 0) | ($both / $either) as $score | select($score >= $min)
           | [($score * 100 | round / 100), $a.number, $b.number, $a.title, $b.title]]
        | sort_by(-.[0])[] | @tsv'
    ;;
esac
