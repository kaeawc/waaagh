#!/usr/bin/env bats
# routines.sh (../routines.md): the RemoteTrigger bodies for the four traveling-mode routines, the
# record a teardown reads, and the labels. gh is stubbed. Run: bats routines.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR FX="$T/fx"
  mkdir -p "$FX" "$T/bin"
  export FX PATH="$T/bin:$PATH" ORCHESTRATE_STATE_DIR="$T/state" ORCHESTRATE_NOW=1795200000
  cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$FX/calls"
case "$1 $2" in
  "label list") [ ! -f "$FX/labels-fail" ] || exit 1; printf 'bug\ncloud-ready\ncloud-review\n' ;;
  "label create") ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$T/bin/gh"
}
rt() { "$SCRIPTS/routines.sh" "$@"; }
ENV=env_0123abc

@test "render: the orchestrator gets its schedule, three sources and the cycle; created disabled" {
  run rt render --role orchestrator --repo o/r --env "$ENV"
  [ "$status" -eq 0 ]
  [ "$(jq -r .name <<<"$output")" = "travel: orchestrator (o/r)" ]
  [ "$(jq -r .enabled <<<"$output")" = false ]
  [ "$(jq -r .clear_mcp_connections <<<"$output")" = true ]
  [ "$(jq -r .cron_expression <<<"$output")" = "7 * * * *" ]
  [ "$(jq -r .job_config.ccr.environment_id <<<"$output")" = "$ENV" ]
  [ "$(jq -r .job_config.ccr.session_context.model <<<"$output")" = claude-sonnet-5-5 ]
  [ "$(jq -r '[.job_config.ccr.session_context.sources[].git_repository.url] | join(" ")' <<<"$output")" = \
    "https://github.com/o/r https://github.com/o/orchestrate-state https://github.com/kaeawc/waaagh" ]
  p=$(jq -r '.job_config.ccr.events[0].data.message.content' <<<"$output")
  [[ "$p" == *'"$SCRIPTS/travel-cycle.sh" run --repo o/r --store "$STORE"'* ]]
  [[ "$p" != *"{{"* ]]
  [[ "$(jq -r '.job_config.ccr.events[0].data.uuid' <<<"$output")" =~ ^[0-9a-f-]{36}$ ]]
  run rt render --role orchestrator --repo o/r --env "$ENV" --minute 37 --store o/s --waaagh me/w --model claude-opus-5-5
  [ "$(jq -r .cron_expression <<<"$output")" = "37 * * * *" ]
  [ "$(jq -r .job_config.ccr.session_context.model <<<"$output")" = claude-opus-5-5 ]
  [[ "$(jq -c .job_config.ccr.session_context.sources <<<"$output")" == *'o/s"'*'me/w"'* ]]
}

@test "render: workers have no schedule, the sources and model their role needs; --update leaves name and enabled alone" {
  for r in implement repair; do
    run rt render --role "$r" --repo o/r --env "$ENV"
    [ "$(jq -r .name <<<"$output")" = "travel: worker-$r (o/r)" ]
    [ "$(jq -r 'has("cron_expression")' <<<"$output")" = false ]
    [ "$(jq -r .job_config.ccr.session_context.model <<<"$output")" = claude-opus-5-5 ]
    [ "$(jq -r '.job_config.ccr.session_context.sources | length' <<<"$output")" -eq 1 ]
  done
  run rt render --role review --repo o/r --env "$ENV"
  [ "$(jq -r '.job_config.ccr.session_context.sources | length' <<<"$output")" -eq 2 ]
  [[ "$(jq -r '.job_config.ccr.events[0].data.message.content' <<<"$output")" == *'app-broker.sh" status --repo o/r'* ]]
  run rt render --role review --repo o/r --env "$ENV" --update
  [ "$(jq -r 'has("name") or has("enabled") or has("clear_mcp_connections")' <<<"$output")" = false ]
  [ "$(jq -r '.job_config.ccr.session_context.model' <<<"$output")" = claude-sonnet-5-5 ]
}

@test "hook: implement on issues, repair and review on pull_request filtered to their label; none for the orchestrator" {
  run rt hook --role implement --repo o/r --trigger-id trig_01A
  [ "$(jq -c . <<<"$output")" = '{"routine_trigger_id":"trig_01A","hook_type":"app","source":"github","scope_id":"o/r","events":["issues"]}' ]
  run rt hook --role review --repo o/r --trigger-id trig_01B
  [ "$(jq -c '[.events, .filter]' <<<"$output")" = '[["pull_request"],{"labels":["cloud-review"]}]' ]
  run rt hook --role repair --repo o/r --trigger-id trig_01C
  [ "$(jq -r '.filter.labels[0]' <<<"$output")" = cloud-repair ]
  run rt hook --role orchestrator --repo o/r --trigger-id trig_01D
  [ "$status" -eq 2 ]
}

@test "record, list and forget keep the teardown's list" {
  run rt list --repo o/r
  [ "$output" = "none recorded" ]
  rt record --role orchestrator --repo o/r --trigger-id trig_01A
  rt record --role review --repo o/r --trigger-id trig_01B
  run rt record --role review --repo o/r --trigger-id trig_01B
  [ "$output" = "already recorded: trig_01B" ]
  run rt list --repo o/r
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == $'orchestrator\ttrig_01A\t2026-'* ]]
  run rt forget --repo o/r --trigger-id trig_01A
  [ "$output" = "forgot trig_01A" ]
  run rt forget --repo o/r --trigger-id trig_01A
  [ "$output" = "not recorded: trig_01A" ]
  run rt list --repo o/r
  [[ "$output" == review$'\t'trig_01B* ]]
}

@test "labels: dry run by default, --apply creates only the missing ones" {
  run rt labels --repo o/r
  [ "$status" -eq 0 ]
  [[ "$output" == *"have cloud-ready"*"would create cloud-dispatch"*"have cloud-review"* ]]
  [ -z "$(grep "label create" "$FX/calls" 2>/dev/null)" ]
  run rt labels --repo o/r --apply
  [ "$(grep -c 'label create' "$FX/calls")" -eq 3 ]
  grep -q 'label create cloud-dispatched --repo o/r' "$FX/calls"
  touch "$FX/labels-fail"
  run rt labels --repo o/r
  [ "$status" -eq 3 ]
}

@test "usage" {
  run rt roles
  [ "$output" = $'orchestrator\nimplement\nrepair\nreview' ]
  run rt render --role orchestrator --repo o/r
  [ "$status" -eq 2 ]
  run rt render --role nope --repo o/r --env "$ENV"
  [ "$status" -eq 2 ]
  run rt render --role orchestrator --repo o/r --env "$ENV" --minute 60
  [ "$status" -eq 2 ]
  run rt hook --role review --repo o/r --trigger-id bad
  [ "$status" -eq 2 ]
  run rt list --repo bad
  [ "$status" -eq 2 ]
  run rt
  [ "$status" -eq 2 ]
}
