#!/usr/bin/env bats
# open-blockers.sh and issues-ranked.sh --drop-blocked against a stubbed gh, plus the doctrine
# pointers (#84). Run: bats open-blockers.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  # Issue N is $FX/issue-N.json (missing: 404; containing "500": a server error), its blocked_by
  # list $FX/deps-N.json (missing: []; containing "404": the feature is off).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"; all=${all% --include}
echo "$all" >>"$FX/calls"
case "$all" in
  "api repos/o/r/issues/"*/dependencies/blocked_by*)
    n=${all#api repos/o/r/issues/}; n=${n%%/*}
    if [ ! -f "$FX/deps-$n.json" ]; then echo '[]'
    elif grep -qx 404 "$FX/deps-$n.json"; then echo "gh: Not Found (HTTP 404)" >&2; exit 1
    else cat "$FX/deps-$n.json"; fi ;;
  "api repos/o/r/issues/"*)
    n=${all#api repos/o/r/issues/}
    if [ ! -f "$FX/issue-$n.json" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1
    elif grep -qx 500 "$FX/issue-$n.json"; then echo "gh: Server Error (HTTP 500)" >&2; exit 1
    else cat "$FX/issue-$n.json"; fi ;;
  "pr list"*) echo '[]' ;;
  "issue list"*) cat "$FX/issues.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

issue() { # n state [body]
  jq -n --argjson n "$1" --arg s "$2" --arg b "${3:-}" '{number: $n, state: $s, body: $b}' >"$FX/issue-$1.json"
}
dep() { # n state [repo]
  jq -n --argjson n "$1" --arg s "$2" --arg r "${3:-o/r}" \
    '{number: $n, state: $s, repository_url: "https://api.github.com/repos/\($r)"}'
}
ob() { "$SCRIPTS/open-blockers.sh" --repo o/r "$@"; }

@test "native blocked_by: only open blockers count; another repository is named in full" {
  issue 10 open
  { dep 1 open; dep 2 closed; dep 3 open x/y; } | jq -s . >"$FX/deps-10.json"
  run ob 10
  [ "$status" -eq 3 ]
  [ "$output" = "10 BLOCKED by #1 x/y#3" ]
}

@test "body 'Blocked by' lines: each referenced issue's state is looked up" {
  issue 20 open $'Context.\n\n**Blocked by:** #5, #6 and https://github.com/o/r/issues/7\nRelated to #8\nUnblocked by #9'
  issue 5 open; issue 6 closed; issue 7 open
  run ob 20
  [ "$status" -eq 3 ]
  [ "$output" = "20 BLOCKED by #5 #7" ]
  ! grep -q 'issues/8$' "$FX/calls"
  ! grep -q 'issues/9$' "$FX/calls"
}

@test "clear issues, # prefixes, a missing reference, a 404 dependency list and a cached lookup" {
  issue 30 open 'blocked by #404404 (typo)'
  echo 404 >"$FX/deps-30.json"
  issue 31 open 'Blocked by #33'; issue 32 closed 'Blocked by #33'; issue 33 closed
  run ob '#30' 31 32
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "30 clear" ]
  [ "${lines[1]}" = "31 clear" ]
  [ "${lines[2]}" = "32 clear" ]
  [ "$(grep -c '^api repos/o/r/issues/33$' "$FX/calls")" -eq 1 ]
}

@test "a blocker in both the dependency list and the body is listed once" {
  issue 40 open 'Blocked by #1'
  dep 1 open | jq -s . >"$FX/deps-40.json"
  run ob 40
  [ "$status" -eq 3 ]
  [ "$output" = "40 BLOCKED by #1" ]
  ! grep -q '^api repos/o/r/issues/1$' "$FX/calls"
}

@test "unreadable: the issue or a referenced issue; other issues still answer; exit 4 wins" {
  echo 500 >"$FX/issue-50.json"
  issue 51 open 'Blocked by #52'; echo 500 >"$FX/issue-52.json"
  issue 53 open 'Blocked by #54'; issue 54 open
  run ob 50 51 53
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = "50 unreadable issue" ]
  [ "${lines[1]}" = "51 unreadable #52" ]
  [ "${lines[2]}" = "53 BLOCKED by #54" ]
}

@test "usage: no issue or a non-number exits 2 without calling gh" {
  run ob
  [ "$status" -eq 2 ]
  [[ "$output" == *"open-blockers.sh [--repo OWNER/REPO] <issue>..."* ]]
  run ob abc
  [ "$status" -eq 2 ]
  run ob --help
  [ "$status" -eq 0 ]
  [[ "$output" != *"set -euo pipefail"* ]]
  [ ! -f "$FX/calls" ]
}

ranked_fixture() {
  cat >"$FX/issues.json" <<'JSON'
[{"number":1,"title":"blocked bug","labels":[{"name":"bug"}],"updatedAt":"2026-09-27T09:00:00Z"},
 {"number":2,"title":"free bug","labels":[{"name":"bug"}],"updatedAt":"2026-09-27T08:00:00Z"},
 {"number":3,"title":"other","labels":[],"updatedAt":"2026-09-27T07:00:00Z"},
 {"number":4,"title":"the blocker","labels":[],"updatedAt":"2026-09-27T06:00:00Z"},
 {"number":5,"title":"blocked too","labels":[],"updatedAt":"2026-09-27T05:00:00Z"}]
JSON
  issue 1 open 'Blocked by #4 and #99'; issue 2 open; issue 3 open; issue 4 open; issue 99 open
  issue 5 open; dep 6 open | jq -s . >"$FX/deps-5.json"
}

@test "issues-ranked --drop-blocked drops blocked rows and ranks a routable blocker in their place" {
  ranked_fixture
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --limit 3 --drop-blocked
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -v '^#' | cut -f1,2 | tr '\t\n' ': ')" = "1:4 2:2 3:3 " ]
  [[ "${lines[3]}" == "# drop-blocked: dropped 1 (#1 by #4 #99); promoted blockers: #4; blockers outside this list: #99; unchecked: none" ]]
  # Only the top 3 and the promoted blocker were checked; #5 below the cut was not.
  ! grep -q 'issues/5' "$FX/calls"
}

@test "issues-ranked --drop-blocked: an unreadable row stays; without the flag nothing is checked" {
  ranked_fixture
  echo 500 >"$FX/issue-2.json"
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --limit 5 --drop-blocked
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -v '^#' | cut -f2 | tr '\n' ' ')" = "4 2 3 " ]
  [[ "$output" == *"dropped 2 (#1 by #4 #99; #5 by #6)"* ]]
  [[ "$output" == *"blockers outside this list: #6 #99; unchecked: #2"* ]]
  rm "$FX/calls"
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --limit 5
  [ "$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')" = "1 2 3 4 5 " ]
  ! grep -q '^api ' "$FX/calls"
}

@test "doctrine: lane drivers, the planner and the dispatcher name the one blocker check" {
  R="$ROOT/skills/orchestrate"
  grep -qF 'open-blockers.sh' "$R/subagent-hygiene.md"
  grep -qF 'issues-ranked.sh --route cloud-ready --skip-in-pr --drop-blocked' "$R/roles/cloud-dispatch.md"
  grep -qF -- '--drop-blocked' "$R/routing.md"
  grep -qF 'open-blockers.sh' "$R/SKILL.md"
  grep -qF -- '--drop-blocked' "$R/roles/hygiene-bot.md"
  grep -qF '`open-blockers.sh`' "$ROOT/README.md"
}
