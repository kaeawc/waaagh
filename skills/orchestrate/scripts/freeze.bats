#!/usr/bin/env bats
# Release freeze (#208): freeze.sh start/sweep/end/status disarms every armed auto-merge (read over
# REST, disarmed with `gh pr merge --disable-auto`), records it, re-arms it with its own method at
# the end, and fails loudly (exit 6, owner action) when GitHub refuses the GraphQL-only mutation.
# While FREEZE exists every merge path holds every PR (orch_hold_of; pr-merge.sh exit 14).
# Stubbed gh: open PRs in $FX/pulls/<n>.json. Run: bats scripts/freeze.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX/pulls" "$BATS_TEST_TMPDIR/bin"
  ST="$ORCHESTRATE_STATE_DIR/o__r"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Fixture switches in $FX:
  #   pulls/<n>.json  a PR; open ones are listed by `api --paginate repos/o/r/pulls?state=open...`
  #   refuse          `pr merge` fails with GitHub's GraphQL 403
  #   fail            `pr merge` fails with a plain error
  #   sticky          `pr merge --disable-auto` succeeds but the PR stays armed
  #   list-fails      listing the open PRs fails
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
case "$all" in
  "api --paginate repos/o/r/pulls?state=open"*)
    [ ! -f "$FX/list-fails" ] || { echo "HTTP 502" >&2; exit 1; }
    jq -s '[.[] | select(.state == "open")]' "$FX"/pulls/*.json ;;
  "api repos/o/r/pulls/"*) n=${all#api repos/o/r/pulls/}; cat "$FX/pulls/${n%% *}.json" ;;
  "pr merge "*)
    n=${all#pr merge }; n=${n%% *}
    if [ -f "$FX/refuse" ]; then
      echo "GraphQL: Resource not accessible by integration (HTTP 403)" >&2; exit 1
    fi
    if [ -f "$FX/fail" ]; then echo "something broke" >&2; exit 1; fi
    f="$FX/pulls/$n.json"
    case "$all" in
      *--disable-auto*) if [ ! -f "$FX/sticky" ]; then jq '.auto_merge = null' "$f" >"$f.t" && mv "$f.t" "$f"; fi ;;
      *--auto*) m=${all##*--}; jq --arg m "$m" '.auto_merge = {merge_method: $m, enabled_by: {login: "me"}}' "$f" >"$f.t" && mv "$f.t" "$f" ;;
    esac ;;
  *) echo "unexpected gh $all" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# pr N STATE METHOD|- [BY]: a PR fixture; METHOD - means auto-merge is not armed.
pr() {
  local am=null
  [ "$3" = - ] || am=$(jq -cn --arg m "$3" --arg by "${4:-dependabot[bot]}" '{merge_method: $m, enabled_by: {login: $by}}')
  jq -n --argjson n "$1" --arg st "$2" --argjson am "$am" \
    '{number: $n, state: $st, merged_at: null, head: {sha: "abc\($n)"}, auto_merge: $am}' >"$FX/pulls/$1.json"
}
armed() { jq -r '.auto_merge != null' "$FX/pulls/$1.json"; }
calls() { cat "$FX/calls" 2>/dev/null || true; }

@test "start freezes, disarms every armed open PR, records its method, and leaves unarmed ones alone" {
  pr 11 open squash
  pr 12 open -
  pr 13 open rebase owner
  run "$SCRIPTS/freeze.sh" start --reason "release 0.0.92" --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"frozen: every merge path holds every PR"* ]]
  [[ "$output" == *"disarmed: #11 (method squash, armed by dependabot[bot])"* ]]
  [[ "$output" == *"disarmed: #13 (method rebase, armed by owner)"* ]]
  [ "$(armed 11)" = false ]
  [ "$(armed 13)" = false ]
  [ "$(grep -c 'pr merge 12' "$FX/calls" || true)" -eq 0 ]
  [ "$(cut -f1,2,4 "$ST/freeze-disarmed")" = "$(printf '11\tsquash\tdependabot[bot]\n13\trebase\towner')" ]
  [ "$(cut -f2 "$ST/FREEZE")" = "release 0.0.92" ]
  run "$SCRIPTS/freeze.sh" status --repo o/r
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "frozen since:2026-09-27T12:00:00Z reason=release 0.0.92" ]]
  [[ "$output" == *"#13 disarmed:2026-09-27T12:00:00Z method:rebase armed_by:owner"* ]]
}

@test "sweep catches a PR armed since the freeze began; a re-armed PR keeps its first record; start again keeps the freeze" {
  pr 11 open squash
  "$SCRIPTS/freeze.sh" start --repo o/r
  pr 14 open merge
  pr 11 open rebase someone
  run "$SCRIPTS/freeze.sh" sweep --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"disarmed: #14 (method merge"* ]]
  [ "$(armed 14)" = false ]
  [ "$(armed 11)" = false ]
  [ "$(grep -c '^11' "$ST/freeze-disarmed")" -eq 1 ]
  [ "$(awk -F'\t' '$1 == 11 { print $2 }' "$ST/freeze-disarmed")" = squash ]
  run "$SCRIPTS/freeze.sh" sweep --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "swept: no open PR has auto-merge armed" ]
  run "$SCRIPTS/freeze.sh" start --repo o/r
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "already frozen since:2026-09-27T12:00:00Z" ]]
}

@test "end re-arms each recorded PR with its own method, skips merged or closed ones, and lifts the freeze" {
  pr 11 open squash
  pr 13 open rebase
  pr 15 open merge
  pr 16 open merge
  "$SCRIPTS/freeze.sh" start --repo o/r
  jq '.state = "closed" | .merged_at = "2026-09-27T12:30:00Z"' "$FX/pulls/15.json" >"$FX/t" && mv "$FX/t" "$FX/pulls/15.json"
  jq '.state = "closed"' "$FX/pulls/16.json" >"$FX/t" && mv "$FX/t" "$FX/pulls/16.json"
  pr 13 open rebase me
  run "$SCRIPTS/freeze.sh" end --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-armed: #11 (method squash; was armed by dependabot[bot])"* ]]
  [[ "$output" == *"re-armed: #13 (already armed)"* ]]
  [[ "$output" == *"skipped: #15 is merged"* ]]
  [[ "$output" == *"skipped: #16 is closed"* ]]
  [[ "$output" == *"unfrozen: merges resume"* ]]
  [[ "$(calls)" == *"pr merge 11 --repo o/r --auto --squash"* ]]
  [ "$(armed 11)" = true ]
  [ ! -e "$ST/FREEZE" ]
  [ ! -e "$ST/freeze-disarmed" ]
  run "$SCRIPTS/freeze.sh" status --repo o/r
  [ "$status" -eq 3 ]
  [[ "$output" == "not frozen"* ]]
  run "$SCRIPTS/freeze.sh" sweep --repo o/r
  [ "$status" -eq 3 ]
  run "$SCRIPTS/freeze.sh" end --repo o/r
  [ "$status" -eq 3 ]
}

@test "a refused disarm (GraphQL 403) is exit 6 with the owner action; a disarm done elsewhere then verifies" {
  pr 11 open squash
  touch "$FX/refuse"
  run "$SCRIPTS/freeze.sh" start --repo o/r
  [ "$status" -eq 6 ]
  [[ "$output" == *"refused: still armed: #11"* ]]
  [[ "$output" == *"owner action: GitHub refused the auto-merge disable here (GraphQL-only on GitHub)"* ]]
  [[ "$output" == *"disable_pr_auto_merge"* ]]
  [ -e "$ST/FREEZE" ]
  [ "$(cut -f1 "$ST/freeze-disarmed")" = 11 ]
  [[ "$(cat "$ST/freeze.log")" == *"pr=11 disarm refused: GraphQL"* ]]
  pr 11 open -
  run "$SCRIPTS/freeze.sh" sweep --repo o/r
  [ "$status" -eq 0 ]
  [ "$output" = "swept: no open PR has auto-merge armed" ]
}

@test "a refused re-arm keeps the freeze and the record, exit 6; done elsewhere, end then lifts it" {
  pr 11 open squash
  "$SCRIPTS/freeze.sh" start --repo o/r
  touch "$FX/refuse"
  run "$SCRIPTS/freeze.sh" end --repo o/r
  [ "$status" -eq 6 ]
  [[ "$output" == *"still frozen: 11 not re-armed"* ]]
  [[ "$output" == *"auto-merge enable PRs #11(--squash) elsewhere"* ]]
  [[ "$output" == *"enable_pr_auto_merge"* ]]
  [ -e "$ST/FREEZE" ]
  [ "$(cut -f1 "$ST/freeze-disarmed")" = 11 ]
  pr 11 open squash me
  run "$SCRIPTS/freeze.sh" end --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-armed: #11 (already armed)"* ]]
  [ ! -e "$ST/FREEZE" ]
}

@test "end --no-rearm lifts the freeze and lists what was not re-armed" {
  pr 11 open squash
  "$SCRIPTS/freeze.sh" start --repo o/r
  run "$SCRIPTS/freeze.sh" end --no-rearm --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"not re-armed: #11 (method squash)"* ]]
  [ "$(grep -c -- '--auto' "$FX/calls" || true)" -eq 0 ]
  [ ! -e "$ST/FREEZE" ]
  [[ "$(cat "$ST/freeze.log")" == *"re-arm skipped (--no-rearm): 11"* ]]
}

@test "plain failures are exit 5: a list that cannot be read, a failed disarm, a PR still armed, a failed re-arm, an unreadable PR" {
  pr 11 open squash
  touch "$FX/list-fails"
  run "$SCRIPTS/freeze.sh" start --repo o/r
  [ "$status" -eq 5 ]
  [[ "$output" == *"error: could not list the open PRs of o/r over REST"* ]]
  rm "$FX/list-fails"
  touch "$FX/fail"
  run "$SCRIPTS/freeze.sh" sweep --repo o/r
  [ "$status" -eq 5 ]
  [[ "$output" == *"error: disarming PR 11 failed: something broke"* ]]
  rm "$FX/fail"
  touch "$FX/sticky"
  run "$SCRIPTS/freeze.sh" sweep --repo o/r
  [ "$status" -eq 5 ]
  [[ "$output" == *"error: PR 11 is still armed after --disable-auto"* ]]
  rm "$FX/sticky"
  "$SCRIPTS/freeze.sh" sweep --repo o/r
  touch "$FX/fail"
  run "$SCRIPTS/freeze.sh" end --repo o/r
  [ "$status" -eq 5 ]
  [[ "$output" == *"error: re-arming PR 11 failed: something broke"* ]]
  [ -e "$ST/FREEZE" ]
  rm "$FX/fail" "$FX/pulls/11.json"
  run "$SCRIPTS/freeze.sh" end --repo o/r
  [ "$status" -eq 5 ]
  [[ "$output" == *"error: PR 11 could not be read"* ]]
  [ -e "$ST/FREEZE" ]
}

@test "usage: a missing or unknown command, an unknown flag" {
  run "$SCRIPTS/freeze.sh"
  [ "$status" -eq 2 ]
  run "$SCRIPTS/freeze.sh" thaw
  [ "$status" -eq 2 ]
  run "$SCRIPTS/freeze.sh" start --bogus
  [ "$status" -eq 2 ]
  [ ! -e "$FX/calls" ]
}

@test "while frozen every PR is held: orch_hold_of, its hint, and pr-merge.sh exit 14 before any GitHub read" {
  mkdir -p "$ST"
  run bash -c 'source "$1/_lib.sh"; orch_hold_of o/r 7' _ "$SCRIPTS"
  [ "$status" -eq 1 ]
  printf '2026-09-27T12:00:00Z\trelease 1.2\n' >"$ST/FREEZE"
  run bash -c 'source "$1/_lib.sh"; orch_hold_of o/r "#7"' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = "#7 until:freeze-end since:2026-09-27T12:00:00Z release freeze: release 1.2" ]
  run bash -c 'source "$1/_lib.sh"; orch_hold_hint "$2"' _ "$SCRIPTS" "$output"
  [ "$output" = "freeze.sh end lifts it" ]
  run bash -c 'source "$1/_lib.sh"; orch_hold_hint "#7 until:owner"' _ "$SCRIPTS"
  [ "$output" = "hold.sh release clears it" ]
  run "$SCRIPTS/pr-merge.sh" --repo o/r --pr 7 --head abcdef1
  [ "$status" -eq 14 ]
  [[ "$output" == "held: PR 7 is in the hold file (#7 until:freeze-end "*"); freeze.sh end lifts it" ]]
  [ ! -e "$FX/calls" ]
}
