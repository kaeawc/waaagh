#!/usr/bin/env bash
# Traveling-mode routines (../routines.md): render the RemoteTrigger bodies that create, refine and
# wire the four cloud routines of one repository, and keep the record of the routines created, so
# that a teardown knows what to delete. This script never calls RemoteTrigger: the session sends
# what it prints (RemoteTrigger create / update / create_webhook_trigger) and records the answer.
#
# Usage: routines.sh roles
#        routines.sh render --role ROLE --repo OWNER/REPO --env ENV_ID [--store OWNER/NAME]
#                           [--waaagh OWNER/NAME] [--model MODEL] [--minute M] [--update]
#        routines.sh hook --role ROLE --repo OWNER/REPO --trigger-id ID
#        routines.sh record --role ROLE --repo OWNER/REPO --trigger-id ID
#        routines.sh forget --repo OWNER/REPO --trigger-id ID
#        routines.sh list --repo OWNER/REPO
#        routines.sh labels --repo OWNER/REPO [--apply]
#   roles    the four roles, one per line: orchestrator implement repair review
#   render   the body for RemoteTrigger create: the prompt from templates/routines/ROLE.txt with
#            {{REPO}}, {{STORE}} and {{WAAAGH}} filled in, the sources the role needs, its model, and
#            enabled=false. The orchestrator runs hourly at minute M (default 7); a worker has no
#            schedule (hook wires its GitHub trigger). --update prints the body for RemoteTrigger
#            update instead (prompt, sources, model, schedule; never the name or enabled), which is
#            how a template change reaches a routine that exists.
#   hook     the body for RemoteTrigger create_webhook_trigger: implement fires on `issues`,
#            repair and review on `pull_request` filtered to their label. The orchestrator has none.
#   record   append ROLE and ID to routines.tsv in the repository's state dir; forget removes one
#   list     the recorded routines: role, trigger id, recorded at
#   labels   the labels the routines use; --apply creates the missing ones
#   --store   the private state store (default: <owner>/orchestrate-state)
#   --waaagh  the waaagh checkout the orchestrator and reviewer run scripts from (default
#             kaeawc/waaagh)
#   --model   default: claude-sonnet-5-5 for orchestrator and review, claude-opus-5-5 for implement
#             and repair
# Exit: 0 done | 3 a GitHub call failed | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"
orch_gh_priority normal

op=${1:-}
case "$op" in roles | render | hook | record | forget | list | labels) shift ;; -h | --help) orch_usage; exit 0 ;; *) orch_usage >&2; exit 2 ;; esac
role="" repo="" env_id="" store="" waaagh=kaeawc/waaagh model="" minute=7 update=no trigger="" apply=no
while (($#)); do
  case "$1" in
    --role) role=${2:-}; shift 2 ;;
    --repo) repo=${2:-}; shift 2 ;;
    --env) env_id=${2:-}; shift 2 ;;
    --store) store=${2:-}; shift 2 ;;
    --waaagh) waaagh=${2:-}; shift 2 ;;
    --model) model=${2:-}; shift 2 ;;
    --minute) minute=${2:-}; shift 2 ;;
    --trigger-id) trigger=${2:-}; shift 2 ;;
    --update) update=yes; shift ;;
    --apply) apply=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "routines.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
bad() { echo "routines.sh: $1" >&2; exit 2; }
slug='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
roles="orchestrator implement repair review"
labels="cloud-ready cloud-dispatch cloud-dispatched cloud-repair cloud-review"

if [[ "$op" == roles ]]; then tr ' ' '\n' <<<"$roles"; exit 0; fi
[[ "$repo" =~ $slug ]] || bad "--repo OWNER/REPO"
case "$op" in render | hook | record) [[ " $roles " == *" $role "* ]] || bad "--role must be one of: $roles" ;; esac
case "$op" in hook | record | forget) [[ "$trigger" =~ ^trig_[A-Za-z0-9]+$ ]] || bad "--trigger-id trig_..." ;; esac

case "$op" in
  render)
    [[ "$env_id" =~ ^env_[A-Za-z0-9]+$ ]] || bad "--env env_... (the cloud environment the routines run in)"
    store=${store:-${repo%%/*}/orchestrate-state}
    [[ "$store" =~ $slug && "$waaagh" =~ $slug ]] || bad "--store and --waaagh are OWNER/NAME"
    [[ "$minute" =~ ^([0-9]|[1-5][0-9])$ ]] || bad "--minute 0-59"
    case "$role" in
      orchestrator) names="travel: orchestrator" sources="$repo $store $waaagh" def=claude-sonnet-5-5 cron="$minute * * * *" ;;
      implement) names="travel: worker-implement" sources="$repo" def=claude-opus-5-5 cron="" ;;
      repair) names="travel: worker-repair" sources="$repo" def=claude-opus-5-5 cron="" ;;
      review) names="travel: worker-review" sources="$repo $waaagh" def=claude-sonnet-5-5 cron="" ;;
    esac
    model=${model:-$def}
    [[ "$model" =~ ^claude-[a-z0-9-]+$ ]] || bad "--model claude-..."
    tpl="$here/../templates/routines/$role.txt"
    prompt=$(sed -e "s|{{REPO}}|$repo|g" -e "s|{{STORE}}|$store|g" -e "s|{{WAAAGH}}|$waaagh|g" "$tpl")
    uuid=$( (uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid) | tr 'A-F' 'a-f')
    jq -n --arg name "$names ($repo)" --arg cron "$cron" --arg env "$env_id" --arg model "$model" \
      --arg prompt "$prompt" --arg uuid "$uuid" --arg sources "$sources" --arg update "$update" '
      {job_config: {ccr: {
          environment_id: $env,
          events: [{data: {message: {content: $prompt, role: "user"}, parent_tool_use_id: null,
                           session_id: "", type: "user", uuid: $uuid}}],
          session_context: {
            allowed_tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"],
            model: $model,
            sources: [$sources | split(" ")[] | {git_repository: {url: "https://github.com/\(.)"}}]}}}}
      + (if $cron == "" then {} else {cron_expression: $cron} end)
      + (if $update == "yes" then {} else {name: $name, enabled: false, clear_mcp_connections: true} end)' ;;
  hook)
    case "$role" in
      orchestrator) bad "the orchestrator runs on its schedule: it has no webhook trigger" ;;
      implement) jq -n --arg t "$trigger" --arg r "$repo" '{routine_trigger_id: $t, hook_type: "app", source: "github", scope_id: $r, events: ["issues"]}' ;;
      *) jq -n --arg t "$trigger" --arg r "$repo" --arg l "cloud-$role" '{routine_trigger_id: $t, hook_type: "app", source: "github", scope_id: $r, events: ["pull_request"], filter: {labels: [$l]}}' ;;
    esac ;;
  record)
    f="$(orch_state_dir "$repo")/routines.tsv"
    ! grep -q "	$trigger	" "$f" 2>/dev/null || { echo "already recorded: $trigger"; exit 0; }
    printf '%s\t%s\t%s\n' "$role" "$trigger" "$(orch_iso "$(orch_now)")" >>"$f"
    echo "recorded $role $trigger" ;;
  forget)
    f="$(orch_state_dir "$repo")/routines.tsv"
    if grep -q "	$trigger	" "$f" 2>/dev/null; then
      grep -v "	$trigger	" "$f" >"$f.tmp" || true
      mv "$f.tmp" "$f"
      echo "forgot $trigger"
    else
      echo "not recorded: $trigger"
    fi ;;
  list)
    f="$(orch_state_root)/${repo//\//__}/routines.tsv"
    [[ -s "$f" ]] && cat "$f" || echo "none recorded" ;;
  labels)
    have=$(gh label list --repo "$repo" --limit 200 --json name --jq '.[].name' 2>/dev/null) ||
      { echo "routines.sh: cannot read the labels of $repo" >&2; exit 3; }
    for l in $labels; do
      if grep -qx "$l" <<<"$have"; then echo "have $l"; continue; fi
      if [[ "$apply" == yes ]]; then
        gh label create "$l" --repo "$repo" --color ededed --description "waaagh traveling mode" >/dev/null ||
          { echo "routines.sh: could not create $l" >&2; exit 3; }
        echo "created $l"
      else
        echo "would create $l"
      fi
    done ;;
esac
