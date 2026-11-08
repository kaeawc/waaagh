#!/usr/bin/env bats
# issue-route.sh and issues-ranked.sh --route against a stubbed gh, plus the routing doctrine
# contract. Run: bats issue-route.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400   # 2026-09-27T12:00:00Z
  # The stub keeps one issue's labels in $FX/labels (one per line) and its comments in
  # $FX/comments, so writes are visible to the readback. EDIT_FAIL=1 makes `gh issue edit` fail.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
view() {
  jq -n --rawfile l "$FX/labels" --rawfile c "$FX/comments" --arg s "$(cat "$FX/state" 2>/dev/null || echo OPEN)" \
    '{state: $s, labels: [$l | split("\n")[] | select(. != "") | {name: .}],
      comments: (if $c == "" then [] else [{body: $c}] end)}'
}
case "$1 $2" in
  "issue list") cat "$FX/issues.json" ;;
  "issue view") view ;;
  "label list") cat "$FX/repo-labels.json" ;;
  "label create") echo "$3" >>"$FX/created" ;;
  "issue edit")
    [ "${EDIT_FAIL:-0}" = 1 ] && { echo "HTTP 403: You have exceeded a secondary rate limit" >&2; exit 1; }
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label) echo "$2" >>"$FX/labels"; shift 2 ;;
        --remove-label) grep -vxF "$2" "$FX/labels" >"$FX/l.tmp" || true; mv "$FX/l.tmp" "$FX/labels"; shift 2 ;;
        *) shift ;;
      esac
    done ;;
  "issue comment") shift 2; while [ $# -gt 0 ]; do [ "$1" = --body ] && printf '%s' "$2" >"$FX/comments"; shift; done ;;
  "api -X")
    case "$3" in
      POST) echo "${6#labels[]=}" >>"$FX/labels" ;;
      DELETE) l=$(jq -rn --arg u "${4##*/}" '$u | @text | gsub("%3A"; ":")'); grep -vxF "$l" "$FX/labels" >"$FX/l.tmp" || true; mv "$FX/l.tmp" "$FX/labels" ;;
    esac ;;
  "pr list") echo '[]' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  : >"$FX/labels"; : >"$FX/comments"; : >"$FX/calls"
}
ir() { "$SCRIPTS/issue-route.sh" "$@" --repo o/r; }

@test "status counts routes and lists unrouted and multi-routed actionable issues only" {
  cat >"$FX/issues.json" <<'JSON'
[{"number":1,"title":"fix CI cache","labels":[{"name":"cloud-ready"}]},
 {"number":2,"title":"emulator tap","labels":[{"name":"needs-local:android-emulator"},{"name":"bug"}]},
 {"number":3,"title":"both sides","labels":[{"name":"cloud-ready"},{"name":"needs-local:ios-simulator"}]},
 {"number":4,"title":"nobody owns me","labels":[{"name":"bug"}]},
 {"number":5,"title":"an epic","labels":[{"name":"epic"}]},
 {"number":6,"title":"waiting","labels":[{"name":"needs-decision"},{"name":"cloud-ready"}]},
 {"number":7,"title":"bare","labels":[]},
 {"number":8,"title":"wear","labels":[{"name":"needs-local:wearos"}]}]
JSON
  run ir status
  [ "$status" -eq 0 ]
  [[ "$output" == *$'count\tcloud-ready\t2'* ]]
  [[ "$output" == *$'count\tneeds-local:android-emulator\t1'* ]]
  [[ "$output" == *$'count\tneeds-local:ios-simulator\t1'* ]]
  [[ "$output" == *$'count\tneeds-local:macos-xcode\t0'* ]]
  [[ "$output" == *$'count\tneeds-local:wearos\t1'* ]]
  [[ "$output" == *$'count\tunrouted\t2'* ]]
  [[ "$output" == *$'count\tmulti\t1'* ]]
  [[ "$output" == *$'count\tskipped\t2'* ]]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$1 == "unrouted" { printf "%s ", $2 }')" = "4 7 " ]
  [[ "$output" == *$'unrouted\t7\t-\tbare'* ]]
  [[ "$output" == *$'multi\t3\tcloud-ready,needs-local:ios-simulator\tboth sides'* ]]
  grep -q 'issue list --repo o/r --state open --limit 1000' "$FX/calls"
}

@test "status reports an unreadable issue list instead of empty counts" {
  echo 'not json' >"$FX/issues.json"
  run ir status
  [ "$status" -eq 4 ]
}

@test "labels creates only the schema labels the repository lacks, and a dry run creates none" {
  echo '[{"name":"Cloud-Ready"},{"name":"needs-local:ios-simulator"},{"name":"bug"}]' >"$FX/repo-labels.json"
  run ir labels --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"exists cloud-ready"* ]]
  [[ "$output" == *"would create needs-local:android-emulator"* ]]
  [ ! -e "$FX/created" ]
  run ir labels
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' <"$FX/created")" = "needs-local:android-emulator needs-local:macos-xcode needs-local:research " ]
  grep -q 'label-create	needs-local:research' "$ORCHESTRATE_STATE_DIR/o__r/route-actions.log"
  # A repository schema replaces the built-in one.
  printf 'cloud-ready\t0e8a16\tcloud\nneeds-local:wearos\tc5def5\tWear OS emulator\n' >"$ORCHESTRATE_STATE_DIR/o__r/routes.tsv"
  rm "$FX/created"
  run ir labels
  [ "$(cat "$FX/created")" = "needs-local:wearos" ]
}

@test "set gives exactly one route, removing the others, and is idempotent" {
  printf 'bug\nneeds-local:ios-simulator\nneeds-local:research\n' >"$FX/labels"
  run ir set --issue 3 --route cloud-ready
  [ "$status" -eq 0 ]
  [ "$output" = "routed 3 cloud-ready" ]
  [ "$(sort "$FX/labels" | tr '\n' ' ')" = "bug cloud-ready " ]
  [ ! -s "$FX/comments" ]
  grep -q 'removed=needs-local:ios-simulator needs-local:research' "$ORCHESTRATE_STATE_DIR/o__r/route-actions.log"
  : >"$FX/calls"
  run ir set --issue 3 --route cloud-ready
  [ "$output" = "unchanged 3 cloud-ready" ]
  ! grep -q 'issue edit' "$FX/calls"
}

@test "a local route needs what and requires, and posts the local-work comment once" {
  run ir set --issue 4 --route needs-local:android-emulator
  [ "$status" -eq 3 ]
  run ir set --issue 4 --route needs-local:android-emulator --what "reproduce the tap offset." --requires "API 34 emulator"
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/labels")" = "needs-local:android-emulator" ]
  [[ "$(cat "$FX/comments")" == "Local work needed: reproduce the tap offset. Type: android-emulator. Requires: API 34 emulator."* ]]
  grep -q 'waaagh:route issue=4 route=needs-local:android-emulator' "$FX/comments"
  : >"$FX/calls"
  run ir set --issue 4 --route needs-local:android-emulator --what "x" --requires "y" --type bug
  [ "$output" = "unchanged 4 needs-local:android-emulator" ]
  ! grep -q 'issue comment' "$FX/calls"
}

@test "set refuses skip-labelled, closed, and non-route targets, and dry-runs without writing" {
  echo blocked >"$FX/labels"
  run ir set --issue 5 --route cloud-ready
  [ "$status" -eq 3 ]
  [[ "$output" == *"labelled blocked"* ]]
  run ir set --issue 5 --route cloud-ready --skip-label epic
  [ "$status" -eq 0 ]
  : >"$FX/labels"; echo CLOSED >"$FX/state"
  run ir set --issue 5 --route cloud-ready
  [ "$status" -eq 3 ]
  echo OPEN >"$FX/state"
  run ir set --issue 5 --route bug
  [ "$status" -eq 3 ]
  echo needs-local:research >"$FX/labels"; : >"$FX/calls"
  run ir set --issue 5 --route cloud-ready --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "would route 5 cloud-ready (remove needs-local:research)" ]
  ! grep -q 'issue edit' "$FX/calls"
}

@test "a failed gh issue edit falls back to the REST label endpoints" {
  echo needs-local:research >"$FX/labels"
  EDIT_FAIL=1 run ir set --issue 6 --route needs-local:macos-xcode --what "check signing" --requires "macOS 15, Xcode 17"
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/labels")" = "needs-local:macos-xcode" ]
  grep -q 'api -X POST repos/o/r/issues/6/labels -f labels\[\]=needs-local:macos-xcode' "$FX/calls"
  grep -q 'api -X DELETE repos/o/r/issues/6/labels/needs-local%3Aresearch' "$FX/calls"
}

@test "issues-ranked --route keeps one route: exact label or a needs-local:* prefix" {
  cat >"$FX/issues.json" <<'JSON'
[{"number":1,"title":"ci","labels":[{"name":"cloud-ready"}],"updatedAt":"2026-09-27T09:00:00Z"},
 {"number":2,"title":"emu","labels":[{"name":"needs-local:android-emulator"}],"updatedAt":"2026-09-27T08:00:00Z"},
 {"number":3,"title":"sim","labels":[{"name":"needs-local:ios-simulator"}],"updatedAt":"2026-09-27T07:00:00Z"},
 {"number":4,"title":"unrouted","labels":[],"updatedAt":"2026-09-27T06:00:00Z"}]
JSON
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --route cloud-ready
  [ "$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')" = "1 " ]
  run "$SCRIPTS/issues-ranked.sh" --repo o/r --route 'needs-local:*'
  [ "$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')" = "2 3 " ]
  run "$SCRIPTS/issues-ranked.sh" --repo o/r
  [ "$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')" = "1 2 3 4 " ]
}

@test "routing doctrine: schema, exactly-one invariant, router buckets, and dispatch split (#54)" {
  R="$ROOT/skills/orchestrate"
  grep -qF 'routing.md' "$R/SKILL.md"
  grep -qF 'roles/router.md' "$R/SKILL.md"
  grep -qF '**exactly one** route label' "$R/routing.md"
  grep -qF 'gh label create' "$R/routing.md"
  grep -qF 'Cloud dispatch takes only `cloud-ready`' "$R/routing.md"
  grep -qF 'Local lanes take only `needs-local:*`' "$R/routing.md"
  for b in '**cloud**' '**local, by type**' '**already-done**' '**needs-decision**' '**skip**'; do
    grep -qF -- "$b" "$R/roles/router.md"
  done
  grep -qF 'the question, the options, and your recommendation' "$R/roles/router.md"
  grep -qF '`router.md`' "$R/roles/README.md"
  grep -qF '`issue-route.sh`' "$ROOT/README.md"
}
