#!/usr/bin/env bash
# Campaign state cleanup (#418): rebuildable output and raw captures left in old campaign state.
# Nothing expires campaign state, so evidence directories keep whole checkouts, app builds and raw
# audio long after the PRs they proved merged (one campaign reached 67 GB). This finds, below the
# campaign's subdirectories, only what can be rebuilt or compressed, and leaves evidence alone.
# A dry run unless --apply.
#
# Usage: campaign-gc.sh [--repo OWNER/REPO | --state-dir DIR] [--older-than DAYS] [--top N] [--apply]
#   --state-dir   the campaign directory (default <state root>/<owner>__<repo> of --repo)
#   --older-than  skip a candidate with anything in it newer than DAYS days (default 14)
#   --top         list the N largest candidates (default 20; 0 for none)
#   --apply       remove build output, binaries and temp files; gzip raw captures in place
# Candidates, below each top-level subdirectory of the campaign:
#   build    directories DerivedData and derived-data; node_modules, build, .gradle, target,
#            .build, .kotlin and Pods only beside a build definition (package.json, build.gradle*,
#            settings.gradle*, gradlew, Cargo.toml, Package.swift, Podfile, pom.xml, go.mod,
#            CMakeLists.txt, Makefile, *.xcodeproj, *.xcworkspace)
#   binary   *.apk, *.aab, *.ipa files; *.app, *.xcarchive bundles
#   temp     *.tmp files
#   capture  *.pcm, *.hprof files (gzipped, not removed: they are evidence)
# Never touched: files at the campaign's top level (ledgers), the learnings, briefs, bin, ops,
# locks, diagnostics, snapshots and loops directories, a candidate with anything in it newer than
# --older-than (checked again right before each action), every top-level entry a process works in
# (spectra owner --under), anything inside .git or .jj, a top-level entry itself, and a path with
# a tab or newline in it (counted as odd-names). Symbolic links are not followed.
# Output (TSV): one line per category, `<category> <count> <size>`, then the largest candidates,
# `<size> <category> <path below the campaign>`, then one summary line:
#   mode=dry-run|apply entries=<n> busy=<n> recent=<n> [odd-names=<n>] remove=<size> compress=<size>
#   [freed=<size>]
#   (entries: top-level entries searched; busy: entries skipped; recent: candidates skipped)
# Every --apply action is appended to <campaign>/campaign-gc.log.
# Env: ORCHESTRATE_NOW (clock, tests).
# Exit: 0 | 2 usage | 5 --apply refused: who works in the campaign could not be told (spectra)
set -euo pipefail
# This script's directory with no subshell or dirname process: every script start pays for it (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
# shellcheck source=_lib.sh
source "$here/_lib.sh"

repo="" dir="" days=14 top=20 apply=no
while (($#)); do
  case "$1" in
    --repo) repo=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --state-dir) dir=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --older-than) days=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --top) top=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
    --apply) apply=yes; shift ;;
    -h | --help) orch_usage; exit 0 ;;
    *) echo "campaign-gc.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$days" =~ ^[0-9]+$ ]] || { echo "campaign-gc.sh: --older-than needs a number of days" >&2; exit 2; }
[[ "$top" =~ ^[0-9]+$ ]] || { echo "campaign-gc.sh: --top needs a number" >&2; exit 2; }
if [[ -z "$dir" ]]; then
  [[ -n "$repo" ]] || { echo "campaign-gc.sh: give --repo OWNER/REPO or --state-dir DIR" >&2; exit 2; }
  dir="$(orch_state_root)/${repo//\//__}"
fi
[[ -d "$dir" ]] || { echo "campaign-gc.sh: no campaign directory $dir" >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)

work=$(mktemp -d "${TMPDIR:-/tmp}/campaign-gc.XXXXXX")
trap 'rm -rf "$work"' EXIT
# The age cutoff as a reference file: `find -newer` is the same on BSD and GNU find.
stamp=$(jq -rn --argjson t "$(($(orch_now) - days * 86400))" '$t | strftime("%Y%m%d%H%M.%S")')
TZ=UTC touch -t "$stamp" "$work/cutoff"

human() { awk -v k="$1" 'BEGIN { split("K M G T", u); i = 1; while (k >= 1024 && i < 4) { k /= 1024; i++ }
  printf (i == 1 ? "%dK" : "%.1f%s"), k, u[i] }'; }

entries=()
for e in "$dir"/*/; do
  e=${e%/}
  [[ -d "$e" && ! -L "$e" ]] || continue
  case "${e##*/}" in learnings | briefs | bin | ops | locks | diagnostics | snapshots | loops) continue ;; esac
  entries+=("$e")
done

busy=0
if ((${#entries[@]})); then
  if cwds=$(proc_cwds "${entries[@]}" | cut -f2-); then
    kept=()
    for e in "${entries[@]}"; do
      inuse=no
      while IFS= read -r c; do [[ "$c" != "$e" && "$c" != "$e/"* ]] || { inuse=yes; break; }; done <<<"$cwds"
      if [[ "$inuse" == yes ]]; then busy=$((busy + 1)); else kept+=("$e"); fi
    done
    entries=(${kept[@]+"${kept[@]}"})
  elif [[ "$apply" == yes ]]; then
    echo "campaign-gc.sh: who works in the campaign could not be told: spectra did not answer; nothing was changed" >&2
    exit 5
  else
    echo "campaign-gc.sh: spectra could not tell who works in the campaign; a busy entry may be listed" >&2
  fi
fi

# Candidates. `.git` and `.jj` are never entered; a top-level entry is never a candidate itself.
: >"$work/list" ; : >"$work/found"
for e in ${entries[@]+"${entries[@]}"}; do
  find "$e" -mindepth 1 \( -type d \( -name .git -o -name .jj \) -prune \) \
    -o \( -type d \( -name node_modules -o -name build -o -name .gradle -o -name DerivedData -o -name derived-data \
      -o -name target -o -name .build -o -name .kotlin -o -name Pods -o -name '*.app' -o -name '*.xcarchive' \) -prune -print0 \) \
    -o \( -type f \( -name '*.apk' -o -name '*.aab' -o -name '*.ipa' -o -name '*.tmp' -o -name '*.pcm' -o -name '*.hprof' \) -print0 \) \
    2>/dev/null >>"$work/found" || true
done
# has_build_file DIR: DIR holds a build definition, so a generic name below it (build, target,
# node_modules, ...) is that build's output and not, say, a source package named `build`.
has_build_file() {
  local f
  for f in package.json build.gradle build.gradle.kts settings.gradle settings.gradle.kts gradlew Cargo.toml \
    Package.swift Podfile pom.xml go.mod CMakeLists.txt Makefile; do
    [[ ! -e "$1/$f" ]] || return 0
  done
  for f in "$1"/*.xcodeproj "$1"/*.xcworkspace; do [[ ! -e "$f" ]] || return 0; done
  return 1
}
# Kept as candidates: paths with no tab or newline (the size listing below is one line per path),
# generic build directory names only beside a build definition, and nothing newer than the cutoff
# (in use or still wanted).
recent=0 odd=0
: >"$work/old"
if [[ -s "$work/found" ]]; then
  while IFS= read -r -d '' p; do
    case "$p" in *$'\t'* | *$'\n'*) odd=$((odd + 1)); continue ;; esac
    case "${p##*/}" in
      node_modules | build | .gradle | target | .build | .kotlin | Pods) has_build_file "${p%/*}" || continue ;;
    esac
    if [[ -n "$(find "$p" -newer "$work/cutoff" -print -quit 2>/dev/null)" ]]; then recent=$((recent + 1))
    else printf '%s\0' "$p" >>"$work/old"; fi
  done <"$work/found"
fi
[[ ! -s "$work/old" ]] || xargs -0 du -sk <"$work/old" 2>/dev/null >"$work/list" || true

# Category of each candidate: "<kb>\t<category>\t<path>".
awk -F'\t' '{ p = $2; c = "build"
  if (p ~ /\.(app|xcarchive|apk|aab|ipa)$/) c = "binary"; else if (p ~ /\.tmp$/) c = "temp"
  else if (p ~ /\.(pcm|hprof)$/) c = "capture"
  printf "%s\t%s\t%s\n", $1, c, p }' "$work/list" >"$work/cands"

for c in build binary temp capture; do
  read -r n kb <<<"$(awk -F'\t' -v c="$c" '$2 == c { n++; s += $1 } END { print n + 0, s + 0 }' "$work/cands")"
  printf '%s\t%s\t%s\n' "$c" "$n" "$(human "$kb")"
done
if ((top > 0)); then
  sort -t$'\t' -k1,1nr "$work/cands" >"$work/sorted"
  head -n "$top" "$work/sorted" | while IFS=$'\t' read -r kb c p; do
    printf '%s\t%s\t%s\n' "$(human "$kb")" "$c" "${p#"$dir"/}"
  done
fi
remove=$(awk -F'\t' '$2 != "capture" { s += $1 } END { print s + 0 }' "$work/cands")
compress=$(awk -F'\t' '$2 == "capture" { s += $1 } END { print s + 0 }' "$work/cands")
summary="mode=$([[ "$apply" == yes ]] && echo apply || echo dry-run) entries=${#entries[@]} busy=$busy recent=$recent"
((odd == 0)) || summary+=" odd-names=$odd"
summary+=" remove=$(human "$remove") compress=$(human "$compress")"

if [[ "$apply" == yes ]]; then
  before=$(du -sk "$dir" | cut -f1)
  log="$dir/campaign-gc.log"
  while IFS=$'\t' read -r kb c p; do
    [[ -e "$p" && ! -L "$p" ]] || continue
    # Listing and sizing can take minutes: anything written in it since is left alone.
    if [[ -n "$(find "$p" -newer "$work/cutoff" -print -quit 2>/dev/null)" ]]; then
      printf '%s\tskipped (changed)\t%s\t%sK\t%s\n' "$(orch_iso "$(orch_now)")" "$c" "$kb" "${p#"$dir"/}" >>"$log"; continue
    fi
    case "$c" in
      capture) if gzip -9n -- "$p"; then act=gzip; else act="gzip failed"; fi ;;
      *) if rm -rf -- "$p"; then act=removed; else act="remove failed"; fi ;;
    esac
    printf '%s\t%s\t%s\t%sK\t%s\n' "$(orch_iso "$(orch_now)")" "$act" "$c" "$kb" "${p#"$dir"/}" >>"$log"
  done <"$work/cands"
  after=$(du -sk "$dir" | cut -f1)
  summary+=" freed=$(human $((before > after ? before - after : 0)))"
fi
echo "$summary"
