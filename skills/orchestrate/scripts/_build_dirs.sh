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
#              that way (verification lanes sharing one build per commit, #215, extend it there).
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
  return 0
}
