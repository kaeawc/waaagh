#!/usr/bin/env bash
# Issue routing: every actionable open issue carries exactly ONE route label, so a local lane and a
# cloud lane never both take the same issue. Routes are `cloud-ready` and `needs-local:<type>`.
#
# Usage: issue-route.sh status [--repo OWNER/REPO] [--skip-label L]... [--limit N]
#        issue-route.sh labels [--repo OWNER/REPO] [--dry-run]
#        issue-route.sh set --issue N --route R [--what TEXT --requires TEXT [--type TEXT]]
#                           [--repo OWNER/REPO] [--skip-label L]... [--dry-run]
#   status  read-only. Route counts, then the issues that break the invariant. TSV rows:
#             count  <route|unrouted|multi|skipped>  N
#             unrouted  number  labels  title     (actionable, no route label; oldest first)
#             multi     number  routes  title     (more than one route label)
#           At most --limit (default 200) unrouted and multi rows each; counts are always complete.
#   labels  create each schema label the repository lacks (`gh label create`); existing labels
#           are left alone. Schema: <state dir>/routes.tsv (`<label><TAB><color><TAB><description>`
#           per line) when present, else the built-in five (cloud-ready, needs-local:android-emulator,
#           needs-local:ios-simulator, needs-local:macos-xcode, needs-local:research).
#   set     give issue N exactly route R: add R, remove every other route label. A needs-local:*
#           route also needs --what and --requires and posts ONE comment
#           "Local work needed: <what>. Type: <type>. Requires: <requires>." (--type defaults to the
#           route's suffix). R must be cloud-ready or needs-local:<type>. If `gh issue edit` fails
#           (for example a secondary rate limit) the labels are retried once through the REST API.
# A route label is `cloud-ready` or any label starting `needs-local:`. Issues carrying a skip label
# are not actionable: not counted as unrouted, and `set` refuses them. Default skip labels:
# physical-device, needs-human, blocked, desktop, epic, needs-decision (--skip-label replaces them).
# Reads at most 1000 open issues (over REST where GraphQL is refused). Writes append to <state dir>/route-actions.log.
# Exit: 0 ok (or would change) | 2 usage | 3 refused | 4 issues or labels could not be read |
#       5 write failed (rerun finishes it) | 9 outcome unknown (the issue could not be read back).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}
if [[ -n "$cmd" ]]; then shift; fi
repo="" limit=200 dry=no issue="" route="" what="" requires="" type=""
skip=()
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --skip-label) skip+=("$2"); shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --route) route=$2; shift 2 ;;
    --what) what=$2; shift 2 ;;
    --requires) requires=$2; shift 2 ;;
    --type) type=$2; shift 2 ;;
    --dry-run) dry=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "issue-route.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in status | labels | set) ;; -h | --help) orch_usage; exit 0 ;; *) usage ;; esac
((${#skip[@]})) || skip=(physical-device needs-human blocked desktop epic needs-decision)
repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
skip_json=$(printf '%s\n' "${skip[@]}" | jq -R . | jq -sc .)
log_action() { printf '%s\t%s\n' "$(orch_iso "$(orch_now)")" "$*" >>"$state/route-actions.log"; }
is_route='def is_route: . == "cloud-ready" or startswith("needs-local:");'

schema() { # label<TAB>color<TAB>description
  if [[ -s "$state/routes.tsv" ]]; then
    awk -F'\t' 'NF >= 1 && $1 != "" && $1 !~ /^#/' "$state/routes.tsv"
  else
    printf '%s\t%s\t%s\n' \
      cloud-ready 0e8a16 "A Linux agent can finish this without a device" \
      needs-local:android-emulator 1d76db "Needs a local Android emulator" \
      needs-local:ios-simulator 5319e7 "Needs a local iOS simulator" \
      needs-local:macos-xcode 0052cc "Needs macOS with Xcode" \
      needs-local:research fbca04 "Must be measured locally before it can be fixed"
  fi
}

case "$cmd" in
  status)
    # GraphQL, or REST where GitHub refuses GraphQL (gh-issues.sh); bounded like orch_read_retry.
    issues=$("$here/gh-issues.sh" issues --repo "$repo" --limit 1000 --fields number,title,labels \
      --tries 3 --budget "${ORCHESTRATE_READ_BUDGET:-60}" 2>/dev/null) && jq -e 'type == "array"' <<<"$issues" >/dev/null ||
      { echo "issue-route.sh: open issues could not be read" >&2; exit 4; }
    known=$(schema | cut -f1 | jq -R . | jq -sc .)
    jq -r --argjson skip "$skip_json" --argjson known "$known" --argjson limit "$limit" "$is_route"'
      [.[] | {number, title, l: [.labels[].name]} | .r = [.l[] | select(is_route)]
       | .skipped = (any(.l[]; . as $x | $skip | index($x)))] as $all
      | ($all | map(select(.skipped | not))) as $act
      | ([$known[], ($act[].r[])] | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)) as $routes
      | ($routes[] as $r | ["count", $r, ([$act[] | select(.r | index([$r]))] | length)]),
        ["count", "unrouted", ([$act[] | select(.r == [])] | length)],
        ["count", "multi", ([$act[] | select((.r | length) > 1)] | length)],
        ["count", "skipped", ([$all[] | select(.skipped)] | length)],
        ($act | map(select(.r == [])) | sort_by(.number) | .[0:$limit][]
          | ["unrouted", .number, (.l | join(",") | if . == "" then "-" else . end), .title]),
        ($act | map(select((.r | length) > 1)) | sort_by(.number) | .[0:$limit][]
          | ["multi", .number, (.r | join(",")), .title])
      | @tsv' <<<"$issues"
    ;;

  labels)
    have=$(orch_read_retry 3 gh label list --repo "$repo" --limit 1000 --json name) &&
      jq -e 'type == "array"' <<<"$have" >/dev/null ||
      { echo "issue-route.sh: labels could not be read" >&2; exit 4; }
    rc=0
    while IFS=$'\t' read -r name color desc; do
      [[ -n "$name" ]] || continue
      if jq -e --arg n "$name" 'any(.[]; (.name | ascii_downcase) == ($n | ascii_downcase))' <<<"$have" >/dev/null; then
        echo "exists $name"
      elif [[ "$dry" == yes ]]; then
        echo "would create $name"
      elif gh label create "$name" --repo "$repo" --color "${color:-ededed}" --description "${desc:-}" >/dev/null 2>&1; then
        echo "created $name"; log_action "label-create	$name"
      else
        echo "failed $name"; rc=5
      fi
    done < <(schema)
    exit "$rc"
    ;;

  set)
    [[ "$issue" =~ ^[0-9]+$ && -n "$route" ]] || usage
    refuse() { echo "refused: $*"; exit 3; }
    case "$route" in
      cloud-ready) ;;
      needs-local:?*)
        [[ -n "$what" && -n "$requires" ]] || refuse "a needs-local route needs --what and --requires"
        type=${type:-${route#needs-local:}} ;;
      *) refuse "route must be cloud-ready or needs-local:<type>, not $route" ;;
    esac
    view() { orch_read_retry 3 gh issue view "$issue" --repo "$repo" --json state,labels,comments; }
    marker="<!-- waaagh:route issue=$issue route=$route -->"
    info=$(view) || { echo "unverified: issue $issue could not be read"; exit 9; }
    [[ "$(jq -r .state <<<"$info")" == OPEN ]] || refuse "issue $issue is not open"
    hit=$(jq -r --argjson skip "$skip_json" '[.labels[].name | select(. as $x | $skip | index($x))] | first // ""' <<<"$info")
    [[ -z "$hit" ]] || refuse "issue $issue is labelled $hit"
    others=()
    while IFS= read -r l; do if [[ -n "$l" ]]; then others+=("$l"); fi; done < <(jq -r --arg r "$route" "$is_route"'
      .labels[].name | select(is_route and . != $r)' <<<"$info")
    removed=$(jq -rn '$ARGS.positional | join(" ")' --args ${others[@]+"${others[@]}"})
    has_route=$(jq -r --arg r "$route" 'any(.labels[]; .name == $r)' <<<"$info")
    comment=""
    if [[ "$route" == needs-local:* ]]; then
      strip() { sed -E 's/[[:space:]]*\.+[[:space:]]*$//' <<<"$1"; }
      comment="Local work needed: $(strip "$what"). Type: $(strip "$type"). Requires: $(strip "$requires")."
    fi
    has_comment() { jq -e --arg m "$marker" '[.comments[]?.body | select(contains($m))] | length > 0' <<<"$1" >/dev/null; }
    need_comment=no
    if [[ -n "$comment" ]] && ! has_comment "$info"; then need_comment=yes; fi
    if [[ "$has_route" == true && ${#others[@]} -eq 0 && "$need_comment" == no ]]; then
      echo "unchanged $issue $route"; exit 0
    fi
    if [[ "$dry" == yes ]]; then
      echo "would route $issue $route${removed:+ (remove $removed)}"
      [[ "$need_comment" == no ]] || echo "would comment: $comment"
      exit 0
    fi
    rc=0
    if [[ "$has_route" != true || ${#others[@]} -gt 0 ]]; then
      args=(--add-label "$route")
      for l in ${others[@]+"${others[@]}"}; do args+=(--remove-label "$l"); done
      if ! gh issue edit "$issue" --repo "$repo" "${args[@]}" >/dev/null 2>&1; then
        # REST fallback: one add, one delete per extra route.
        gh api -X POST "repos/$repo/issues/$issue/labels" -f "labels[]=$route" >/dev/null 2>&1 || rc=5
        for l in ${others[@]+"${others[@]}"}; do
          enc=$(jq -rn --arg l "$l" '$l | @uri')
          gh api -X DELETE "repos/$repo/issues/$issue/labels/$enc" >/dev/null 2>&1 || rc=5
        done
      fi
    fi
    if [[ "$need_comment" == yes ]]; then
      gh issue comment "$issue" --repo "$repo" --body "$comment

$marker" >/dev/null 2>&1 || rc=5
    fi
    after=$(view) || { echo "unverified: route of issue $issue sent but not read back; rerun to reconcile"; exit 9; }
    routes=$(jq -r "$is_route"' [.labels[].name | select(is_route)] | join(",")' <<<"$after")
    if [[ "$routes" == "$route" ]] && { [[ -z "$comment" ]] || has_comment "$after"; }; then
      log_action "route	issue=$issue	$route${removed:+	removed=$removed}"
      echo "routed $issue $route"
    else
      echo "route of issue $issue incomplete (routes now: ${routes:-none}; exit $rc); rerun to finish"; exit 5
    fi
    ;;
esac
