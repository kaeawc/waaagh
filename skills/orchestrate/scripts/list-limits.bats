#!/usr/bin/env bats
# A list limit never hides items silently (#259): gh-issues.sh and gh-rest-pr.sh list warn on
# stderr when a read stops at --limit. gh is stubbed: `issue list` prints $FX/list.json, and REST
# pages of 100 are cut from $FX/rest.json. Run: bats list-limits.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FX"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
a="$*"
case "$a" in
  "issue list"*) cat "$FX/list.json" ;;
  *"repos/o/r/issues?state=open"* | *"repos/o/r/pulls?state=open"*)
    p=${a##*&page=}; p=${p%%[!0-9]*}
    jq --argjson p "$p" '.[($p - 1) * 100:$p * 100]' "$FX/rest.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1790510400 GH_READ_JITTER=0
}
items() { jq -n --argjson n "$1" '[range(1; $n + 1) | {number: ., title: "t\(.)", labels: []}]'; }
err() { cat "$BATS_TEST_TMPDIR/err" 2>/dev/null || true; }
gi() { "$SCRIPTS/gh-issues.sh" "$@" --repo o/r 2>"$BATS_TEST_TMPDIR/err"; }
rp() { "$SCRIPTS/gh-rest-pr.sh" "$@" --repo o/r 2>"$BATS_TEST_TMPDIR/err"; }

@test "gh-issues.sh over GraphQL warns when the list holds exactly --limit items" {
  items 5 >"$FX/list.json"
  ORCHESTRATE_GH_API=graphql run gi issues --limit 5
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 5 ]
  [[ "$(err)" == *"gh-issues.sh: warning: issues returned --limit 5 items; the list may be incomplete (raise --limit)"* ]]
  ORCHESTRATE_GH_API=graphql run gi issues --limit 6
  [ "$status" -eq 0 ]
  [ "$(grep -c warning "$BATS_TEST_TMPDIR/err" || true)" -eq 0 ]
  # a deliberate existence check stays quiet
  ORCHESTRATE_GH_API=graphql run gi issues --limit 5 --no-limit-warning
  [ "$status" -eq 0 ]
  [ "$(grep -c warning "$BATS_TEST_TMPDIR/err" || true)" -eq 0 ]
}

@test "gh-issues.sh over REST warns at --limit too, and stays quiet below it" {
  items 250 >"$FX/rest.json"
  ORCHESTRATE_GH_API=rest run gi issues --limit 200
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 200 ]
  [[ "$(err)" == *"warning: issues returned --limit 200 items"* ]]
  ORCHESTRATE_GH_API=rest run gi issues --limit 300
  [ "$(jq length <<<"$output")" -eq 250 ]
  [ "$(grep -c warning "$BATS_TEST_TMPDIR/err" || true)" -eq 0 ]
}

@test "gh-rest-pr.sh list warns when it stops at --limit after a full page" {
  jq -n '[range(1; 251) | {number: ., title: "t", body: "", state: "open", user: {login: "a"},
    draft: false, head: {ref: "b", sha: "s", repo: {full_name: "o/r"}}, base: {ref: "main", repo: {full_name: "o/r"}},
    labels: [], created_at: "x", updated_at: "x", html_url: "u"}]' >"$FX/rest.json"
  run rp list --limit 150
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 150 ]
  [[ "$(err)" == *"gh-rest-pr.sh: warning: list stopped at --limit 150 after a full page; the list may be incomplete"* ]]
  run rp list --limit 300
  [ "$(jq length <<<"$output")" -eq 250 ]
  [ "$(grep -c warning "$BATS_TEST_TMPDIR/err" || true)" -eq 0 ]
}
