#!/usr/bin/env bash
# Verify-on-main: open issues whose fix already merged in a PR that did not close them ("Part of
# #N" and other non-closing references, or a closing reference that did not close the issue). They
# need a device or product check on the default branch, not an implementation lane (#258).
#
# Usage: verify-on-main.sh scan  [--repo OWNER/REPO] [--label L] [--platform-prefix P]
#                                [--since-days N] [--checkout DIR] [--ref REF] [--branch B] [--apply]
#        verify-on-main.sh batch [same options, without --apply]
#   scan   one row per open issue that a PR merged in the window references, or that carries the
#          label already. TSV: state  issue  platforms  fix_refs  evidence  reason  title
#            verify    no verification result on a default-branch SHA covers it yet: route it to a
#                      verify batch, not to implementation
#            closable  a PASS result on a default-branch SHA, posted after the latest fix merged,
#                      covers every platform: evidence lists the result comment URL(s). Report it
#                      to the owner; nothing here closes an issue (close policy, #87)
#            failed    the latest result on a default-branch SHA after the fix is FAIL: it still
#                      needs implementation, so the label comes off
#            unknown   its comments could not be read: no change
#          A last "# " line counts the states and says how SHAs were checked (git REF, rest, none).
#          --apply puts the label on verify and closable rows that lack it and takes it off failed
#          rows (REST label writes, logged to <state dir>/verify-on-main.log). Without it, read-only.
#   batch  read-only. The verify rows grouped by platform, one single-pass verification lane each
#          (roles/verify-batch.md), then the closable rows:
#            batch  <platform|any>  #a,#b  fix_refs        a row for each platform still missing
#            closable  #n  -  <evidence URLs>
# Results: an issue comment line "Device verification: PASS|FAIL on <platform> ... at <SHA>"
# (roles/verify-batch.md), or the marker device-recheck.sh posts on linked issues
# ("<!-- waaagh:device-recheck verdict=pass|fail head=<SHA> -->", platform-less: it covers an issue
# with at most one platform). A result counts only when posted after the latest fix merged and its
# SHA is on the default branch: `git merge-base --is-ancestor` in --checkout (default .) against
# REF (default origin/HEAD, else HEAD) when that checkout has the commit, else the REST compare of
# the SHA with --branch (default: the repository's default branch).
# Platforms: an issue's labels starting with --platform-prefix (default
# $ORCHESTRATE_VERIFY_PLATFORM_PREFIX, else needs-local:), prefix dropped. A result "on W" covers
# platform P when W is P, or one is the other followed by "-..." (android covers android-emulator).
# References: closing keywords, a linked closing reference, or the non-closing words in
# $ORCHESTRATE_VERIFY_REF_WORDS (a regex alternation; default
# "part of|refs?|references|related to|towards?|addresses|follow-up to"), then #N.
# Label: --label, else $ORCHESTRATE_VERIFY_ON_MAIN_LABEL, else verify-on-main. Defaults:
# --since-days 180. Reads at most 1000 open issues and 1000 merged PRs, one comment page per issue.
# Exit: 0 ok | 2 usage | 4 issues or merged PRs could not be read | 5 a label write failed (rerun
#       finishes it)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority low

cmd=${1:-}
case "$cmd" in
  scan | batch) shift ;;
  -h | --help) orch_usage; exit 0 ;;
  -*) echo "verify-on-main.sh: unknown argument: $cmd" >&2; exit 2 ;;
  *) orch_usage >&2; exit 2 ;;
esac
repo="" days=180 checkout=. ref="" branch="" apply=no
label=${ORCHESTRATE_VERIFY_ON_MAIN_LABEL:-verify-on-main}
prefix=${ORCHESTRATE_VERIFY_PLATFORM_PREFIX:-needs-local:}
words=${ORCHESTRATE_VERIFY_REF_WORDS:-part of|refs?|references|related to|towards?|addresses|follow-up to}
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --platform-prefix) prefix=$2; shift 2 ;;
    --since-days) days=$2; shift 2 ;;
    --checkout) checkout=$2; shift 2 ;;
    --ref) ref=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --apply) [[ "$cmd" == scan ]] || { echo "verify-on-main.sh: --apply is for scan" >&2; exit 2; }
      apply=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "verify-on-main.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$days" =~ ^[0-9]+$ ]] || { echo "verify-on-main.sh: --since-days must be a whole number" >&2; exit 2; }
[[ -n "$label" ]] || { echo "verify-on-main.sh: the label is empty" >&2; exit 2; }
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
since=$(jq -rn --argjson now "$(orch_now)" --argjson d "$days" '$now - $d * 86400 | strftime("%Y-%m-%d")')
gi() { "$here/gh-issues.sh" "$1" --repo "$repo" "${@:2}"; }
read_fail() { echo "verify-on-main.sh: $1 could not be read" >&2; exit 4; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gi issues --limit 1000 --fields number,title,labels >"$tmp/issues" || read_fail "open issues"
gi prs-merged --limit 1000 --merged ">=$since" --fields number,title,body,mergedAt,closingIssuesReferences \
  >"$tmp/prs" || read_fail "merged PRs"

# Candidates: open issues a merged PR references, plus those labelled already.
jq -c --slurpfile prs "$tmp/prs" --arg label "$label" --arg prefix "$prefix" --arg words "$words" '
  def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
  def refs: [scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|" + $words + ")\\s*:?\\s+#(\\d+)") | .[0] | tonumber];
  ([$prs[0][] | {ref: "#\(.number)", t: (.mergedAt | epoch),
     refs: ([(.closingIssuesReferences // [])[].number] + (((.title // "") + "\n" + (.body // "")) | refs))}]) as $fixes
  | [.[] | .number as $n | ([(.labels // [])[].name]) as $l
     | [$fixes[] | select(any(.refs[]; . == $n))] as $f
     | select(($f | length) > 0 or ($l | index($label)))
     | {n: $n, title: (.title // ""), labelled: (($l | index($label)) != null),
        platforms: ([$l[] | select(startswith($prefix)) | ltrimstr($prefix)] | unique),
        refs: ($f | map(.ref) | unique), fixed_at: ([$f[].t] | max // 0)}]' "$tmp/issues" >"$tmp/cands" ||
  read_fail "open issues or merged PRs"

# Results on each candidate (one comment page each): {v, w, sha, t, url}.
: >"$tmp/unread"
echo '{}' >"$tmp/results"
for n in $(jq -r '.[].n' "$tmp/cands"); do
  if ! c=$(orch_read_retry 3 gh api "repos/$repo/issues/$n/comments?per_page=100") ||
    ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$c"; then
    echo "$n" >>"$tmp/unread"; continue
  fi
  printf '%s' "$c" >"$tmp/c"
  jq -c --slurpfile c "$tmp/c" --arg n "$n" '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    def verdict_re: "^[\\s>*_-]*device (?:verification|evidence)[*_]*\\s*:\\s*[*_]*\\s*(?<v>pass|fail)\\b(?<rest>.*)$";
    .[$n] = [$c[0][] | (.created_at | epoch) as $t | (.html_url // "-") as $url | (.body // "") as $b
      | ([$b | split("\n")[] | capture(verdict_re; "i")
          | {v: (.v | ascii_upcase), w: ((.rest | capture("^\\s*on\\s+(?<w>[A-Za-z0-9_.-]+)"; "i") | .w | ascii_downcase) // ""),
             sha: ((.rest | capture("\\bat\\s+`?(?<s>[0-9a-fA-F]{7,40})\\b") | .s | ascii_downcase) // "")}]
         + [$b | capture("<!-- waaagh:device-recheck verdict=(?<v>pass|fail) head=(?<s>[0-9a-f]{7,40}) -->")
          | {v: (.v | ascii_upcase), w: "", sha: .s}])[]
      | select(.sha != "") + {t: $t, url: $url}]' "$tmp/results" >"$tmp/r" && mv "$tmp/r" "$tmp/results"
done

# Is each result SHA on the default branch? git first, REST compare where the checkout lacks it.
how=none
if git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -z "$ref" ]]; then
    ref=HEAD
    if git -C "$checkout" rev-parse --verify -q origin/HEAD >/dev/null; then ref=origin/HEAD; fi
  fi
  git -C "$checkout" rev-parse --verify -q "$ref^{commit}" >/dev/null || ref=""
fi
: >"$tmp/onmain"
for sha in $(jq -r '[.[][] | .sha] | unique | .[]' "$tmp/results"); do
  on=unknown
  if [[ -n "$ref" ]] && git -C "$checkout" rev-parse --verify -q "$sha^{commit}" >/dev/null; then
    on=no
    if git -C "$checkout" merge-base --is-ancestor "$sha" "$ref" 2>/dev/null; then on=yes; fi
    case "$how" in none) how="git $ref" ;; rest) how="git $ref+rest" ;; esac
  else
    if [[ -z "$branch" ]]; then
      branch=$(orch_read_retry 3 gh api "repos/$repo" | jq -r '.default_branch // empty' 2>/dev/null) || branch=""
      [[ -n "$branch" ]] || branch=-
    fi
    if [[ "$branch" != - ]] && cmp=$(orch_read_retry 3 gh api "repos/$repo/compare/$sha...$branch"); then
      case "$(jq -r '.status // ""' <<<"$cmp" 2>/dev/null)" in identical | ahead) on=yes ;; behind | diverged) on=no ;; esac
      case "$how" in none) how=rest ;; git*) how="${how%+rest}+rest" ;; esac
    fi
  fi
  printf '%s %s\n' "$sha" "$on" >>"$tmp/onmain"
done
jq -Rn '[inputs | split(" ") | select(length == 2) | {key: .[0], value: .[1]}] | from_entries' \
  <"$tmp/onmain" >"$tmp/onmain.json"
jq -Rn '[inputs | select(length > 0) | tonumber]' <"$tmp/unread" >"$tmp/unread.json"

rows=$(jq -r --slurpfile res "$tmp/results" --slurpfile on "$tmp/onmain.json" --slurpfile unread "$tmp/unread.json" '
  def covers($w; $p): ($p | ascii_downcase) as $p | $w == $p or ($p | startswith($w + "-")) or ($w | startswith($p + "-"));
  def dash: if . == "" then "-" else . end;
  [.[] | . as $i | ($res[0]["\($i.n)"] // []) as $all
   | [$all[] | select(.t >= $i.fixed_at and $on[0][.sha] == "yes")] as $main
   # The latest main result on each platform; a platform-less result covers a single-platform issue.
   | (if ($i.platforms | length) == 0 then [{p: "any", r: ($main | last)}]
      else [$i.platforms[] as $p | {p: $p, r: ([$main[] | select((.w == "" and ($i.platforms | length) == 1) or (.w != "" and covers(.w; $p)))] | last)}]
      end) as $cov
   | ($cov | map(select(.r == null or .r.v != "PASS") | .p)) as $missing
   | (if ($unread[0] | index($i.n)) then ["unknown", "-", "comments could not be read"]
      elif any($cov[]; .r != null and .r.v == "FAIL") then
        ["failed", ([$cov[] | select(.r.v == "FAIL") | .r.url] | unique | join(",")),
         "FAIL on a default-branch SHA after the fix: " + ([$cov[] | select(.r.v == "FAIL") | .p] | join(","))]
      elif ($missing | length) == 0 then
        ["closable", ([$cov[].r.url] | unique | join(",")), "PASS on a default-branch SHA after the fix"]
      elif ($i.refs | length) == 0 then ["verify", "-", "labelled; no merged reference in the window; verify on " + ($missing | join(","))]
      else ["verify", "-", "fix merged; verify on " + ($missing | join(","))] end) as $s
   | [$s[0], $i.n, ($i.platforms | join(",") | dash), ($i.refs | join(",") | dash), $s[1], $s[2], ($i.title | dash),
      ($i.labelled | tostring), ($missing | join(",") | dash)]]
  | sort_by(.[0], .[1])[] | @tsv' "$tmp/cands")

count() { awk -F'\t' -v s="$1" '$1 == s { c++ } END { print c + 0 }' <<<"$rows"; }

if [[ "$cmd" == batch ]]; then
  awk -F'\t' -v OFS='\t' '
    $1 == "verify" { k = ($9 == "-") ? 0 : split($9, ps, ","); if (k == 0) { k = 1; ps[1] = "any" }
      for (i = 1; i <= k; i++) { p = ps[i]; if (!(p in is)) order[++np] = p
        is[p] = is[p] (is[p] == "" ? "" : ",") "#" $2
        if ($4 != "-") rf[p] = rf[p] (rf[p] == "" ? "" : ",") $4 } }
    $1 == "closable" { cl[++nc] = "closable" OFS "#" $2 OFS "-" OFS $5 }
    END { for (i = 1; i <= np; i++) { p = order[i]; print "batch", p, is[p], (rf[p] == "" ? "-" : rf[p]) }
      for (i = 1; i <= nc; i++) print cl[i] }' <<<"$rows"
  echo "# batches for $(count verify) issues; closable=$(count closable) failed=$(count failed) unknown=$(count unknown); label: $label; checked: $how"
  exit 0
fi

[[ -z "$rows" ]] || cut -f1-7 <<<"$rows"
added=0 removed=0 rc=0
if [[ "$apply" == yes && -n "$rows" ]]; then
  log() { printf '%s\t%s\n' "$(orch_iso "$(orch_now)")" "$1" >>"$state/verify-on-main.log"; }
  enc=$(jq -rn --arg s "$label" '$s | @uri')
  created=no
  while IFS=$'\t' read -r st n _ _ _ _ _ labelled _; do
    if [[ ("$st" == verify || "$st" == closable) && "$labelled" == false ]]; then
      if [[ "$created" == no ]]; then
        gh label create "$label" --repo "$repo" --color FBCA04 --force \
          --description "Fix merged without closing: verify on the default branch, do not implement" >/dev/null 2>&1 || true
        created=yes
      fi
      if gh api -X POST "repos/$repo/issues/$n/labels" -f "labels[]=$label" >/dev/null 2>&1; then
        added=$((added + 1)); log "add #$n $label ($st)"
      else echo "verify-on-main.sh: could not label #$n $label; rerun" >&2; rc=5; fi
    elif [[ "$st" == failed && "$labelled" == true ]]; then
      if gh api -X DELETE "repos/$repo/issues/$n/labels/$enc" >/dev/null 2>&1; then
        removed=$((removed + 1)); log "remove #$n $label (failed)"
      else echo "verify-on-main.sh: could not remove $label from #$n; rerun" >&2; rc=5; fi
    fi
  done <<<"$rows"
fi
extra=""
[[ "$apply" == no ]] || extra=" labelled=$added unlabelled=$removed"
echo "# verify=$(count verify) closable=$(count closable) failed=$(count failed) unknown=$(count unknown)$extra; label: $label; checked: $how"
exit "$rc"
