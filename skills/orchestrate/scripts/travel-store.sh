#!/usr/bin/env bash
# The traveling-mode state store (traveling-mode.md, #263): a private git repository, one folder
# per target repository (<owner>__<repo>/), holding MODE, LEASE and journal.tsv next to that
# repository's usual state files. One writer at a time: a lease, and pushes that must fast-forward.
# Nothing here ever force-pushes or rewrites the store's history.
#
# Usage: travel-store.sh <command> --store DIR --repo OWNER/REPO [options]
#   mode                     print `local` or `traveling` (no MODE file: local)
#   set-mode local|traveling write MODE, journal it, commit and push (the host's toggle only)
#   lease show               print the LEASE line (no LEASE file: `holder=none expires=0 since=-`)
#   lease take --holder H [--ttl SECONDS]
#                            take the lease when it is free (holder=none), expired, or already H's:
#                            write `holder=H expires=<now+ttl> since=<iso>` (ttl default 5400),
#                            journal it, commit and push. Exit 4 when another holder's lease is
#                            unexpired; exit 3 when the push is rejected (another writer pushed
#                            first: the local commit is dropped and nothing was taken)
#   lease renew --holder H [--ttl SECONDS]   extend H's own lease (exit 4 if H does not hold it)
#   lease release --holder H                 write holder=none if H holds it, journal, push
#   journal --actor A --action X [--detail TEXT] [--push]
#                            append `iso<TAB>A<TAB>X<TAB>TEXT` to journal.tsv and commit (and push)
#   push                     commit any pending change under the repository's folder and push
#   scan [DIR]               look for anything that resembles a credential under DIR (default the
#                            repository's folder); print each hit as `path:line: <kind>`, exit 3 on any
# Every command first fast-forwards the checkout from its remote (`git pull --ff-only`); a checkout
# that cannot fast-forward is exit 3. --store defaults to $ORCHESTRATE_STATE_DIR; the remote is
# origin, the branch the checkout's current one. Times: ORCHESTRATE_NOW (tests), else the clock.
# Exit: 0 | 3 the store could not be synced, the push was rejected, or scan found a secret |
#   4 the lease is held by another holder (take) or not by this one (renew, release) | 2 usage
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"

usage() { orch_usage >&2; exit 2; }
cmd=${1:-}; [[ -n "$cmd" ]] || usage
case "$cmd" in -h | --help) orch_usage; exit 0 ;; esac
shift
sub=""
if [[ "$cmd" == lease ]]; then sub=${1:-}; shift || true; fi
store=${ORCHESTRATE_STATE_DIR:-} repo="" holder="" ttl=5400 actor="" action="" detail="" push=no mode_arg="" scan_dir=""
case "$cmd" in set-mode) mode_arg=${1:-}; shift || true ;; scan) [[ "${1:-}" == -* || -z "${1:-}" ]] || { scan_dir=$1; shift; } ;; esac
while (($#)); do
  case "$1" in
    --store) store=${2:-}; shift 2 ;;
    --repo) repo=${2:-}; shift 2 ;;
    --holder) holder=${2:-}; shift 2 ;;
    --ttl) ttl=${2:-}; shift 2 ;;
    --actor) actor=${2:-}; shift 2 ;;
    --action) action=${2:-}; shift 2 ;;
    --detail) detail=${2:-}; shift 2 ;;
    --push) push=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "travel-store.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$cmd" in mode | set-mode | lease | journal | push | scan) ;; *) usage ;; esac
[[ "$cmd" != lease ]] || case "$sub" in show | take | renew | release) ;; *) usage ;; esac
[[ "$cmd" != set-mode ]] || case "$mode_arg" in local | traveling) ;; *) echo "travel-store.sh: set-mode needs local or traveling" >&2; exit 2 ;; esac
[[ "$ttl" =~ ^[1-9][0-9]*$ ]] || { echo "travel-store.sh: bad --ttl: $ttl" >&2; exit 2; }
[[ "$repo" == */* ]] || { echo "travel-store.sh: --repo OWNER/REPO is required" >&2; exit 2; }
[[ -n "$store" && -d "$store/.git" ]] || { echo "travel-store.sh: --store must be a git checkout of the state store" >&2; exit 2; }
if [[ "$cmd" == lease && "$sub" != show && -z "$holder" ]]; then echo "travel-store.sh: lease $sub needs --holder" >&2; exit 2; fi
if [[ "$cmd" == journal && ( -z "$actor" || -z "$action" ) ]]; then echo "travel-store.sh: journal needs --actor and --action" >&2; exit 2; fi
case "$holder$actor$action$detail" in *$'\t'* | *$'\n'*) echo "travel-store.sh: tabs and newlines are not allowed in holder, actor, action or detail" >&2; exit 2 ;; esac

ns=${repo//\//__} dir="$store/$ns"
g() { git -C "$store" "$@"; }
now=$(orch_now)
iso=$(orch_iso "$now")
branch=$(g rev-parse --abbrev-ref HEAD)

sync() {
  if g remote get-url origin >/dev/null 2>&1; then
    g fetch -q origin "$branch" 2>/dev/null || { echo "travel-store.sh: cannot fetch the store" >&2; exit 3; }
    if g rev-parse -q --verify "origin/$branch" >/dev/null; then
      g merge -q --ff-only "origin/$branch" 2>/dev/null || { echo "travel-store.sh: the store checkout cannot fast-forward to origin/$branch; fix it by hand" >&2; exit 3; }
    fi
  fi
  mkdir -p "$dir"
}
# commit MSG: commit the repository's folder if it changed.
commit() { g add -A -- "$ns"; g diff --cached --quiet || g commit -q -m "$1" -- "$ns"; }
# publish: push without force. A rejected push drops this run's commits and is exit 3.
publish() {
  g remote get-url origin >/dev/null 2>&1 || return 0
  if ! g push -q origin "HEAD:$branch" 2>/dev/null; then
    g fetch -q origin "$branch" 2>/dev/null || true
    g reset -q --hard "origin/$branch" 2>/dev/null || true
    echo "travel-store.sh: push rejected: another writer pushed first; nothing was changed" >&2
    exit 3
  fi
}
journal_row() { printf '%s\t%s\t%s\t%s\n' "$iso" "$1" "$2" "$3" >>"$dir/journal.tsv"; }
read_lease() { # sets cur_holder cur_expires
  local line
  line=$(cat "$dir/LEASE" 2>/dev/null || true)
  cur_holder=$(sed -nE 's/.*holder=([^ ]*).*/\1/p' <<<"$line")
  cur_expires=$(sed -nE 's/.*expires=([0-9]+).*/\1/p' <<<"$line")
  cur_holder=${cur_holder:-none} cur_expires=${cur_expires:-0}
}
write_lease() { printf 'holder=%s expires=%s since=%s\n' "$1" "$2" "$iso" >"$dir/LEASE"; }

if [[ "$cmd" == scan ]]; then
  target=${scan_dir:-$dir}
  [[ -d "$target" ]] || { echo "travel-store.sh: no such directory: $target" >&2; exit 2; }
  hits=$(grep -rInE --exclude-dir=.git \
    -e 'gh[pousr]_[A-Za-z0-9]{30,}' -e 'github_pat_[A-Za-z0-9_]{30,}' -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e 'xox[abposr]-[A-Za-z0-9-]{10,}' -e 'AKIA[0-9A-Z]{16}' -e 'sk-ant-[A-Za-z0-9_-]{20,}' -e 'sk-[A-Za-z0-9]{40,}' \
    "$target" 2>/dev/null | cut -d: -f1,2 || true)
  [[ -n "$hits" ]] || { echo "clean"; exit 0; }
  sed 's/$/: looks like a credential/' <<<"$hits"
  exit 3
fi

sync
case "$cmd" in
  mode) m=$(cat "$dir/MODE" 2>/dev/null || true); [[ "$m" == traveling ]] && echo traveling || echo local ;;
  set-mode)
    echo "$mode_arg" >"$dir/MODE"
    journal_row host mode "$mode_arg"
    commit "MODE=$mode_arg for $repo"
    publish
    echo "mode $mode_arg" ;;
  journal)
    journal_row "$actor" "$action" "$detail"
    commit "journal: $actor $action"
    [[ "$push" == no ]] || publish
    echo "journaled" ;;
  push) commit "state for $repo"; publish; echo "pushed" ;;
  lease)
    read_lease
    case "$sub" in
      show) echo "holder=$cur_holder expires=$cur_expires since=$(sed -nE 's/.*since=([^ ]*).*/\1/p' "$dir/LEASE" 2>/dev/null || echo -)" ;;
      take)
        if [[ "$cur_holder" != none && "$cur_holder" != "$holder" ]] && ((cur_expires > now)); then
          echo "held by $cur_holder until $(orch_iso "$cur_expires")" >&2; exit 4
        fi
        write_lease "$holder" $((now + ttl))
        journal_row "$holder" lease-take "from=$cur_holder expired=$((cur_expires <= now ? 1 : 0))"
        commit "lease: $holder takes $repo"
        publish
        echo "taken by $holder until $(orch_iso $((now + ttl)))" ;;
      renew)
        [[ "$cur_holder" == "$holder" ]] || { echo "not held by $holder (holder=$cur_holder)" >&2; exit 4; }
        write_lease "$holder" $((now + ttl))
        commit "lease: $holder renews $repo"
        publish
        echo "renewed by $holder until $(orch_iso $((now + ttl)))" ;;
      release)
        [[ "$cur_holder" == "$holder" ]] || { echo "not held by $holder (holder=$cur_holder)" >&2; exit 4; }
        write_lease none 0
        journal_row "$holder" lease-release ""
        commit "lease: $holder releases $repo"
        publish
        echo "released" ;;
    esac ;;
esac
