#!/usr/bin/env bats
# Shared rerunnable-verdict list and reruns.log reader in _lib.sh (#275).

setup() { load test_helper; }

lib() { bash -c "source '$BATS_TEST_DIRNAME/_lib.sh'; $*"; }

@test "orch_verdict_rerunnable accepts the rerun verdicts, any case, underscore as dash" {
  for v in flake known-flake infra rerun rerun-dont-fix RERUN_DONT_FIX Known_Flake; do
    run lib "orch_verdict_rerunnable '$v'"
    [ "$status" -eq 0 ]
  done
}

@test "orch_verdict_rerunnable refuses everything else" {
  for v in investigate unclassified rerun-failed "" fix; do
    run lib "orch_verdict_rerunnable '$v'"
    [ "$status" -eq 1 ]
  done
}

@test "orch_rerun_seen: latest record decides, a refused rerun does not count" {
  f="$BATS_TEST_TMPDIR/reruns.log"
  printf 't\trun=5\tfull\n' >"$f"
  run lib "reruns='$f'; orch_rerun_seen 5"
  [ "$status" -eq 0 ]
  printf 't\trun=5\tfailed\n' >"$f"
  run lib "reruns='$f'; orch_rerun_seen 5"
  [ "$status" -eq 1 ]
  run lib "reruns='$f'; orch_rerun_seen 6"
  [ "$status" -eq 1 ]
  run lib "reruns='$BATS_TEST_TMPDIR/none'; orch_rerun_seen 5"
  [ "$status" -eq 1 ]
}
