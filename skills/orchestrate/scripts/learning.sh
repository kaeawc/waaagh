#!/usr/bin/env bash
# Campaign learnings: one file per learning under <state dir>/learnings/, an INDEX.md rebuilt on
# every change and recorded in campaign.json (.learnings), so the next session or a fresh brief
# finds the campaign's operating knowledge. Doctrine: skills/orchestrate/learnings.md.
#
# Usage: learning.sh <command> [--repo OWNER/REPO] [options]
#   add --title T --rule R --why W --how H --source S --trigger owner|procedural
#       --scope repo|global --roles R1,R2 [--date YYYY-MM-DD]
#             write one learning (id = date-slug of the title) and print its path. owner: an owner
#             instruction that changes routing, delegation or closing; procedural: a failure whose
#             fix is procedure, not code. Roles: role template names, orchestrator, or all.
#   index     rebuild INDEX.md and the ledger entry; print the index path
#   list      [--role R] [--all]   id, roles, scope, title per active learning (--all: superseded too)
#   show      --id ID              print one learning
#   brief     --role R             what a role brief loads: the index, then every active learning
#             tagged R or all
#   status    one key=value per line: active, global_not_upstreamed, added_since_consolidation,
#             last_consolidation_at, consolidation_due (yes|no)
#   consolidate [--done]   print duplicate candidates (same normalized title or rule), one
#             `dup<TAB>id<TAB>id` line each, and global learnings not yet upstreamed; --done
#             records that the pass ran (resets added_since_consolidation)
#   supersede --id OLD --by NEW [--note TEXT]   fold OLD into NEW: OLD's file is removed, NEW and
#             history.log keep one history line
#   retire    --id ID --note TEXT   drop a rule nothing replaces; history.log keeps one line
#   upstream  --id ID [--create]    a global learning as a waaagh doctrine issue: print the title
#             and body, or with --create open it on ORCHESTRATE_UPSTREAM_REPO (default
#             kaeawc/waaagh) and record its URL in the learning. Already upstreamed: print the URL.
# Env: ORCHESTRATE_LEARNINGS_CONSOLIDATE_EVERY (default 10) learnings added between passes.
# Exit: 0 ok | 2 usage | 3 refused (id exists, unknown id, repo-scope upstream) | 9 the upstream
#       issue was sent but its URL is unknown (see <state dir>/ops/upstream-<id>.json)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_lib.sh
source "$here/_lib.sh"

usage() { sed -n '2,30p' "$0" >&2; exit 2; }
cmd=${1:-}
case "$cmd" in
  add | index | list | show | brief | status | consolidate | supersede | retire | upstream) shift ;;
  -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
  *) usage ;;
esac
repo="" title="" rule="" why="" how="" source_ev="" trigger="" scope="" roles="" date=""
id="" by="" note="" role="" all=no done=no create=no
while (($#)); do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --rule) rule=$2; shift 2 ;;
    --why) why=$2; shift 2 ;;
    --how) how=$2; shift 2 ;;
    --source) source_ev=$2; shift 2 ;;
    --trigger) trigger=$2; shift 2 ;;
    --scope) scope=$2; shift 2 ;;
    --roles) roles=$2; shift 2 ;;
    --date) date=$2; shift 2 ;;
    --id) id=$2; shift 2 ;;
    --by) by=$2; shift 2 ;;
    --note) note=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --all) all=yes; shift ;;
    --done) done=yes; shift ;;
    --create) create=yes; shift ;;
    *) echo "learning.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
refuse() { echo "refused: $*"; exit 3; }

repo=$(orch_repo "$repo")
state=$(orch_state_dir "$repo")
dir="$state/learnings"
ledger="$state/campaign.json"
today=$(jq -rn --argjson t "$(orch_now)" '$t | strftime("%Y-%m-%d")')
mkdir -p "$dir"

# fm FILE KEY: one front-matter value.
fm() { awk -v k="$2" 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit }
  inside && index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$1"; }
# The entry files, oldest first (ids start with their date).
entries() { local f; for f in "$dir"/[0-9]*.md; do [[ ! -f "$f" ]] || echo "$f"; done; }
# need_id ID: refuse an id with no entry (in this shell, so the refusal reaches the caller).
need_id() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+$ && -f "$dir/$1.md" ]] || refuse "no learning ${1:-(none)}"; }
tagged() { [[ ",$(fm "$1" roles)," == *",$2,"* || ",$(fm "$1" roles)," == *",all,"* ]]; }
norm() { tr '[:upper:]' '[:lower:]' <<<"$1" | tr -cs 'a-z0-9' ' ' | sed -e 's/^ *//' -e 's/ *$//'; }
# The rule paragraph of an entry, on one line.
rule_of() { awk '/^\*\*Rule:\*\* / { sub(/^\*\*Rule:\*\* /, ""); on = 1 } /^\*\*Why:\*\*/ { exit } on { printf "%s ", $0 }' "$1"; }
history() { printf '%s\t%s\n' "$today" "$1" >>"$dir/history.log"; }
set_fm() { # set_fm FILE KEY VALUE
  local tmp
  tmp=$(mktemp "$1.XXXXXX")
  awk -v k="$2" -v v="$3" 'NR == 1 && $0 == "---" { inside = 1; print; next }
    inside && $0 == "---" { inside = 0 } inside && ($0 == k ":" || index($0, k ": ") == 1) { print k ": " v; next } { print }' "$1" >"$tmp" && mv "$tmp" "$1"
}

ledger_update() { # ledger_update JQ-FILTER [jq args...]
  local filter=$1 tmp
  shift
  # Same first shape as campaign.sh, so its count still starts here.
  [[ -f "$ledger" ]] || jq -n --arg at "$(orch_iso "$(orch_now)")" \
    '{started_at: $at, last_verification_at: $at, last_verification_sha: null}' >"$ledger"
  tmp=$(mktemp "$ledger.XXXXXX")
  jq "$@" "$filter" "$ledger" >"$tmp" && mv "$tmp" "$ledger"
}

reindex() {
  local f n=0 lines="" up
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    n=$((n + 1))
    up=$(fm "$f" upstream)
    lines+="- \`$(fm "$f" id)\` [$(fm "$f" roles)] $(fm "$f" scope)${up:+, upstream $up} — $(fm "$f" title)"$'\n'
  done < <(entries)
  {
    echo "# Learnings — $repo"
    echo
    echo "$n active. One entry: \`learning.sh show --id ID\`. A role's entries: \`learning.sh brief --role ROLE\`."
    echo
    printf '%s' "$lines"
  } >"$dir/INDEX.md.tmp" && mv "$dir/INDEX.md.tmp" "$dir/INDEX.md"
  ledger_update '.learnings = ((.learnings // {}) + {index: $index, active: $n, updated_at: $at})' \
    --arg index "$dir/INDEX.md" --argjson n "$n" --arg at "$(orch_iso "$(orch_now)")"
}

case "$cmd" in
  add)
    [[ -n "$title" && -n "$rule" && -n "$why" && -n "$how" && -n "$source_ev" ]] || usage
    [[ "$trigger" == owner || "$trigger" == procedural ]] || usage
    [[ "$scope" == repo || "$scope" == global ]] || usage
    [[ "$roles" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || usage
    date=${date:-$today}
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    [[ "$title" != *$'\n'* && "$source_ev" != *$'\n'* ]] || usage
    slug=$(norm "$title" | tr ' ' '-' | cut -c1-50 | sed 's/-*$//')
    [[ -n "$slug" ]] || usage
    id="$date-$slug" f="$dir/$date-$slug.md"
    [[ ! -f "$f" ]] || refuse "learning $id exists; supersede it or change the title"
    cat >"$f.tmp" <<EOF
---
id: $id
title: $title
date: $date
trigger: $trigger
scope: $scope
roles: $roles
source: $source_ev
upstream:
---
**Rule:** $rule

**Why:** $why

**How to apply:** $how

## History
- $date created ($trigger): $source_ev
EOF
    mv "$f.tmp" "$f"
    ledger_update '.learnings.added_since_consolidation = ((.learnings.added_since_consolidation // 0) + 1)'
    reindex
    echo "$f"
    ;;
  index) reindex; echo "$dir/INDEX.md" ;;
  list)
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      [[ -z "$role" ]] || tagged "$f" "$role" || continue
      printf '%s\t%s\t%s\t%s\n' "$(fm "$f" id)" "$(fm "$f" roles)" "$(fm "$f" scope)" "$(fm "$f" title)"
    done < <(entries)
    if [[ "$all" == yes && -f "$dir/history.log" ]]; then sed 's/^/history\t/' "$dir/history.log"; fi
    ;;
  show) need_id "$id"; cat "$dir/$id.md" ;;
  brief)
    [[ "$role" =~ ^[a-z0-9-]+$ ]] || usage
    [[ -f "$dir/INDEX.md" ]] || reindex
    cat "$dir/INDEX.md"
    while IFS= read -r f; do
      [[ -n "$f" ]] && tagged "$f" "$role" || continue
      printf '\n## %s\n' "$(fm "$f" title)"
      awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { inside = 0; next }
        inside { next } /^## History$/ { exit } { print }' "$f"
    done < <(entries)
    ;;
  status)
    active=0 notup=0
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      active=$((active + 1))
      [[ "$(fm "$f" scope)" != global || -n "$(fm "$f" upstream)" ]] || notup=$((notup + 1))
    done < <(entries)
    added=0 last=never
    if [[ -f "$ledger" ]]; then
      added=$(jq -r '.learnings.added_since_consolidation // 0' "$ledger")
      last=$(jq -r '.learnings.last_consolidation_at // "never"' "$ledger")
    fi
    every=${ORCHESTRATE_LEARNINGS_CONSOLIDATE_EVERY:-10}
    echo "active=$active"
    echo "global_not_upstreamed=$notup"
    echo "added_since_consolidation=$added"
    echo "last_consolidation_at=$last"
    echo "consolidation_due=$( ((added >= every)) && echo yes || echo no)"
    ;;
  consolidate)
    keys=""
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      keys+="$(fm "$f" id)"$'\t'"$(norm "$(fm "$f" title)")"$'\n'
      keys+="$(fm "$f" id)"$'\t'"$(norm "$(rule_of "$f")")"$'\n'
      [[ "$(fm "$f" scope)" != global || -n "$(fm "$f" upstream)" ]] || printf 'upstream\t%s\n' "$(fm "$f" id)"
    done < <(entries)
    printf '%s' "$keys" | awk -F'\t' 'NF == 2 && $2 != "" { if ($2 in first && first[$2] != $1) {
        pair = first[$2] "\t" $1; if (!(pair in seen)) { seen[pair] = 1; print "dup\t" pair } }
      else if (!($2 in first)) first[$2] = $1 }'
    if [[ "$done" == yes ]]; then
      ledger_update '.learnings.added_since_consolidation = 0 | .learnings.last_consolidation_at = $at' \
        --arg at "$(orch_iso "$(orch_now)")"
      echo "consolidated at $(orch_iso "$(orch_now)")"
    fi
    ;;
  supersede)
    need_id "$id"; need_id "$by"
    old="$dir/$id.md" new="$dir/$by.md"
    [[ "$id" != "$by" ]] || refuse "a learning cannot supersede itself"
    line="superseded $id ($(fm "$old" title)) by $by${note:+: $note}"
    printf -- '- %s absorbed %s (%s)%s\n' "$today" "$id" "$(fm "$old" title)" "${note:+: $note}" >>"$new"
    history "$line"
    rm -f "$old"
    reindex
    echo "$line"
    ;;
  retire)
    [[ -n "$note" ]] || usage
    need_id "$id"; old="$dir/$id.md"
    line="retired $id ($(fm "$old" title)): $note"
    history "$line"
    rm -f "$old"
    reindex
    echo "$line"
    ;;
  upstream)
    need_id "$id"; f="$dir/$id.md"
    [[ "$(fm "$f" scope)" == global ]] || refuse "$id is repo-specific; only global learnings go upstream"
    url=$(fm "$f" upstream)
    if [[ -n "$url" ]]; then echo "upstreamed: $url"; exit 0; fi
    up=${ORCHESTRATE_UPSTREAM_REPO:-kaeawc/waaagh}
    ititle="Doctrine: $(fm "$f" title)"
    body="A campaign on another repository learned this, and it applies to every repository. Proposed as a waaagh doctrine change.

$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { inside = 0; next } !inside' "$f")

Trigger: $(fm "$f" trigger). Source event: $(fm "$f" source). Roles: $(fm "$f" roles).

<!-- waaagh:learning id=$id -->"
    if [[ "$create" == no ]]; then
      printf 'repo: %s\ntitle: %s\n\n%s\n' "$up" "$ititle" "$body"
      exit 0
    fi
    journal="$state/ops/upstream-$id.json"
    orch_journal "$journal" "$(jq -cn --arg up "$up" --arg id "$id" --arg at "$(orch_iso "$(orch_now)")" \
      '{op: "upstream-learning", repo: $up, learning: $id, state: "intent", started_at: $at}')"
    rc=0
    out=$(gh issue create --repo "$up" --title "$ititle" --body "$body" 2>/dev/null) || rc=$?
    url=$(printf '%s\n' "$out" | awk '/^https:\/\/github\.com\/.*\/issues\/[0-9]+$/ { u = $0 } END { print u }')
    if [[ -z "$url" ]]; then
      orch_journal "$journal" "$(jq -c --argjson rc "$rc" '.state = "unknown" | .exit = $rc' "$journal")"
      echo "unverified: issue create sent (exit $rc) but no URL came back; search $up for 'waaagh:learning id=$id' before retrying"
      exit 9
    fi
    orch_journal "$journal" "$(jq -c --arg u "$url" '.state = "done" | .url = $u' "$journal")"
    set_fm "$f" upstream "$url"
    printf -- '- %s proposed upstream: %s\n' "$today" "$url" >>"$f"
    reindex
    echo "upstreamed: $url"
    ;;
esac
