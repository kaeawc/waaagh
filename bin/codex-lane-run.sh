#!/usr/bin/env bash
# Run one `codex exec` implementation lane with supervision: a spec/worktree identity check, a
# snapshot of the spec, soft progress checkpoints, a stall timeout and a hard cap.
#
# Exit: codex's own exit code | 64 spec does not name this worktree | 124 hard cap | 125 stalled
# Files next to --log: .spec (snapshot) .args .stderr .progress.latest .progress .final .exit
# Env: CODEX_LANE_SERVICE_TIER (e.g. fast), CODEX_LANE_SOL_MODEL (default gpt-6.1-sol)
set -euo pipefail

usage() {
  echo "Usage: codex-lane-run.sh --model SLUG --spec FILE --final FILE --cd DIR [--log FILE] [--effort RUNG] [--soft SECS] [--stall SECS] [--hard SECS] [--poll SECS]" >&2
}

MODEL='' EFFORT='' SPEC='' FINAL='' LOG='' CD_DIR=''
EFFORT_SET=0 LOG_SET=0
SOFT=1800 STALL=600 HARD=7200 POLL=30
while (($#)); do
  case "$1" in
    --model|--effort|--spec|--final|--log|--cd|--soft|--stall|--hard|--poll)
      if (($# < 2)); then usage; exit 2; fi
      key=$1 value=$2; shift 2
      case "$key" in
        --model) MODEL=$value ;; --effort) EFFORT=$value; EFFORT_SET=1 ;;
        --spec) SPEC=$value ;; --final) FINAL=$value ;;
        --log) LOG=$value; LOG_SET=1 ;; --cd) CD_DIR=$value ;;
        --soft) SOFT=$value ;; --stall) STALL=$value ;; --hard) HARD=$value ;; --poll) POLL=$value ;;
      esac
      ;;
    *) usage; exit 2 ;;
  esac
done

valid_positive_integer() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 > 0)); }
# The Sol lane resolves to GPT-6.1 Sol by default; override with CODEX_LANE_SOL_MODEL.
if [[ $MODEL == gpt-6-sol ]]; then MODEL=${CODEX_LANE_SOL_MODEL:-gpt-6.1-sol}; fi
if [[ -z $MODEL || -z $SPEC || -z $FINAL || -z $CD_DIR ]] || ! valid_positive_integer "$SOFT" || ! valid_positive_integer "$STALL" || ! valid_positive_integer "$HARD" || ! valid_positive_integer "$POLL"; then
  usage; exit 2
fi

# Cross-lane guard: concurrent lanes sharing temp paths can feed codex another lane's (or
# another session's) spec file; codex then exits 0 having worked a different task.
# The spec's first line must name this run's worktree, and the spec is snapshotted
# into the run log before launch so later writes to $SPEC cannot change what codex reads.
if [[ ! -f $SPEC ]]; then echo "codex-lane-run: spec file not found: $SPEC" >&2; exit 2; fi
if [[ ! -d $CD_DIR ]]; then echo "codex-lane-run: --cd is not a directory: $CD_DIR" >&2; exit 2; fi
CD_REAL=$(cd "$CD_DIR" && pwd -P)
spec_header=$(head -n 1 "$SPEC")
declared_dir=${spec_header#LANE-WORKTREE: }
if [[ $spec_header != "LANE-WORKTREE: "* || ! -d $declared_dir || $(cd "$declared_dir" && pwd -P) != "$CD_REAL" ]]; then
  echo "codex-lane-run: refusing to run: the spec's first line must be 'LANE-WORKTREE: $CD_REAL' (got: '${spec_header:0:200}'). The spec file may belong to another lane." >&2
  exit 64
fi

# latest.* symlinks are a human convenience only; lanes poll their own exact --log path.
worktree=$(basename "$CD_DIR")
worktree=$(printf '%s' "$worktree" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
DEFAULT_DIR="$HOME/.claude/codex-lanes/$worktree"
mkdir -p "$DEFAULT_DIR"
if (( ! LOG_SET )); then
  model_short=${MODEL#gpt-6-}
  model_short=$(printf '%s' "$model_short" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  LOG="$DEFAULT_DIR/$model_short-$(date -u +%Y%m%dT%H%M%S)-$$.jsonl"
fi

# shellcheck disable=SC2317,SC2329
child_pid=''; pgid=''; exit_code=0
# shellcheck disable=SC2317,SC2329
cleanup() {
  local status=$? waited=0
  if [[ -n ${pgid:-} ]] && pgrep -g "$pgid" >/dev/null 2>&1; then
    kill -INT -- -"$pgid" 2>/dev/null || true
    while ((waited < 5)) && pgrep -g "$pgid" >/dev/null 2>&1; do sleep 1; waited=$((waited + 1)); done
    if pgrep -g "$pgid" >/dev/null 2>&1; then
      kill -TERM -- -"$pgid" 2>/dev/null || true
      waited=0
      while ((waited < 3)) && pgrep -g "$pgid" >/dev/null 2>&1; do sleep 1; waited=$((waited + 1)); done
    fi
    if pgrep -g "$pgid" >/dev/null 2>&1; then kill -KILL -- -"$pgid" 2>/dev/null || true; fi
  fi
  if ((exit_code == 0 && status != 0)); then exit_code=$status; fi
  if [[ -n ${LOG:-} ]]; then printf '%s\n' "$exit_code" > "$LOG.exit" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit_code=130; exit 130' INT
trap 'exit_code=143; exit 143' TERM

file_size() {
  local size
  size=$(stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0)
  printf '%s' "$size"
}
process_alive() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$1" 2>/dev/null || true)
  [[ $state != Z* ]]
}
is_git=0
if [[ $(git -C "$CD_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true) == true ]]; then is_git=1; fi
git_status() {
  if ((is_git)); then git -C "$CD_DIR" status --porcelain 2>/dev/null || true
  else printf '%s\n' '(not a git work tree)'; fi
}
git_summary() {
  local status=$1 count listing
  if ((is_git)); then
    count=$(printf '%s\n' "$status" | awk 'NF { n++ } END { print n+0 }')
    listing=$(printf '%s\n' "$status" | sed -n '1,20p')
  else count=0; listing='(not a git work tree)'; fi
  printf 'Changed entries: %s\n%s' "$count" "$listing"
}
cpu_seconds() {
  local line total=0 h m s rest
  while IFS= read -r line; do
    line=${line//[[:space:]]/}
    [[ -n $line ]] || continue
    IFS=: read -r -a parts <<< "$line"
    case ${#parts[@]} in
      2) m=${parts[0]} s=${parts[1]%%.*}; total=$((total + 10#$m * 60 + 10#$s)) ;;
      3) h=${parts[0]} m=${parts[1]} s=${parts[2]%%.*}; total=$((total + 10#$h * 3600 + 10#$m * 60 + 10#$s)) ;;
    esac
  done < <(ps -o time= -g "$pgid" 2>/dev/null || true)
  printf '%s' "$total"
}
group_has_descendants() {
  local pids pid
  pids=$(pgrep -g "$pgid" 2>/dev/null || true)
  while IFS= read -r pid; do [[ -n $pid && $pid != "$child_pid" ]] && return 0; done <<< "$pids"
  return 1
}
last_message() {
  local message
  message=
  if command -v jq >/dev/null 2>&1 && [[ -f $LOG ]]; then
    message=$(tail -n 50 "$LOG" 2>/dev/null | jq -r 'select(.type=="item.completed") | .item | (.text // .command // empty)' 2>/dev/null | awk 'NF { last=$0 } END { print last }' || true)
  fi
  if [[ -z $message && -f $LOG ]]; then
    message=$(tail -n 50 "$LOG" 2>/dev/null | grep -Eo '"text"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/^[^:]*:[[:space:]]*"//; s/"$//' | tail -n 1 || true)
    if [[ -z $message ]]; then message=$(tail -n 50 "$LOG" 2>/dev/null | grep -Eo '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/^[^:]*:[[:space:]]*"//; s/"$//' | tail -n 1 || true); fi
  fi
  [[ -n $message ]] || message='(no message recovered)'
  printf '%s' "$message"
}
write_status() {
  local destination=$1 elapsed=$2 size=$3 since=$4 alive=$5 git_info=$6 message=$7 cpu=$8
  {
    printf 'Timestamp: %s\nElapsed seconds: %s\nCodex alive: %s\nLog size bytes: %s\nSeconds since progress: %s\nCodex process-group CPU seconds: %s\nGit status --porcelain:\n%s\nMost recent agent message or command:\n%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$elapsed" "$alive" "$size" "$since" "$cpu" "$git_info" "$message"
  } > "$destination"
}
mkdir -p "$(dirname "$FINAL")" "$(dirname "$LOG")"
cp "$SPEC" "$LOG.spec"
: > "$FINAL"
echo "codex-lane-run: log=$LOG (wait on $LOG.exit, not latest.jsonl.exit)" >&2
if [[ -n $DEFAULT_DIR ]]; then
  ln -sfn "$LOG" "$DEFAULT_DIR/latest.jsonl"
  ln -sfn "$LOG.progress.latest" "$DEFAULT_DIR/latest.jsonl.progress.latest"
  ln -sfn "$LOG.progress" "$DEFAULT_DIR/latest.jsonl.progress"
  ln -sfn "$LOG.exit" "$DEFAULT_DIR/latest.jsonl.exit"
fi
codex_args=(exec --model "$MODEL")
if ((EFFORT_SET)); then codex_args+=(-c "model_reasoning_effort=$EFFORT"); fi
if [[ -n ${CODEX_LANE_SERVICE_TIER:-} ]]; then codex_args+=(-c "service_tier=$CODEX_LANE_SERVICE_TIER"); fi
codex_args+=(--sandbox workspace-write --skip-git-repo-check --cd "$CD_DIR" --json --output-last-message "$FINAL" -)
printf "%s\n" "${codex_args[*]}" > "$LOG.args"
perl -e 'setpgrp(0, 0) or die "setpgrp: $!"; $SIG{INT} = "DEFAULT"; exec @ARGV or die "exec codex: $!"' codex "${codex_args[@]}" < "$LOG.spec" > "$LOG" 2>"$LOG.stderr" &
child_pid=$!
pgid=$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)
[[ -n $pgid ]] || pgid=$child_pid
start=$(date +%s); last_progress=$start
last_log_size=$(file_size "$LOG"); last_git=$(git_status); last_cpu=$(cpu_seconds)
last_checkpoint=0 reason=
while :; do
  now=$(date +%s); elapsed=$((now - start)); size=$(file_size "$LOG")
  current_git=$(git_status); current_cpu=$(cpu_seconds)
  if [[ $size != "$last_log_size" || $current_git != "$last_git" || $current_cpu -gt $last_cpu ]] || group_has_descendants; then
    last_progress=$now; last_log_size=$size; last_git=$current_git
  fi
  ((current_cpu > last_cpu)) && last_cpu=$current_cpu
  since=$((now - last_progress)); git_info=$(git_summary "$current_git")
  if process_alive "$child_pid"; then alive=yes; else alive=no; fi
  message=$(last_message)
  write_status "$LOG.progress.latest" "$elapsed" "$size" "$since" "$alive" "$git_info" "$message" "$current_cpu"
  checkpoint=$((elapsed / SOFT))
  while ((checkpoint > last_checkpoint)); do
    {
      printf 'Timestamp: %s\nElapsed seconds: %s\nCodex alive: %s\nLog size bytes: %s\nSeconds since progress: %s\nCodex process-group CPU seconds: %s\nGit status --porcelain:\n%s\nMost recent agent message or command:\n%s\n\n---\n\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$elapsed" "$alive" "$size" "$since" "$current_cpu" "$git_info" "$message"
    } >> "$LOG.progress"
    last_checkpoint=$((last_checkpoint + 1))
  done
  if [[ $alive == no ]]; then
    if wait "$child_pid"; then exit_code=0; else exit_code=$?; fi
    child_pid=; reason="normal exit code $exit_code"; break
  fi
  if ((since >= STALL)); then reason=stalled; exit_code=125; break; fi
  if ((elapsed >= HARD)); then reason='hard cap'; exit_code=124; break; fi
  sleep "$POLL"
done

if [[ $reason == stalled || $reason == 'hard cap' ]]; then
  kill -INT -- -"$pgid" 2>/dev/null || true
  waited=0
  while ((waited < 60)) && pgrep -g "$pgid" >/dev/null 2>&1; do sleep 1; waited=$((waited + 1)); done
  if pgrep -g "$pgid" >/dev/null 2>&1; then
    kill -TERM -- -"$pgid" 2>/dev/null || true; waited=0
    while ((waited < 10)) && pgrep -g "$pgid" >/dev/null 2>&1; do sleep 1; waited=$((waited + 1)); done
  fi
  if pgrep -g "$pgid" >/dev/null 2>&1; then kill -KILL -- -"$pgid" 2>/dev/null || true; fi
  wait "$child_pid" 2>/dev/null || true; child_pid=
fi
if [[ ! -s $FINAL ]]; then
  {
    printf 'codex stopped (%s) after %ss\n\n%s\n' "$reason" "$(( $(date +%s) - start ))" "$(last_message)"
    if [[ -s $LOG.stderr ]]; then printf '\nLast stderr:\n'; tail -n 20 "$LOG.stderr"; fi
  } > "$FINAL"
fi
cp "$FINAL" "$LOG.final" 2>/dev/null || true
printf '%s\n' "$exit_code" > "$LOG.exit"
trap - EXIT
exit "$exit_code"
