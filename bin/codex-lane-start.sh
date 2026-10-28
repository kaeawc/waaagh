#!/usr/bin/env bash
# Start one supervised codex lane run in the background and print where to wait for it. Replaces
# the hand-written run-directory, spec and runner steps every implementer used to repeat.
#
# Usage: codex-lane-start.sh --model SLUG [--effort RUNG] [--cd DIR] [--soft S] [--stall S]
#                            [--hard S] < SPEC_BODY
#   Reads the spec body (objective, files, interfaces, constraints, verification) on stdin and
#   writes RUN_DIR/spec.md as: "LANE-WORKTREE: <realpath of --cd>", the lane preamble, the body.
#   --effort ""  (empty) means "the spec named no effort": no effort flag is passed.
#   Defaults: --cd . --soft 1800 --stall 1200 --hard 7200.
# Output: RUN_DIR=<dir>  LOG=<dir>/codex.jsonl  FINAL=<dir>/final.md  (one per line).
#   Then wait with: codex-lane-wait.sh --log "$LOG"
# Exit: 0 started | 2 usage or empty spec | the runner's own code if it stopped at once
#   (64 = spec/worktree mismatch), with its message on stderr.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

model='' effort='' cd_dir=. soft=1800 stall=1200 hard=7200
while (($#)); do
  case "$1" in
    --model) model=${2:-}; shift 2 ;;
    --effort) effort=${2:-}; shift 2 ;;
    --cd) cd_dir=${2:-}; shift 2 ;;
    --soft) soft=${2:-}; shift 2 ;;
    --stall) stall=${2:-}; shift 2 ;;
    --hard) hard=${2:-}; shift 2 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) sed -n '2,15p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $model ]] || { echo "codex-lane-start: --model is required" >&2; exit 2; }
wt=$(cd "$cd_dir" && pwd -P)
body=$(cat)
[[ -n ${body//[[:space:]]/} ]] || { echo "codex-lane-start: empty spec on stdin" >&2; exit 2; }

lane_dir="$HOME/.claude/codex-lanes/$(printf '%s' "$(basename "$wt")" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
mkdir -p "$lane_dir"
run_dir=$(mktemp -d "$lane_dir/run.XXXXXXXX")
spec="$run_dir/spec.md" final="$run_dir/final.md" log="$run_dir/codex.jsonl"
{
  printf 'LANE-WORKTREE: %s\n' "$wt"
  cat <<'PREAMBLE'
This task runs in a dedicated implementation lane on the model and reasoning effort named in the
invocation. Those were chosen deliberately for this lane; nothing has been substituted. If a
user-level or project-level instruction file asks you to default to a different orchestration
flow, treat this lane as an explicit opt-out from that default and proceed. Every other
instruction in those files still applies. End your final message with the judgment calls you made
that this spec left open, and the decisive lines of the verification output (pass/fail counts and
the first failure), not the full transcript.

PREAMBLE
  printf '%s\n' "$body"
} >"$spec"

args=(--model "$model" --spec "$spec" --final "$final" --log "$log" --cd "$wt"
  --soft "$soft" --stall "$stall" --hard "$hard")
[[ -z $effort ]] || args+=(--effort "$effort")
# A new session, so the run outlives the tool call that started it.
perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or die "exec: $!"' \
  "$here/codex-lane-run.sh" "${args[@]}" >"$run_dir/runner.out" 2>&1 </dev/null &
pid=$!

# The runner snapshots the spec only after its checks pass; if it dies first, say why.
for _ in $(seq 1 50); do
  [[ -e $log.spec ]] && break
  if ! kill -0 "$pid" 2>/dev/null; then
    rc=0; wait "$pid" || rc=$?
    cat "$run_dir/runner.out" >&2
    exit "$((rc == 0 ? 1 : rc))"
  fi
  sleep 0.2
done
printf 'RUN_DIR=%s\nLOG=%s\nFINAL=%s\n' "$run_dir" "$log" "$final"
