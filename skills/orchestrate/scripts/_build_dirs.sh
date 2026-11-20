#!/usr/bin/env bash
# Lane-private build output (#213) for gate-slot.sh and heavy-build-slot.sh, and the sweep
# wt-cleanup.sh runs. Source, do not execute.
# Lanes on one host must not share a build output directory: a tool default under /tmp or a fixed
# home path (Xcode derived data and its module cache, Gradle's project cache, TMPDIR, XDG caches)
# lets one lane read another's half-written output, which looks like a flaky or broken build.
# Each gate therefore runs with a lane-private directory, ORCHESTRATE_LANE_BUILD_DIR, and with the
# rows of a build-dirs table pointing each tool's output into it:
#   table      ORCHESTRATE_BUILD_DIRS (a file, or off / none / 0 to disable), else
#              <state dir>/<owner>__<repo>/build-dirs.tsv for this checkout's origin, else the shipped
#              defaults, build-dirs.tsv next to this file. A repo's table replaces the defaults.
#   rows       MATCH<TAB>KIND<TAB>NAME<TAB>VALUE; # comments and blank lines are skipped.
#              MATCH: * (every gate) or tool names joined by | (gradle|gradlew), matched against
#              the basename of each command word (its first token, as gate-slot.sh routes).
#              KIND env: export NAME=VALUE (overrides the inherited value: a shared TMPDIR is
#              the problem). KIND arg: insert NAME VALUE right after the first command word that is
#              exactly that tool, unless NAME (or NAME=...) is already on the command line, which
#              is kept, with a note on stderr. A tool reached only inside a `bash -c` string gets
#              env rows, not args. VALUE expands {dir} (the lane build dir), {id} (the lane id) and
#              {worktree}; an absolute VALUE is created as a directory.
#   lane dir   lane_build_dir: <root>/<id>, root ORCHESTRATE_BUILD_ROOT (default <state dir>/build),
#              id ORCHESTRATE_LANE_ID, else the worktree's basename and a checksum of its path. The
#              dir holds .worktree (the worktree path); wt-cleanup.sh removes a lane dir once its
#              worktree is gone. lane_build_dir is the one place the directory is derived: keep it
#              that way.
#   shared     shared_build_dir (#215): verification and device lanes on one tree fingerprint share
#              one build of their artifacts, <root>/shared/<fingerprint>--<name> (shared-build.sh).
#              Only artifacts are shared: TMPDIR and tool caches stay in the lane dir.
#              shared_builds_sweep prunes partial builds and builds past the keep / size cap, as
#              build rows in wt-cleanup.sh.
# The per-repo gate environment (gate-env.sh) is sourced after these exports and can override them.

_build_dirs_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# repo_state_dir: <state dir>/<owner>__<repo> for this checkout's origin, found without a network
# call; returns 1 when there is no GitHub-shaped origin.
repo_state_dir() {
  local url slug
  url=$(git remote get-url origin 2>/dev/null) || return 1
  slug=$(sed -E 's#^.*github\.com[:/]##; s#\.git$##' <<<"$url")
  [[ "$slug" == */* ]] || return 1
  echo "${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/${slug//\//__}"
}

build_root() { echo "${ORCHESTRATE_BUILD_ROOT:-${ORCHESTRATE_STATE_DIR:-$HOME/.claude/orchestrate}/build}"; }

# lane_build_worktree: the worktree the gate runs in (its toplevel, resolved), else the cwd.
lane_build_worktree() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) && (cd "$top" && pwd -P) && return 0
  pwd -P
}

# lane_build_dir WORKTREE: the lane-private build output directory for WORKTREE.
lane_build_dir() {
  local id=${ORCHESTRATE_LANE_ID:-}
  if [[ -n "$id" ]]; then
    id=$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')
  else
    id=$(basename -- "$1")
    id="$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')-$(printf '%s' "$1" | cksum | awk '{ print $1 }')"
  fi
  echo "$(build_root)/$id"
}

# build_dirs_table: the table in force; returns 1 when lane build dirs are off.
build_dirs_table() {
  local t=${ORCHESTRATE_BUILD_DIRS:-} s
  case "$t" in
    off | none | 0) return 1 ;;
    "") ;;
    *) echo "$t"; return 0 ;;
  esac
  if s=$(repo_state_dir) && [[ -f "$s/build-dirs.tsv" ]]; then echo "$s/build-dirs.tsv"; return 0; fi
  echo "$_build_dirs_here/build-dirs.tsv"
}

# _bd_tool WORD: the basename of WORD's first token.
_bd_tool() { basename -- "${1%% *}" 2>/dev/null || true; }

# build_dirs_apply CMD...: export the lane build dir and the table's env rows, and set BUILD_ARGV to
# CMD with the table's arg rows inserted. Never fails the gate: a problem is a note on stderr and
# the command runs as given.
build_dirs_apply() {
  BUILD_ARGV=("$@")
  local table wt dir id match kind name value i n at w t has
  table=$(build_dirs_table) || return 0
  [[ -r "$table" ]] || { echo "build-dirs: table $table not readable; lane build dirs not applied" >&2; return 0; }
  wt=$(lane_build_worktree)
  dir=$(lane_build_dir "$wt")
  id=${dir##*/}
  mkdir -p "$dir" 2>/dev/null || { echo "build-dirs: cannot create $dir; lane build dirs not applied" >&2; return 0; }
  [[ -f "$dir/.worktree" ]] || printf '%s\n' "$wt" >"$dir/.worktree"
  export ORCHESTRATE_LANE_BUILD_DIR="$dir" ORCHESTRATE_LANE_BUILD_ID="$id"
  while IFS=$'\t' read -r match kind name value || [[ -n "$match" ]]; do
    [[ -n "$match" && "$match" != \#* ]] || continue
    value=${value//"{dir}"/$dir}
    value=${value//"{id}"/$id}
    value=${value//"{worktree}"/$wt}
    n=${#BUILD_ARGV[@]} at=-1 has=no
    if [[ "$match" == "*" ]]; then
      has=yes
    else
      for ((i = 0; i < n; i++)); do
        w=${BUILD_ARGV[i]} t=$(_bd_tool "${BUILD_ARGV[i]}")
        [[ "|$match|" == *"|$t|"* ]] || continue
        has=yes
        if [[ "$w" != *" "* ]]; then at=$i; break; fi
      done
    fi
    [[ "$has" == yes ]] || continue
    case "$kind" in
      env)
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "build-dirs: bad env name '$name' in $table" >&2; continue; }
        export "$name=$value"
        ;;
      arg)
        ((at >= 0)) || continue
        w=no
        for ((i = 0; i < n; i++)); do
          [[ "${BUILD_ARGV[i]}" == "$name" || "${BUILD_ARGV[i]}" == "$name="* ]] && w=yes
        done
        if [[ "$w" == yes ]]; then
          echo "build-dirs: $name given on the command line; lane-private $value not applied" >&2
          continue
        fi
        BUILD_ARGV=("${BUILD_ARGV[@]:0:at+1}" "$name" "$value" "${BUILD_ARGV[@]:at+1}")
        ;;
      *) echo "build-dirs: unknown kind '$kind' in $table" >&2; continue ;;
    esac
    [[ "$value" != /* ]] || mkdir -p "$value" 2>/dev/null || true
  done <"$table"
  return 0
}

# build_dirs_sweep APPLY CWDS: one TSV row per lane build dir whose worktree is gone, and with APPLY
# = yes remove it, unless a process is working inside it (CWDS: one resolved cwd per line).
# Only direct children of the build root that hold a .worktree marker naming an absolute path that
# no longer exists are touched.
build_dirs_sweep() {
  local apply=$1 cwds=$2 root d wt
  root=$(build_root)
  [[ -n "$root" && -d "$root" ]] || return 0
  for d in "$root"/*; do
    [[ -d "$d" && -f "$d/.worktree" ]] || continue
    wt=$(sed -n 1p "$d/.worktree" 2>/dev/null || true)
    [[ "$wt" == /* && ! -e "$wt" ]] || continue
    if printf '%s\n' "$cwds" | awk -v d="$d" '$0 == d || index($0, d "/") == 1 { f = 1 } END { exit !f }'; then
      printf 'build\t%s\tkeep: a process is working inside it (worktree %s is gone)\n' "$d" "$wt"
    elif [[ "$apply" == yes ]]; then
      if rm -rf "$d" 2>/dev/null; then
        printf 'build\t%s\tremoved: worktree %s is gone\n' "$d" "$wt"
      else
        printf 'build\t%s\tkeep: could not remove it (worktree %s is gone)\n' "$d" "$wt"
      fi
    else
      printf 'build\t%s\tremovable: worktree %s is gone (dry run: --apply removes it)\n' "$d" "$wt"
    fi
  done
  shared_builds_sweep "$apply" "$cwds"
  return 0
}

# --- Shared builds per tree fingerprint (#215) ---
# A shared build is <shared root>/<fingerprint>--<name>: the artifacts at their worktree-relative
# paths, read-only, plus .done (TAB rows: fingerprint, name, built_at, lane) and .used (the epoch
# of its last reuse). It is built in <key>.tmp-<builder PID> and renamed into place once .done is
# written, so a directory without .done is a failed or partial build. <key>.lock is the build lock.

shared_build_root() { echo "$(build_root)/shared"; }

# shared_build_dir FINGERPRINT NAME: the shared artifacts directory for one build of one tree.
shared_build_dir() { echo "$(shared_build_root)/$1--$2"; }

# shared_build_shares CLASS: 0 when lanes of CLASS share builds per commit. The sharing classes are
# ORCHESTRATE_BUILD_SHARE (space or comma separated; default "verify device"; off / none / 0: none).
# Every other class (implementation lanes: impl) keeps the lane-private build of #213.
shared_build_shares() {
  local c=${1:-} s=${ORCHESTRATE_BUILD_SHARE-verify device}
  case "$s" in off | none | 0) return 1 ;; esac
  [[ -n "$c" && " ${s//,/ } " == *" $c "* ]]
}

# shared_build_complete DIR FINGERPRINT: DIR holds a finished build of FINGERPRINT.
shared_build_complete() {
  [[ -f "$1/.done" ]] || return 1
  [[ "$(awk -F'\t' '$1 == "fingerprint" { print $2; exit }' "$1/.done" 2>/dev/null || true)" == "$2" ]]
}

# _sb_last_use DIR: the epoch DIR was last built or reused (0 when unknown).
_sb_last_use() {
  local u
  u=$(sed -n 1p "$1/.used" 2>/dev/null || true)
  [[ "$u" =~ ^[0-9]+$ ]] || u=$(awk -F'\t' '$1 == "built_at" { print $2; exit }' "$1/.done" 2>/dev/null || true)
  [[ "$u" =~ ^[0-9]+$ ]] || u=0
  echo "$u"
}

# shared_build_remove DIR: remove a shared build; its files are read-only, so make them writable first.
shared_build_remove() {
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf "$1" 2>/dev/null && [[ ! -e "$1" ]]
}

# _sb_drop APPLY CWDS DIR REASON: one build row for DIR, removed with APPLY = yes unless in use.
_sb_drop() {
  if printf '%s\n' "$2" | awk -v d="$3" '$0 == d || index($0, d "/") == 1 { f = 1 } END { exit !f }'; then
    printf 'build\t%s\tkeep: a process is working inside it (%s)\n' "$3" "$4"
  elif [[ "$1" == yes ]]; then
    if shared_build_remove "$3"; then
      printf 'build\t%s\tremoved: %s\n' "$3" "$4"
    else
      printf 'build\t%s\tkeep: could not remove it (%s)\n' "$3" "$4"
    fi
  else
    printf 'build\t%s\tremovable: %s (dry run: --apply removes it)\n' "$3" "$4"
  fi
}

# shared_builds_sweep APPLY CWDS [PIN]: build rows for shared builds to drop, removed with APPLY = yes
# unless a process works inside one (CWDS as in build_dirs_sweep). Dropped: a staging dir whose
# builder is gone and a dir with no .done (failed or partial builds); and finished builds beyond the
# cap, newest use first: the newest is always kept, then up to ORCHESTRATE_SHARED_BUILD_KEEP builds
# (default 3) while their total size stays within ORCHESTRATE_SHARED_BUILD_MAX_MB (default 20480).
# PIN (a build just made) counts as the newest. Locks and a live builder's staging dir are left alone.
shared_builds_sweep() {
  local apply=$1 cwds=$2 root d name pid list="" keep cap n=0 total=0 size use
  root=$(shared_build_root)
  [[ -d "$root" ]] || return 0
  keep=${ORCHESTRATE_SHARED_BUILD_KEEP:-3} cap=${ORCHESTRATE_SHARED_BUILD_MAX_MB:-20480}
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=20480
  for d in "$root"/*; do
    [[ -d "$d" ]] || continue
    name=${d##*/}
    case "$name" in
      *.lock) continue ;;
      *.tmp-*)
        pid=${name##*.tmp-}
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then continue; fi
        _sb_drop "$apply" "$cwds" "$d" "partial shared build, builder $pid is gone"
        continue
        ;;
    esac
    if [[ ! -f "$d/.done" ]]; then
      _sb_drop "$apply" "$cwds" "$d" "shared build with no completion marker"
      continue
    fi
    use=$(_sb_last_use "$d")
    [[ "$d" != "${3:-}" ]] || use=99999999999 # the build just made sorts first: never pruned
    list+="$use"$'\t'"$d"$'\n'
  done
  [[ -n "$list" ]] || return 0
  while IFS=$'\t' read -r use d; do
    [[ -n "$d" ]] || continue
    n=$((n + 1))
    size=$(du -sk "$d" 2>/dev/null | awk '{ print $1 }' || true)
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    if ((n == 1)) || { ((n <= keep)) && ((total + size <= cap * 1024)); }; then
      total=$((total + size))
      continue
    fi
    _sb_drop "$apply" "$cwds" "$d" "shared build over the cap ($keep builds, $cap MB; last used $use)"
  done < <(printf '%s' "$list" | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2r)
  return 0
}
