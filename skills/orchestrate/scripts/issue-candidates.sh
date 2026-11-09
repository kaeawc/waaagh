#!/usr/bin/env bash
# Cheap candidate lists for the hygiene bot and the local sweep. Candidates are leads to verify,
# never verdicts. Read-only.
#
# Usage: issue-candidates.sh fixed [--repo OWNER/REPO] [--since-days N]
#        issue-candidates.sh dupes [--repo OWNER/REPO] [--since-days N] [--min-score 0.5]
#                                  [--limit 25] [--per-issue 3]
#        issue-candidates.sh sweep [--repo OWNER/REPO] [--since-days N] [--route GLOB]
#                                  [--bucket A,B,C,D] [--limit 50] [--checkout DIR] [--ref REF]
#                                  [--drop-blocked]
#   fixed  open issues that a PR merged in the window says it closes, fixes or resolves.
#          TSV: issue  pr  merged_at  how(linked|body)  issue_title
#   dupes  open issues (updated in the window) whose titles share most of their words.
#          TSV: score  issue_a  issue_b  title_a  title_b
#          Issues whose titles have the same word set are one cluster row: issue_a is the lowest
#          number, issue_b lists the others (first 10, then +N) and title_b is "(same title words)".
#          Other pairs are ranked by score, then issue numbers; each issue appears in at most
#          --per-issue pair rows, and at most --limit rows are printed. A last "# " line gives the
#          counts and the path of the uncapped results file under <state dir>/candidates/.
#   sweep  sort open issues carrying a route label that matches --route (default 'needs-local:*'):
#            A  closeable: a merged fix, and a PASS device verdict after it on every platform
#            B  a merged fix; device verification still missing on some platform
#            C  no merged fix (still needs implementation), or a FAIL verdict after the fix
#            D  unclear: mentioned without a closing keyword, a PASS without a fix, unstructured
#               device evidence only, or a research route
#          A merged fix is a PR merged in the window that closes the issue (linked, or a closing
#          keyword in its body), or a commit in the window on REF (default origin/HEAD, else HEAD,
#          in the git checkout --checkout, default .) whose message closes it. A device verdict is
#          an issue comment line "Device verification: PASS|FAIL on <platform> ..." (see
#          roles/verify-batch.md). An issue needs every platform its needs-local:<type> labels name
#          (android-emulator -> android, ios-simulator -> ios, macos-xcode -> macos, else <type>).
#          TSV: bucket  issue  platforms  fix_refs  device  reason  title, sorted by bucket, then
#          platforms (so B rows group into one verify batch per platform), then issue. At most
#          --limit rows from the --bucket buckets; a last "# " line gives every bucket's count,
#          whether git history was used, and the uncapped results file under <state dir>/candidates/.
#          --drop-blocked runs open-blockers.sh (REST) on every C row: a row blocked by an open
#          issue moves to bucket "blocked" (reason "blocked by #a #b"), listed after the other rows
#          and shown unless --bucket leaves "blocked" out; a row whose blockers could not be read
#          stays C with reason "...; blockers unverified (<what>)", never counted as clear. The
#          last line then also gives blocked=N unverified=N.
# Defaults: --since-days 14 (sweep: 180), --limit 25 (sweep: 50).
# Reads go through gh-issues.sh: GraphQL, or REST where GitHub refuses GraphQL (cloud sessions);
# over REST a merged PR's closing references come only from its body (how=body).
# Exit: 0 ok | 2 usage | 4 issues or merged PRs could not be read.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority low

cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" days="" min=0.5 limit="" per_issue=3 route_glob='needs-local:*' buckets=A,B,C,D
checkout=. ref="" drop_blocked=no bucket_set=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --since-days) days=$2; shift 2 ;;
    --min-score) min=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --per-issue) per_issue=$2; shift 2 ;;
    --route) route_glob=$2; shift 2 ;;
    --bucket) buckets=$2; bucket_set=yes; shift 2 ;;
    --drop-blocked) drop_blocked=yes; shift ;;
    --checkout) checkout=$2; shift 2 ;;
    --ref) ref=$2; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "issue-candidates.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in
  fixed | dupes | sweep) ;;
  -h | --help) orch_usage; exit 0 ;;
  *) orch_usage >&2; exit 2 ;;
esac
if [[ -z "$days" ]]; then if [[ "$cmd" == sweep ]]; then days=180; else days=14; fi; fi
if [[ -z "$limit" ]]; then if [[ "$cmd" == sweep ]]; then limit=50; else limit=25; fi; fi
repo=$(orch_repo "$repo")
since=$(jq -rn --argjson now "$(orch_now)" --argjson d "$days" '$now - $d * 86400 | strftime("%Y-%m-%d")')
# Bounded, typed, read-only lists: GraphQL, or REST where GitHub refuses GraphQL.
gi() { "$here/gh-issues.sh" "$1" --repo "$repo" "${@:2}"; }
read_fail() { echo "issue-candidates.sh: $1 could not be read" >&2; exit 4; }
# Lists go to jq as files: one argument holds at most 128 KiB (bodies of 1000 PRs do not fit).
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

case "$cmd" in
  fixed)
    issues=$(gi issues --limit 1000 --fields number,title) || read_fail "open issues"
    merged=$(gi prs-merged --limit 300 --merged ">=$since" --fields number,mergedAt,body,closingIssuesReferences) ||
      read_fail "merged PRs"
    printf '%s' "$issues" >"$tmp/issues"
    jq -r --slurpfile issues "$tmp/issues" '
        ($issues[0] | map({key: (.number | tostring), value: .title}) | from_entries) as $open
        | [.[] | . as $pr
           | (([(.closingIssuesReferences // [])[] | {n: .number, how: "linked"}])
              + [(.body // "") | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s+#(\\d+)") | {n: (.[0] | tonumber), how: "body"}])
           | unique_by(.n)[] | select($open[.n | tostring])
           | [.n, $pr.number, $pr.mergedAt, .how, $open[.n | tostring]]]
        | sort_by(.[0])[] | @tsv' <<<"$merged"
    ;;
  dupes)
    # All leads, uncapped: cluster rows, then every pair of cluster representatives at or above
    # --min-score. Comparing one representative per word set keeps a repetitive cluster linear.
    listed=$(gi issues --limit 400 --since "$since" --fields number,title) || read_fail "open issues"
    all=$(jq -r --argjson min "$min" '
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
        | .[] | @tsv' <<<"$listed")
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
  sweep)
    listed=$(gi issues --limit 1000 --fields number,labels) || read_fail "open issues"
    # The route labels in use that match --route; then each one's issues with their comments.
    issues='[]'
    while IFS= read -r label; do
      [[ -n "$label" ]] || continue
      # shellcheck disable=SC2053  # --route is a glob on purpose
      [[ "$label" == $route_glob ]] || continue
      got=$(gi issues --label "$label" --limit 1000 --fields number,title,labels,comments) ||
        read_fail "issues labelled $label"
      printf '%s' "$got" >"$tmp/more"
      issues=$(jq -c --slurpfile more "$tmp/more" '. + $more[0] | unique_by(.number)' <<<"$issues")
    done < <(jq -r '[.[].labels[]?.name | select(startswith("needs-local:"))] | unique | .[]' <<<"$listed")
    prs=$(gi prs-merged --limit 1000 --merged ">=$since" --fields number,title,mergedAt,body,closingIssuesReferences) ||
      read_fail "merged PRs"
    # Commits on REF in the window: sha, commit date, message. No checkout -> PRs only.
    commits='[]' git_used=none
    if git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1; then
      if [[ -z "$ref" ]]; then
        ref=HEAD
        if git -C "$checkout" rev-parse --verify -q origin/HEAD >/dev/null; then ref=origin/HEAD; fi
      fi
      if log=$(git -C "$checkout" log --since="$since" --format='%h%x1f%ct%x1f%B%x1e' "$ref" 2>/dev/null); then
        commits=$(jq -Rsc 'split("\u001e") | map(ltrimstr("\n") | split("\u001f")
          | select(length == 3) | {sha: .[0], date: .[1], msg: .[2]})' <<<"$log")
        git_used=$ref
      fi
    fi
    printf '%s' "$issues" >"$tmp/issues"; printf '%s' "$prs" >"$tmp/prs"; printf '%s' "$commits" >"$tmp/commits"
    all=$(jq -rn --slurpfile issues "$tmp/issues" --slurpfile prs "$tmp/prs" --slurpfile commits "$tmp/commits" '
      $issues[0] as $issues | $prs[0] as $prs | $commits[0] as $commits
      | def closes: [scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s*:?\\s+#(\\d+)") | .[0] | tonumber];
      def mentions: [scan("#(\\d+)\\b") | .[0] | tonumber];
      def platform: if . == "android-emulator" then "android" elif . == "ios-simulator" then "ios"
        elif . == "macos-xcode" then "macos" else . end;
      def keywords: {android: "android|emulator|pixel", ios: "\\bios\\b|simulator|iphone|ipad",
        macos: "macos|xcode|\\bmac\\b"}[.] // .;
      def verdict_re: "^[\\s>*_-]*device (?:verification|evidence)[*_]*\\s*:\\s*[*_]*(?<v>pass|fail)\\b(?<rest>.*)$";
      def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
      ([$prs[] | {ref: "#\(.number)", t: (.mergedAt | epoch),
          closes: ([(.closingIssuesReferences // [])[].number] + ((.body // "") | closes)),
          mentions: (((.title // "") + "\n" + (.body // "")) | mentions)}]
       + [$commits[] | {ref: .sha, t: (.date | tonumber), closes: (.msg | closes), mentions: (.msg | mentions)}]) as $refs
      | [$issues[] | .number as $n
         | ([.labels[]?.name | select(startswith("needs-local:")) | ltrimstr("needs-local:") | platform] | unique) as $need
         | [$refs[] | select(any(.closes[]; . == $n))] as $fix
         | [$refs[] | select((any(.closes[]; . == $n) | not) and any(.mentions[]; . == $n))] as $weak
         | ([$fix[].t] | max // 0) as $fixed_at
         # Structured verdicts in comment order; a line naming no platform applies to a single-platform issue.
         | [.comments[]? | (.createdAt | epoch) as $t | (.body // "") | split("\n")[]
            | capture(verdict_re; "i") | {t: $t, v: (.v | ascii_upcase), rest}
            | . as $c | ([$need[] | select(. as $p | $c.rest | test($p | keywords; "i"))]
                         | if length == 0 and ($need | length) == 1 then $need else . end) as $on
            | $on[] | {p: ., v: $c.v, t: $c.t}] as $verdicts
         | ($need | map(. as $p | {key: $p, value: ([$verdicts[] | select(.p == $p and .t >= $fixed_at)] | last | .v // "-")})
            | from_entries) as $current
         | [.comments[]? | (.body // "") | split("\n")[] | select(test(verdict_re; "i") | not)
            | select(test("\\b(?:verified|pass(?:ed|es)?)\\b"; "i")) | . as $line
            | $need[] | select(. as $p | $line | test($p | keywords; "i"))] as $loose
         | (if ($fix | length) > 0 then
              if any($need[]; . == "research") then ["D", "research route: confirm the measurement"]
              elif any($current[]; . == "FAIL") then ["C", "device FAIL after the fix"]
              elif all($current[]; . == "PASS") then ["A", "fix merged and PASS on every platform"]
              elif any($need[]; . as $p | $current[$p] != "PASS" and any($loose[]; . == $p)) then
                ["D", "unstructured device evidence: confirm"]
              else ["B", "fix merged; verify on " + ([$need[] | select($current[.] != "PASS")] | join(","))] end
            elif ($weak | length) > 0 then ["D", "mentioned without a closing keyword"]
            elif any($verdicts[]; .v == "PASS") then ["D", "device PASS without a merged fix"]
            else ["C", "no merged fix"] end) as $b
         | [$b[0], $n, ($need | join(",")),
            ((if ($fix | length) > 0 then $fix else $weak end) | map(.ref) | unique | join(",") | if . == "" then "-" else . end),
            ($need | map(. + ":" + $current[.]) | join(",")), $b[1], .title]]
      | sort_by(.[0], .[2], .[1])[] | @tsv')
    out="$(orch_state_dir "$repo")/candidates"
    mkdir -p "$out"
    full="$out/sweep-$(orch_iso "$(orch_now)" | tr -d ':').tsv"
    if [[ "$drop_blocked" == yes ]]; then
      # Blocker check on every C row. open-blockers.sh lines go to awk as a file; a check that
      # fails outright leaves every C row unverified, never clear.
      [[ "$bucket_set" == yes ]] || buckets="$buckets,blocked"
      : >"$tmp/blockers"
      cs=$(awk -F'\t' '$1 == "C" { print $2 }' <<<"$all")
      if [[ -n "$cs" ]]; then
        rc=0
        # shellcheck disable=SC2086  # issue numbers, one word each
        "$here/open-blockers.sh" --repo "$repo" $cs >"$tmp/blockers" || rc=$?
        case "$rc" in
          0 | 3 | 4) ;;
          *) echo "issue-candidates.sh: open-blockers.sh failed (exit $rc); C rows unverified" >&2
             awk '{ print $1 " unreadable blocker check" }' <<<"$cs" >"$tmp/blockers" ;;
        esac
      fi
      printf '%s\n' "$all" >"$tmp/all"
      # blocker line: "<n> BLOCKED by #a #b" | "<n> clear" | "<n> unreadable <what>"
      all=$(awk -F'\t' -v OFS='\t' '
        FILENAME == ARGV[1] { k = split($0, a, " "); if (k < 2) next
          r = ""; for (i = 3; i <= k; i++) r = r (r == "" ? "" : " ") a[i]
          st[a[1]] = a[2]; rest[a[1]] = r; next }
        NF == 0 { next }
        $1 == "C" && st[$2] == "BLOCKED" { $1 = "blocked"; r = rest[$2]; sub(/^by /, "", r)
          $6 = "blocked by " r; held[++h] = $0; next }
        $1 == "C" && st[$2] == "unreadable" { $6 = $6 "; blockers unverified (" rest[$2] ")" }
        { print }
        END { for (i = 1; i <= h; i++) print held[i] }' "$tmp/blockers" "$tmp/all")
    fi
    if [[ -n "$all" ]]; then printf '%s\n' "$all" >"$full"; else : >"$full"; fi
    awk -F'\t' -v limit="$limit" -v want="$buckets" -v full="$full" -v git="$git_used" -v drop="$drop_blocked" '
      BEGIN { n = split(want, w, ","); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
      NF == 0 { next }
      { count[$1]++ }
      $1 == "C" && index($6, "; blockers unverified (") { unverified++ }
      ($1 in keep) { matched++; if (shown < limit) { shown++; print } }
      END {
        more = drop == "yes" ? sprintf(" blocked=%d unverified=%d", count["blocked"], unverified) : ""
        printf "# A=%d B=%d C=%d D=%d%s; shown %d of %d in %s; git: %s; all: %s\n",
          count["A"], count["B"], count["C"], count["D"], more, shown, matched, want, git, full
      }' <<<"$all"
    ;;
esac
