#!/usr/bin/env bats
# Standard cloud briefs kept in the target repository (#67): cloud-dispatch.sh briefs install /
# check, the one-line --brief-ref prompt (fixtures still named), repair dispatches, and the created
# filter that drops the echoed prompt. gh is stubbed from $FX. Run: bats cloud-briefs.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FX"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
f=""
case "$*" in
  "api repos/o/r/contents/.claude/briefs/implement.md?ref=main"*) f=c-implement ;;
  "api repos/o/r/contents/.claude/briefs/repair.md?ref=main"*) f=c-repair ;;
  "api repos/o/r/issues/"*"/comments?per_page=100"*) f=comments ;;
  "api repos/o/r/issues/"*"/timeline?per_page=100"*) f=timeline ;;
  "api repos/o/r/issues/"*) f=issue ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
[ -f "$FX/$f.json" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
cat "$FX/$f.json"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_JITTER=0
  ST="$ORCHESTRATE_STATE_DIR/o__r"
  CO="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$CO"
  echo '[]' >"$FX/comments.json"
  echo '[]' >"$FX/timeline.json"
}
cd_() { "$SCRIPTS/cloud-dispatch.sh" "$@" --repo o/r --no-blocker-check; }   # blockers: cloud-blockers.bats
remote_file() { # remote_file KIND FILE: serve FILE as the contents API answer for KIND
  jq -n --arg c "$(base64 <"$2" | tr -d '\n')" '{content: $c, encoding: "base64"}' >"$FX/c-$1.json"
}
has() { grep -qF -- "$2" "$1" || { echo "missing in ${1#"$ROOT"/}: $2"; return 1; }; }
ver() { # ver K: the version on the first line of waaagh's K brief, so a bump needs no test edit (#199)
  sed -n '1s/.*waaagh-brief [a-z]* v\([0-9]*\).*/\1/p' "$ROOT/skills/orchestrate/briefs/$1.md"
}

@test "briefs install fills repo, base and gates, keeps per-issue values for the prompt" {
  run cd_ briefs install --dir "$CO" --base trunk --gates "make test"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'installed %s\ninstalled %s' "$CO/.claude/briefs/implement.md" "$CO/.claude/briefs/repair.md")" ]
  I="$CO/.claude/briefs/implement.md"
  [[ "$(sed -n 1p "$I")" == "<!-- waaagh-brief implement v$(ver implement)."* ]]
  has "$I" "implement one issue in o/r"
  has "$I" 'Create BRANCH from `origin/trunk`'
  has "$I" "Gates, all passing before you push: make test."
  has "$I" "If the prompt names fixtures, commit the captured fixtures from those URLs verbatim"
  has "$I" "never pkill, killall or kill a process you did not start"
  has "$CO/.claude/briefs/repair.md" "Check out BRANCH"
  run ! grep -q '{{' "$I" "$CO/.claude/briefs/repair.md"
  [ ! -s "$FX/calls" ]
  # Re-running is a no-op; a hand-edited copy is never overwritten without --force.
  run cd_ briefs install --dir "$CO" --base trunk --gates "make test" --kind implement
  [ "$output" = "current $I" ]
  echo "local knob: TEST_TIMEOUT=600" >>"$I"
  run cd_ briefs install --dir "$CO" --base trunk --gates "make test" --kind implement
  [ "$status" -eq 3 ]
  grep -q "local knob" "$I"
  run cd_ briefs install --dir "$CO" --base trunk --gates "make test" --kind implement --force
  [ "$output" = "installed $I" ]
  ! grep -q "local knob" "$I"
}

@test "a state-dir template overrides waaagh's default" {
  mkdir -p "$ST/briefs"
  printf '<!-- waaagh-brief implement v3 -->\nRepo {{REPO}} on {{BASE}}.\n' >"$ST/briefs/implement.md"
  cd_ briefs install --dir "$CO" --base main --kind implement
  [ "$(cat "$CO/.claude/briefs/implement.md")" = "$(printf '<!-- waaagh-brief implement v3 -->\nRepo o/r on main.')" ]
}

@test "briefs check: ok, custom, edited-but-current, outdated and missing (exit 6)" {
  run cd_ briefs check --dir "$CO" --base main
  [ "$status" -eq 6 ]
  [ "$output" = "$(printf 'brief implement missing %s\nbrief repair missing %s' "$CO/.claude/briefs/implement.md" "$CO/.claude/briefs/repair.md")" ]
  cd_ briefs install --dir "$CO" --base main
  run cd_ briefs check --dir "$CO" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'brief implement ok v%s\nbrief repair ok v%s' "$(ver implement)" "$(ver repair)")" ]
  # A repository's own edits at the current version are fine; a version line it dropped is "custom".
  echo "Extra repo rule." >>"$CO/.claude/briefs/implement.md"
  printf 'Our own repair brief.\n' >"$CO/.claude/briefs/repair.md"
  run cd_ briefs check --dir "$CO" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'brief implement ok v%s\nbrief repair custom' "$(ver implement)")" ]
  sed "s/implement v$(ver implement)/implement v0/" "$CO/.claude/briefs/implement.md" >"$CO/x"
  mv "$CO/x" "$CO/.claude/briefs/implement.md"
  run cd_ briefs check --dir "$CO" --base main --kind implement
  [ "$status" -eq 6 ]
  [ "$output" = "brief implement outdated v0 (template v$(ver implement))" ]
}

@test "briefs check --remote reads the base branch through gh-read" {
  cd_ briefs install --dir "$CO" --base main
  remote_file implement "$CO/.claude/briefs/implement.md"
  run cd_ briefs check --remote --base main
  [ "$status" -eq 6 ]
  [ "$output" = "$(printf 'brief implement ok v%s\nbrief repair missing .claude/briefs/repair.md on main' "$(ver implement)")" ]
  remote_file repair "$CO/.claude/briefs/repair.md"
  run cd_ briefs check --remote --base main
  [ "$status" -eq 0 ]
  echo 'not json' >"$FX/c-repair.json"
  run cd_ briefs check --remote --base main --kind repair
  [ "$status" -eq 7 ]
}

@test "payload --brief-ref sends a one-line prompt" {
  run cd_ payload --issue 5 --env env_1 --source u --base main --fixtures none --brief-ref implement
  [ "$status" -eq 0 ]
  msg=$(jq -r '.job_config.ccr.events[0].data.message' <<<"$output")
  [ "$msg" = "Follow .claude/briefs/implement.md for issue #5 (branch work/5-auto)." ]
  run cd_ brief --issue 5 --brief-ref implement
  [ "$output" = "Follow .claude/briefs/implement.md for issue #5 (branch work/5-auto)." ]
}

@test "the one-line prompt still names the fixtures the check requires, and refuses without them" {
  jq -n '{number: 7, html_url: "https://github.com/o/r/issues/7", body: "Parser for the captured dumps.", labels: []}' >"$FX/issue.json"
  run cd_ payload --issue 7 --env env_1 --source u --base main --brief-ref implement
  [ "$status" -eq 5 ]
  jq -n '[{id: 40, body: "<details><summary>fixtures/d.txt</summary>\n\nraw\n</details>",
    html_url: "https://github.com/o/r/issues/7#issuecomment-40"}]' >"$FX/comments.json"
  run cd_ payload --issue 7 --env env_1 --source u --base main --brief-ref implement
  [ "$status" -eq 0 ]
  msg=$(jq -r '.job_config.ccr.events[0].data.message' <<<"$output")
  [ "$msg" = "Follow .claude/briefs/implement.md for issue #7 (branch work/7-auto). Fixtures: https://github.com/o/r/issues/7#issuecomment-40 (commit verbatim)." ]
}

@test "repair: needs --pr, skips the ledger refusal, records as a repair, never as a dispatch" {
  cd_ queue add 5 6
  cd_ record --issue 5 --trigger trig_a --run-at 2026-09-27T12:01:00Z
  run cd_ payload --issue 5 --env env_1 --source u --base main --brief-ref repair
  [ "$status" -eq 2 ]
  run cd_ payload --issue 5 --pr '#31' --env env_1 --source u --base main --brief-ref repair
  [ "$status" -eq 0 ]
  jq -e '.name == "r #5 cloud repair of PR #31" and .run_once_at == "2026-09-27T12:01:20Z"
    and .job_config.ccr.events[0].data.message == "Follow .claude/briefs/repair.md for PR #31 (issue #5, branch work/5-auto)."' <<<"$output"
  [ ! -s "$FX/calls" ]
  run cd_ record --issue 5 --kind repair --pr 31 --trigger trig_r --run-at 2026-09-27T12:01:20Z
  [ "${lines[0]}" = "recorded 5 trig_r 2026-09-27T12:01:20Z repair" ]
  cd_ record --issue 6 --kind repair --pr 32 --trigger trig_s --run-at 2026-09-27T12:01:40Z
  run cd_ next
  [ "$output" = "6" ]
  run cd_ status
  [ "$output" = "$(printf 'queued 1\ndispatched 1\nrepairs 2\nlast #6 trig_s 2026-09-27T12:01:40Z\nbackoff 0')" ]
  run cd_ payload --issue 5 --env e --source u --base main --fixtures none
  [ "$status" -eq 3 ]
  [[ "$output" == *"trig_a at"* && "$output" != *trig_r* ]]
}

@test "created keeps only the trigger id and run time from an echo-heavy create response" {
  brief=$(printf 'x%.0s' $(seq 1 900))
  jq -n --arg b "$brief" '{trigger: {id: "trig_01AB", name: "r #5 cloud lane", run_once_at: "2026-09-27T12:01:00Z",
    job_config: {ccr: {events: [{data: {message: $b}}]}}, derived_state: {prompt: $b}},
    session_request: {prompt: $b}, events: [{message: $b}]}' >"$FX/resp.json"
  run cd_ created --response "$FX/resp.json"
  [ "$status" -eq 0 ]
  [ "$output" = "created trig_01AB 2026-09-27T12:01:00Z" ]
  run cd_ created --issue 5 <"$FX/resp.json"
  [ "$output" = "created trig_01AB 2026-09-27T12:01:00Z" ]
  [ "$(cat "$ST/cloud-sessions.tsv")" = "$(printf '5\ttrig_01AB\t2026-09-27T12:01:00Z\t2026-09-27T12:00:00Z')" ]
  run cd_ created --issue 5 --response "$FX/resp.json"
  [ "$status" -eq 3 ]
  echo '{"error": "rate limited"}' >"$FX/bad.json"
  run cd_ created --response "$FX/bad.json"
  [ "$status" -eq 7 ]
  run cd_ created <<<"garbage"
  [ "$status" -eq 7 ]
}

@test "usage: bad brief-ref, kind and briefs subcommand; -h still ends at the exit line" {
  run cd_ brief --issue 5 --brief-ref other
  [ "$status" -eq 2 ]
  run cd_ briefs install --kind bogus --base main
  [ "$status" -eq 2 ]
  run cd_ briefs
  [ "$status" -eq 2 ]
  run cd_ record --issue 5 --kind all --trigger t --run-at 2026-09-27T12:01:00Z
  [ "$status" -eq 2 ]
  run "$SCRIPTS/cloud-dispatch.sh" -h
  [[ "${lines[${#lines[@]}-1]}" == "# Exit: 0 ok"* ]]
}

@test "doctrine: briefs in the repository, one-line prompt, echo filter (#67)" {
  R="$ROOT/skills/orchestrate/roles/cloud-dispatch.md"
  has "$R" "## Briefs in the repository"
  has "$R" "briefs check --remote"
  has "$R" "Follow .claude/briefs/implement.md"
  has "$R" "cloud-dispatch.sh created --issue N"
  has "$R" "--brief-ref repair"
  has "$ROOT/skills/orchestrate/SKILL.md" ".claude/briefs/"
  has "$ROOT/skills/orchestrate/roles/README.md" "../briefs/implement.md"
  has "$ROOT/README.md" "briefs install"
  for k in implement repair; do
    [[ "$(sed -n 1p "$ROOT/skills/orchestrate/briefs/$k.md")" == "<!-- waaagh-brief $k v"* ]]
    [ "$(wc -c <"$ROOT/skills/orchestrate/briefs/$k.md")" -lt 2200 ]
  done
}
