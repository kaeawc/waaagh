#!/usr/bin/env bats
# selftest_helper.bash is split in two (#310): selftest_fixtures.bash holds the data fixtures,
# selftest_stubs.bash the gh stubs, and the helper loads both. A suite can load the fixtures alone.

setup() { load test_helper; }

@test "selftest_fixtures loads on its own: its fixtures work and no gh stub is defined" {
  load selftest_fixtures
  [ "$(pr_row 1 me false false MERGEABLE "$OKC" | jq -r .number)" = 1 ]
  [ "$(check build SUCCESS wf 2026-09-27T01:00:00Z | jq -r .name)" = build ]
  run declare -F stub_gh
  [ "$status" -ne 0 ]
  run declare -F stub_gh_router
  [ "$status" -ne 0 ]
  run declare -F stub_gh_merge_path
  [ "$status" -ne 0 ]
}

@test "selftest_helper still loads both halves" {
  load selftest_helper
  declare -F stub_gh
  declare -F stub_gh_router
  declare -F stub_gh_merge_path
  declare -F pr_row
  declare -F merge_fixture
}

@test "selftest_stubs loads on its own and defines no fixture helper" {
  load selftest_stubs
  declare -F stub_gh_router
  run declare -F pr_row
  [ "$status" -ne 0 ]
  run declare -F check
  [ "$status" -ne 0 ]
}

@test "orch_rest_pr shows gh-rest-pr.sh's stderr on failure and stays quiet on success" {
  mkdir -p "$BATS_TEST_TMPDIR/s"
  printf '#!/usr/bin/env bash\n[ "$1" = ok ] && { echo body; exit 0; }\necho "reason: boom" >&2; exit 3\n' >"$BATS_TEST_TMPDIR/s/gh-rest-pr.sh"
  chmod +x "$BATS_TEST_TMPDIR/s/gh-rest-pr.sh"
  export ORCHESTRATE_SCRIPTS_DIR="$BATS_TEST_TMPDIR/s"
  source "$BATS_TEST_DIRNAME/_lib.sh"
  run --separate-stderr orch_rest_pr ok
  [ "$status" -eq 0 ]
  [ "$output" = body ]
  [ -z "$stderr" ]
  run --separate-stderr orch_rest_pr list --repo o/r
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"gh-rest-pr.sh list failed (exit 3): reason: boom"* ]]
}
