#!/usr/bin/env bash
# Lane admission with load attribution: may a new lane start on this host now, and what is the
# load made of? Reads the 1-minute load, the CPU count and free memory, then the top processes by
# CPU and by RSS, each tied to the worktree it runs in. Read-only: it never kills or renices.
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
#   cause    indexing|lanes|other|-  <what leads, with CPU %>
#   hint     <what to do about it>
#   top-cpu|top-rss  <pid>  <cpu%>  <rss MB>  <command>  <worktree name or ->
# "indexing" is fseventsd / Spotlight (mds, mds_stores, mdworker) leading the CPU table: the cure
# is fewer worktrees (wt-cleanup.sh) and an owner action, not waiting.
# Free memory: free + inactive + speculative pages (vm_stat), else MemAvailable (/proc/meminfo).
# Env (tests): ORCHESTRATE_HOST_LOAD1, ORCHESTRATE_HOST_CPUS, ORCHESTRATE_HOST_FREE_MB override
# the readings; ps and lsof are found on PATH.
# Exit: 0 ADMIT | 3 HOLD (load or memory below --min-free-gb) | 4 BACKOFF (memory) | 2 usage
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_slots.sh
source "$here/_slots.sh"

root=${ORCHESTRATE_WORKTREE_ROOT:-} top=5 factor=1.5 min_gb=8 backoff_gb=4 third_gb=12
num() { [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "host-load.sh: bad $1: $2" >&2; exit 2; }; }
while (($#)); do
  case "$1" in
    --worktree-root) root=$2; shift 2 ;;
    --top) top=$2; shift 2 ;;
    --load-factor) num "$1" "$2"; factor=$2; shift 2 ;;
    --min-free-gb) num "$1" "$2"; min_gb=$2; shift 2 ;;
    --backoff-gb) num "$1" "$2"; backoff_gb=$2; shift 2 ;;
    --third-slot-gb) num "$1" "$2"; third_gb=$2; shift 2 ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "host-load.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$top" =~ ^[0-9]+$ ]] || { echo "host-load.sh: bad --top: $top" >&2; exit 2; }
if [[ -z "$root" ]] && common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  [[ ! -d "$common/../.claude/worktrees" ]] || root=$(cd "$common/../.claude/worktrees" && pwd -P)
fi
[[ -z "$root" || ! -d "$root" ]] || root=$(cd "$root" && pwd -P)

# --- readings -----------------------------------------------------------------------------------
cpus=${ORCHESTRATE_HOST_CPUS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)}
load1=${ORCHESTRATE_HOST_LOAD1:-}
if [[ -z "$load1" ]]; then
  if [[ -r /proc/loadavg ]]; then
    load1=$(awk '{ print $1 }' /proc/loadavg)
  else
    load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{ print $1 }' || true)
    [[ -n "$load1" ]] || load1=$(uptime | sed 's/.*load average[s]*: *//' | awk -F'[ ,]+' '{ print $1 }')
  fi
fi
free_mb=${ORCHESTRATE_HOST_FREE_MB:-}
if [[ -z "$free_mb" ]]; then
  if command -v vm_stat >/dev/null 2>&1; then
    free_mb=$(vm_stat | awk '
      /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
      /^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); n += $NF }
      END { if (ps) printf "%d", n * ps / 1048576 }')
  elif [[ -r /proc/meminfo ]]; then
    free_mb=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
  fi
fi
[[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=""

# --- verdict ------------------------------------------------------------------------------------
limit=$(awk -v f="$factor" -v c="$cpus" 'BEGIN { printf "%.2f", f * c }')
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }
free_gb=unknown slots=2
[[ -z "$free_mb" ]] || free_gb=$(awk -v m="$free_mb" 'BEGIN { printf "%.1f", m / 1024 }')
if [[ -n "$free_mb" ]] && lt "$free_gb" "$backoff_gb"; then
  verdict=BACKOFF rc=4 reason="free memory ${free_gb} GB < ${backoff_gb} GB: start nothing, let lanes finish"
elif ! lt "$load1" "$limit"; then
  verdict=HOLD rc=3 reason="1-min load $load1 >= $limit ($factor x $cpus CPUs)"
elif [[ -n "$free_mb" ]] && lt "$free_gb" "$min_gb"; then
  verdict=HOLD rc=3 reason="free memory ${free_gb} GB < ${min_gb} GB"
else
  verdict=ADMIT rc=0 reason="load $load1 < $limit, free ${free_gb} GB"
fi
[[ -z "$free_mb" ]] || lt "$free_gb" "$third_gb" || slots=3
printf 'verdict\t%s\t%s\n' "$verdict" "$reason"
printf 'load\t%s\t%s CPUs, limit %s\n' "$load1" "$cpus" "$limit"
printf 'memory\t%s\tmin %s, backoff %s\n' "$free_gb" "$min_gb" "$backoff_gb"
printf 'device-slots\t%s\n' "$slots"
((top > 0)) || exit "$rc"

# --- attribution --------------------------------------------------------------------------------
# pid <TAB> cpu <TAB> rss KB <TAB> command basename, from one ps call (reads to the end).
procs=$(ps -A -o pid= -o pcpu= -o rss= -o comm= 2>/dev/null | awk '
  $1 ~ /^[0-9]+$/ { c = $4; for (i = 5; i <= NF; i++) c = c " " $i; n = split(c, p, "/"); print $1 "\t" $2 "\t" $3 "\t" p[n] }' || true)
cwdmap=$(proc_cwds 2>/dev/null || true)
table() { # KIND SORT-COLUMN
  printf '%s\n' "$procs" | sort -t "$(printf '\t')" -k "$2,$2" -rn | awk -F'\t' -v n="$top" 'NF >= 4 && NR <= n' |
    while IFS=$'\t' read -r pid cpu rss cmd; do
      wt=$(printf '%s\n' "$cwdmap" | awk -F'\t' -v p="$pid" -v r="$root" '
        $1 == p && r != "" && index($2, r "/") == 1 { s = substr($2, length(r) + 2); sub("/.*", "", s); print s; exit }')
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$pid" "$cpu" "$((rss / 1024))" "$cmd" "${wt:--}"
    done
}
cpu_rows=$(table top-cpu 2)
rss_rows=$(table top-rss 3)

# What leads the CPU table: indexing, lane processes (cwd under the worktree root), or other.
cause=$(printf '%s\n' "$cpu_rows" | awk -F'\t' '
  NF < 6 { next }
  { k = ($5 ~ /^(fseventsd|mds|mds_stores|mdworker|mdworker_shared|mdsync|corespotlightd)$/) ? "indexing" : ($6 != "-" ? "lanes" : "other")
    s[k] += $3; if (!(k in who)) who[k] = $5 " " $3 "%"; else if (length(who[k]) < 80) who[k] = who[k] ", " $5 " " $3 "%" }
  END { b = "-"; for (k in s) if (b == "-" || s[k] > s[b]) b = k; print b "\t" (b == "-" ? "no processes read" : who[b]) }')
case "${cause%%$'\t'*}" in
  indexing) hint="system indexing leads: remove finished worktrees (wt-cleanup.sh --apply), then ask the owner to exclude ${root:-the worktree root} from Spotlight (System Settings > Spotlight > Search Privacy) or plan a reboot; fseventsd keeps its memory until a restart" ;;
  lanes) hint="lane processes lead: start no lane; check gate-slot.sh is used and that finished lanes stopped the PIDs they started" ;;
  other) hint="a process outside the lanes leads: tell the owner what it is; do not stop it yourself" ;;
  *) hint="no process table: check with uptime and top by hand" ;;
esac
printf 'cause\t%s\n' "$cause"
printf 'hint\t%s\n' "$hint"
[[ -z "$cpu_rows" ]] || printf '%s\n' "$cpu_rows"
[[ -z "$rss_rows" ]] || printf '%s\n' "$rss_rows"
exit "$rc"
