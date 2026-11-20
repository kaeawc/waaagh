#!/usr/bin/env bats
# The waaagh-bot App broker (#268): app-broker.sh dispatches the app-broker.yml workflow (which
# alone holds the App's key) and reads its result; travel-guard.sh switches the ruleset that makes
# GitHub require the App's orchestrate/review status while traveling. gh is stubbed.
# Run: bats app-broker.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" GH_READ_JITTER=0 GH_READ_FAKE_SLEEP=1
  unset WAAAGH_APP_ID
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
gh_args=("$@")
printf '%s\n' "$*" >>"$FX/calls"
# The body a call sends on stdin (--input -), if any.
for a in "$@"; do [ "$a" != "--input" ] || cat >>"$FX/bodies"; done
case "$*" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  "api -X POST repos/o/r/actions/workflows/app-broker.yml/dispatches"*)
    [ ! -f "$FX/dispatch-fails" ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; } ;;
  "api --paginate repos/o/r/commits/"*"/statuses"*) cat "$FX/statuses.json" ;;
  "api repos/o/r/rulesets?"*) [ ! -f "$FX/rulesets-fail" ] || { echo "HTTP 404" >&2; exit 1; }; cat "$FX/rulesets.json" 2>/dev/null || echo '[]' ;;
  "api repos/o/r/rulesets/"*) cat "$FX/ruleset.json" ;;
  "api -X POST repos/o/r/rulesets --input -") echo '{"id": 77}' ;;
  "api -X PUT repos/o/r/rulesets/"*) echo '{}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  SHA=0123456789abcdef0123456789abcdef01234567
}
ab() { "$SCRIPTS/app-broker.sh" "$@" --repo o/r; }
tg() { "$SCRIPTS/travel-guard.sh" "$@" --repo o/r; }

@test "status and merge dispatch the workflow on the default branch with the request as inputs" {
  run ab status --pr 5 --sha "$SHA" --description "ship at head"
  [ "$status" -eq 0 ]
  [[ "$output" == "dispatched status pr=5 sha=0123456789ab repo=o/r: confirm with app-broker.sh check --sha $SHA"* ]]
  grep -qxF "api -X POST repos/o/r/actions/workflows/app-broker.yml/dispatches -f ref=main -f inputs[op]=status -f inputs[pr]=5 -f inputs[sha]=$SHA -f inputs[state]=success -f inputs[description]=ship at head" "$FX/calls"
  run ab merge --pr 5 --sha "$SHA" --method merge
  [ "$status" -eq 0 ]
  grep -qxF "api -X POST repos/o/r/actions/workflows/app-broker.yml/dispatches -f ref=main -f inputs[op]=merge -f inputs[pr]=5 -f inputs[sha]=$SHA -f inputs[method]=merge" "$FX/calls"
  touch "$FX/dispatch-fails"
  run ab status --pr 5 --sha "$SHA"
  [ "$status" -eq 3 ]
  [[ "$output" == "app-broker.sh: dispatch refused: HTTP 403"* ]]
}

@test "check reads the newest orchestrate/review on the head, and its poster" {
  jq -n '[[{context: "ci", state: "success", creator: {login: "x"}, updated_at: "2026-11-20T01:00:00Z"},
           {context: "orchestrate/review", state: "pending", creator: {login: "waaagh-bot[bot]"}, updated_at: "2026-11-20T01:00:00Z"},
           {context: "orchestrate/review", state: "success", creator: {login: "waaagh-bot[bot]"}, updated_at: "2026-11-20T02:00:00Z"}]]' \
    | jq -c '.[]' >"$FX/statuses.json"
  run ab check --sha "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "success by waaagh-bot[bot] at 2026-11-20T02:00:00Z" ]
  echo '[{"context": "ci", "state": "success"}]' >"$FX/statuses.json"
  run ab check --sha "$SHA"
  [ "$status" -eq 4 ]
  [ "$output" = absent ]
}

@test "bad requests are refused before any GitHub call" {
  run ab status --pr 5 --sha abc123
  [ "$status" -eq 2 ]
  run ab merge --pr x --sha "$SHA"
  [ "$status" -eq 2 ]
  run ab status --pr 5 --sha "$SHA" --state shipped
  [ "$status" -eq 2 ]
  run ab merge --pr 5 --sha "$SHA" --method fast-forward
  [ "$status" -eq 2 ]
  run ab status --pr 5 --sha "$SHA" --description "$(printf 'x%.0s' $(seq 1 141))"
  [ "$status" -eq 2 ]
  run "$SCRIPTS/app-broker.sh" approve
  [ "$status" -eq 2 ]
  [ ! -e "$FX/calls" ]
}

@test "travel-guard creates the ruleset requiring the App's status, then switches it off and on" {
  run tg status
  [ "$output" = absent ]
  run tg on
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs --app-id"* ]]
  WAAAGH_APP_ID=5846220 run tg on
  [ "$status" -eq 0 ]
  [ "$output" = "on id=77 (created)" ]
  jq -e '.name == "waaagh travel guard" and .enforcement == "active" and .conditions.ref_name.include == ["~DEFAULT_BRANCH"]
    and .rules[0].parameters.required_status_checks == [{context: "orchestrate/review", integration_id: 5846220}]' "$FX/bodies"
  echo '[{"id": 77, "name": "waaagh travel guard"}, {"id": 9, "name": "other"}]' >"$FX/rulesets.json"
  run tg off
  [ "$status" -eq 0 ]
  [ "$output" = "off id=77" ]
  grep -qx 'api -X PUT repos/o/r/rulesets/77 --input -' "$FX/calls"
  [ "$(jq -rs 'last | .enforcement' "$FX/bodies")" = disabled ]
  echo '{"id": 77, "enforcement": "disabled"}' >"$FX/ruleset.json"
  run tg status
  [ "$output" = "off id=77" ]
  run tg on --app-id 5846220
  [ "$output" = "on id=77" ]
  [ "$(jq -rs 'last | .enforcement' "$FX/bodies")" = active ]
  rm "$FX/rulesets.json"; run tg off
  [ "$output" = "absent (nothing to turn off)" ]
  touch "$FX/rulesets-fail"; run tg status
  [ "$status" -eq 3 ]
}

@test "the workflow every repository copies is the one tested here, and it keeps the key in the run" {
  cmp "$ROOT/skills/orchestrate/templates/app-broker.yml" "$ROOT/.github/workflows/app-broker.yml"
  w="$ROOT/.github/workflows/app-broker.yml"
  grep -qF 'private-key: ${{ secrets.GH_APP_PRIVATE_KEY }}' "$w"
  grep -qF 'repositories: ${{ github.event.repository.name }}' "$w"
  # Inputs reach the shell through the environment only: no ${{ }} inside any run block.
  spliced=$(awk '/^ +run: \|/ { inrun = 1; ind = match($0, /[^ ]/); next }
    inrun && NF && match($0, /[^ ]/) <= ind { inrun = 0 }
    inrun && /\$\{\{/ { print NR ": " $0 }' "$w")
  [ -z "$spliced" ] || { echo "expression in a run block: $spliced"; false; }
  grep -c 'run: |' "$w" >/dev/null
  # The merge checks the head and the App's own status first.
  grep -qF '[[ "$head" == "$SHA" ]]' "$w"
  grep -qF '"$BOT"' "$w"
}
