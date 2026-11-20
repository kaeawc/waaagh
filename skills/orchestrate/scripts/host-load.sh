#!/usr/bin/env bash
# Lane admission with load attribution: may a new lane start on this host now, and what is the
# load made of? The readings and the attribution come from spectra (`spectra load --json`, #330):
# the 1-minute load, the CPU count, available memory, what leads the CPU table (a worktree under
# the root, Spotlight indexing, or something else) and the top processes and process families.
# The admission rules are waaagh's and stay here. Read-only: it never kills or renices.
#
# Usage: host-load.sh [--worktree-root DIR] [--top N] [--load-factor F] [--min-free-gb G]
#                     [--backoff-gb G] [--third-slot-gb G]
#   --worktree-root  where lane worktrees live (default $ORCHESTRATE_WORKTREE_ROOT, else
#                    <main checkout>/.claude/worktrees when run inside a git checkout)
#   --top            processes listed per table (default 5; 0 lists none and skips attribution)
#   admit only when the 1-min load is below F x CPUs (default 1.5) and free memory is at least
#   --min-free-gb (default 8); below --backoff-gb (default 4) lanes should back off. A third device
#   slot per platform is allowed only at --third-slot-gb free (default 12).
# Output (TSV), first row the verdict:
#   verdict  ADMIT|HOLD|BACKOFF  <reason>
#   load     <1-min>  <cpus> CPUs, limit <F x CPUs>
#   memory   <free GB>|unknown  min <G>, backoff <G>
#   device-slots  2|3
#   cause    indexing|lanes|other|idle|<spectra's kind>  <what leads, from spectra>
#   hint     <what to do about it>
#   top-cpu|top-rss  <pid>  <cpu%>  <rss MB>  <command>  <worktree name or ->
#   family   <name>  <kind>  <members>  <cpu%>  <rss MB>   (process families: xcode, simulator, ...)
# "indexing" is fseventsd / Spotlight (mds, mds_stores, mdworker) leading the CPU table: the cure
# is fewer worktrees (wt-cleanup.sh) and an owner action, not waiting. "lanes" is a worktree under
# the root leading it (spectra's cause "roots").
# Free memory is spectra's available memory; unknown when it could not be read (no memory hold).
# Requires spectra (load); without it, exit 5 and one line naming what is missing (_lib.sh).
# Exit: 0 ADMIT | 3 HOLD (load or memory below --min-free-gb) | 4 BACKOFF (memory) | 2 usage
#   | 5 spectra missing, or its load reading failed
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"

root="" top=5 factor=1.5 min_gb=8 backoff_gb=4 third_gb=12
num() { [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "host-load.sh: bad $1: $2" >&2; exit 2; }; }
while (($#)); do
  case "$1" in
    --worktree-root) root=$2; shift 2 ;;
    --top) top=$2; shift 2 ;;
    --load-factor) num "$1" "$2"; factor=$2; shift 2 ;;
    --min-free-gb) num "$1" "$2"; min_gb=$2; shift 2 ;;
    --backoff-gb) num "$1" "$2"; backoff_gb=$2; shift 2 ;;
    --third-slot-gb) num "$1" "$2"; third_gb=$2; shift 2 ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "host-load.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$top" =~ ^[0-9]+$ ]] || { echo "host-load.sh: bad --top: $top" >&2; exit 2; }
if [[ -z "$root" ]]; then root=$(orch_worktree_root) || root=""
elif [[ -d "$root" ]]; then root=$(cd "$root" && pwd -P); fi

# --- readings (spectra) -------------------------------------------------------------------------
orch_spectra_require load || exit 5
args=(load --json --top "$((top > 0 ? top : 1))" --max-load-per-cpu "$factor" --min-free-gb "$min_gb" --backoff-free-gb "$backoff_gb")
[[ -z "$root" ]] || args+=(--root "$root")
# spectra exits 3 or 4 with its own verdict; its JSON is what counts here.
raw=$(orch_spectra "${args[@]}" 2>/dev/null) || true
if ! read -r load1 cpus free_gb < <(jq -er 'if (.load1 | type) == "number" and (.cpus | type) == "number" then
    [.load1, (.cpus | floor), (if (.available_gb | type) == "number" then .available_gb else "unknown" end)] | @tsv
    else error("not a load reading") end' \
    <<<"$raw" 2>/dev/null) || ((cpus < 1)); then
  echo "host-load.sh: spectra load gave no reading: ${raw:0:200}" >&2
  exit 5
fi
[[ "$free_gb" == unknown ]] || free_gb=$(awk -v g="$free_gb" 'BEGIN { printf "%.1f", int(g * 10) / 10 }')

# --- verdict (waaagh's rules) -------------------------------------------------------------------
limit=$(awk -v f="$factor" -v c="$cpus" 'BEGIN { printf "%.2f", f * c }')
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }
slots=2
if [[ "$free_gb" != unknown ]] && lt "$free_gb" "$backoff_gb"; then
  verdict=BACKOFF rc=4 reason="free memory ${free_gb} GB < ${backoff_gb} GB: start nothing, let lanes finish"
elif ! lt "$load1" "$limit"; then
  verdict=HOLD rc=3 reason="1-min load $load1 >= $limit ($factor x $cpus CPUs)"
elif [[ "$free_gb" != unknown ]] && lt "$free_gb" "$min_gb"; then
  verdict=HOLD rc=3 reason="free memory ${free_gb} GB < ${min_gb} GB"
else
  verdict=ADMIT rc=0 reason="load $load1 < $limit, free ${free_gb} GB"
fi
[[ "$free_gb" == unknown ]] || lt "$free_gb" "$third_gb" || slots=3
printf 'verdict\t%s\t%s\n' "$verdict" "$reason"
printf 'load\t%s\t%s CPUs, limit %s\n' "$load1" "$cpus" "$limit"
printf 'memory\t%s\tmin %s, backoff %s\n' "$free_gb" "$min_gb" "$backoff_gb"
printf 'device-slots\t%s\n' "$slots"
((top > 0)) || exit "$rc"

# --- attribution (spectra) ----------------------------------------------------------------------
# A process's worktree: the first path component of its directory below the root, else "-".
rows=$(jq -r --arg root "$root" --argjson n "$top" '
  def wt: (.dir // .cwd // "") as $d
    | if $root != "" and ($d | startswith($root + "/")) then ($d[($root | length) + 1:] | split("/")[0]) else "-" end;
  def row($k): "\($k)\t\(.pid)\t\(.cpu_pct * 10 | round / 10)\t\((.rss_kib // 0) / 1024 | floor)\t\(.command)\t\(wt)";
  (.cause // {}) as $c
  | ($c.kind // "none") as $k
  | "cause\t\(if $k == "roots" then "lanes" elif $k == "none" then "idle" else $k end)\t\($c.detail // "-")",
    "root-worktree\t\($c.worktree // "")",
    ((.top_cpu // [])[:$n][] | row("top-cpu")),
    ((.top_rss // [])[:$n][] | row("top-rss")),
    ((.families // [])[:$n][] | "family\t\(.name)\t\(.kind)\t\(.members)\t\(.cpu_pct * 10 | round / 10)\t\((.rss_kib // 0) / 1024 | floor)")' <<<"$raw")
cause_line=$(sed -n 1p <<<"$rows")
kind=$(cut -f2 <<<"$cause_line")
lead=$(sed -n 2p <<<"$rows" | cut -f2)
case "$kind" in
  indexing) hint="system indexing leads: remove finished worktrees (wt-cleanup.sh --apply), then ask the owner to exclude ${root:-the worktree root} from Spotlight (System Settings > Spotlight > Search Privacy) or plan a reboot; fseventsd keeps its memory until a restart" ;;
  lanes) hint="lane processes lead${lead:+ (worktree $lead)}: start no lane; check gate-slot.sh is used and that finished lanes stopped the PIDs they started" ;;
  ci-runner) hint="a CI runner on this host leads: lower the lane cap for its duration; do not look for a runaway lane" ;;
  idle) hint="nothing leads the CPU table: the load is falling or brief" ;;
  *) hint="a process outside the lanes leads: tell the owner what it is; do not stop it yourself" ;;
esac
printf '%s\n' "$cause_line"
printf 'hint\t%s\n' "$hint"
sed -n '3,$p' <<<"$rows" | grep -v '^$' || true
exit "$rc"
