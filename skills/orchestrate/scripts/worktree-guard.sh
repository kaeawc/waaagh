#!/usr/bin/env bash
# PreToolUse(Bash) hook (#394): keep new worktrees out of Spotlight. Denies `git worktree add PATH`
# and `jj workspace add PATH` when PATH is not below a directory whose name ends in .noindex (which
# Spotlight skips), nor below the lane root (wt-root.sh path), nor in a temp dir, and names the
# path to use instead, as the lane-safety hook names the lane root. Wired by hooks/hooks.json.
#
# Usage: worktree-guard.sh < payload.json      (payload: {"tool_input":{"command"},"cwd"})
#   PATH is read as the shell would: quotes, `cd DIR` earlier in the command (a literal DIR), git's
#   -C DIR, ~ and $HOME; a path through a symlink counts where the link lands, so a
#   .claude/worktrees linked to .claude/worktrees.noindex (wt-root.sh migrate --dir) is fine.
#   Allowed besides: a path built by "$(wt-root.sh path NAME)", and $TMPDIR. A path built from any
#   other variable or substitution is denied: the hook cannot tell where it lands.
#   Temp dirs: $WAAAGH_LANE_TEMP (colon list), default /tmp:/private/tmp:/var/folders:$TMPDIR.
#   Active on macOS (Spotlight's host) unless WAAAGH_WORKTREE_GUARD=off; =on makes it active
#   everywhere. A payload without `worktree` or `workspace` followed by whitespace and, later, `add`
#   is passed at once, without reading JSON (the hook runs before every Bash call).
# Output: nothing (allow; the normal permission flow continues) or one hookSpecificOutput JSON
#   object with permissionDecision deny and the reason.
# Exit: 0 always (a malformed payload is allowed: lane-safety.sh judges it), 2 an unknown argument.
set -uo pipefail
case "${1:-}" in -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;; esac
(($# == 0)) || { echo "worktree-guard.sh: unknown argument: $1 (usage: worktree-guard.sh < payload.json)" >&2; exit 2; }
# Read the payload first, whatever is decided: a hook that exits unread breaks its writer's pipe.
payload=""
IFS= read -r -d '' payload || true
case "${WAAAGH_WORKTREE_GUARD:-auto}" in
  off) exit 0 ;;
  on) ;;
  *) case "${OSTYPE:-}" in darwin*) ;; *) exit 0 ;; esac ;;
esac
# Only "worktree"/"workspace" then a space or a JSON escape (\t, \n) and later "add": a cwd such as
# ~/workspaces/app does not cost a jq call.
case "$payload" in *worktree[\ \\]*add* | *workspace[\ \\]*add*) ;; *) exit 0 ;; esac

# This script's directory with no subshell or dirname process (#112).
case "$0" in /*/*) here=${0%/*} ;; */*) here=$PWD/${0%/*} ;; *) here=$PWD ;; esac
command -v jq >/dev/null 2>&1 || exit 0
# One jq: the cwd and the command, each ended by a NUL (a command may hold newlines).
cwd="" cmd=""
{ IFS= read -r -d '' cwd && IFS= read -r -d '' cmd; } < <(jq -j '((.cwd // "") | strings) + "\u0000" + ((.tool_input.command // "") | strings) + "\u0000"' <<<"$payload" 2>/dev/null)
[[ -n "$cmd" ]] || exit 0
[[ -n "$cwd" && -d "$cwd" ]] || cwd=$PWD

temps=${WAAAGH_LANE_TEMP:-/tmp:/private/tmp:/var/folders${TMPDIR:+:$TMPDIR}}
denies=""

# norm PATH: an absolute PATH with . and .. resolved lexically and no trailing /.
norm() {
  local IFS=/ part out=""
  # shellcheck disable=SC2086  # split on / on purpose
  set -f; set -- $1; set +f
  for part in "$@"; do
    case "$part" in "" | .) ;; ..) out=${out%/*} ;; *) out="$out/$part" ;; esac
  done
  printf '%s\n' "${out:-/}"
}
# physical PATH: PATH with its deepest existing ancestor resolved through symlinks.
physical() {
  local p=$1 rest=""
  while [[ "$p" != / && ! -d "$p" ]]; do rest="/${p##*/}$rest"; p=${p%/*}; [[ -n "$p" ]] || p=/; done
  p=$(cd "$p" 2>/dev/null && pwd -P) || p=$1
  printf '%s\n' "${p%/}$rest"
}
under() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }
noindexed() { case "/$1/" in */*.noindex/*) return 0 ;; esac; return 1; }
# allowed PATH: below a .noindex directory, the lane root or a temp dir, lexically or physically.
allowed() {
  local p=$1 ph t
  ph=$(physical "$p")
  noindexed "$p" || noindexed "$ph" && return 0
  [[ -n "$root" ]] && { under "$p" "$root" || under "$ph" "$root"; } && return 0
  local IFS=:
  for t in $temps; do
    [[ -n "$t" ]] || continue
    t=${t%/}
    under "$p" "$t" || under "$ph" "$t" && return 0
  done
  return 1
}
# lane_root DIR: set root to the lane root of DIR's repository (orch_worktree_home), once.
root="" root_done=no
lane_root() {
  [[ "$root_done" == no ]] || return 0
  root_done=yes
  # shellcheck source=_lib.sh
  root=$(source "$here/_lib.sh" >/dev/null 2>&1 && orch_worktree_home "$1" 2>/dev/null) || root=""
  [[ -z "$root" ]] || root=$(norm "$root")
}

# judge KIND RAW BASE: one worktree path as written (RAW, with its quoting removed but $ kept)
# relative to BASE.
judge() {
  local kind=$1 raw=$2 base=$3 p name suggestion
  case "$raw" in
    *'$('*wt-root.sh*' path '*) return 0 ;;
    '$TMPDIR'/* | '${TMPDIR}'/*) return 0 ;;
    # With no HOME, ~ and $HOME stay unknown (judged as a variable below), never /.
    \~ | \~/*) p=${HOME:-'$HOME'}${raw#\~} ;;
    '$HOME'/* | '${HOME}'/*) p=${HOME:-'$HOME'}/${raw#*/} ;;
    *) p=$raw ;;
  esac
  name=${raw%/}; name=${name##*/}
  case "$name" in *'$'* | *'`'* | "" | . | ..) name="<lane>" ;; esac
  lane_root "$base"
  suggestion="${root:-~/worktrees.noindex/<repo>}/$name"
  case "$p" in
    *'$'* | *'`'*)
      denies="${denies:+$denies; }$kind $raw: the hook cannot tell where a path built from a variable lands; spell it out under the lane root ($suggestion, from \"\$(wt-root.sh path $name)\") or a temp dir"
      return ;;
  esac
  [[ "$p" == /* ]] || p=$base/$p
  p=$(norm "$p")
  allowed "$p" && return 0
  denies="${denies:+$denies; }$kind $p is outside a .noindex directory, so Spotlight indexes it (#394): create it under the lane root instead, $suggestion (wt-root.sh path $name), or in a temp dir; move existing trees with wt-root.sh migrate"
}

# analyze WORD...: one simple command.
analyze() {
  local base=$cwd
  while (($#)); do case "$1" in [A-Za-z_]*=* | env | command | nohup | time | exec | builtin) shift ;; *) break ;; esac; done
  (($#)) || return 0
  case "${1##*/}" in
    cd) [[ $# -ge 2 && "$2" != -* && "$2" != *'$'* ]] && { [[ "$2" == /* ]] && cwd=$(norm "$2") || cwd=$(norm "$cwd/$2"); }
      return 0 ;;
    git)
      shift
      while (($#)); do
        case "$1" in
          -C) [[ $# -ge 2 ]] || return 0; [[ "$2" == /* ]] && base=$(norm "$2") || base=$(norm "$base/$2"); shift 2 ;;
          -c | --git-dir | --work-tree | --namespace | --exec-path | --super-prefix | --config-env) shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      [[ "${1:-}" == worktree && "${2:-}" == add ]] || return 0
      shift 2
      while (($#)); do
        case "$1" in
          --) shift; break ;;
          -b | -B | --reason) shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      (($#)) && judge "git worktree add" "$1" "$base"
      ;;
    jj)
      shift
      while (($#)); do
        case "$1" in
          -R | --repository | --config | --config-toml | --config-file | --at-op | --at-operation | --color) shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      [[ "${1:-}" == workspace && "${2:-}" == add ]] || return 0
      shift 2
      while (($#)); do
        case "$1" in
          --) shift; break ;;
          --name | -r | --revision | --sparse-patterns | -m | --message) shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      (($#)) && judge "jj workspace add" "$1" "$base"
      ;;
  esac
  return 0
}

# Split the command into simple commands and words, as the shell would for these purposes: quotes
# removed (a quoted $ stays a $, so it is never mistaken for a literal path), separators ; & | ( )
# and newlines end a command. Expansions are not performed.
words=() w="" inword=no i=0 n=${#cmd} q=""
flush_word() { if [[ "$inword" == yes ]]; then words+=("$w"); w="" inword=no; fi; }
flush_cmd() { flush_word; ((${#words[@]})) && analyze "${words[@]}"; words=(); }
while ((i < n)); do
  c=${cmd:i:1}
  if [[ -n "$q" ]]; then
    if [[ "$c" == "$q" ]]; then q=""
    elif [[ "$q" == '"' && "$c" == \\ ]] && ((i + 1 < n)); then i=$((i + 1)); w+=${cmd:i:1}
    else w+=$c; fi
    i=$((i + 1)); continue
  fi
  case "$c" in
    "'" | '"') q=$c inword=yes ;;
    \\) i=$((i + 1))
      if [[ "${cmd:i:1}" != $'\n' ]]; then w+=${cmd:i:1}; inword=yes; fi ;;   # \<newline> continues the line
    ' ' | $'\t') flush_word ;;
    ';' | '&' | '|' | '(' | ')' | $'\n') flush_cmd ;;
    '$')
      # Keep a substitution whole: $( ... ) up to its matching ), so its words are not commands here.
      if [[ "${cmd:i+1:1}" == '(' ]]; then
        depth=0
        while ((i < n)); do
          c=${cmd:i:1}; w+=$c
          [[ "$c" == '(' ]] && depth=$((depth + 1))
          [[ "$c" == ')' ]] && { depth=$((depth - 1)); ((depth == 0)) && break; }
          i=$((i + 1))
        done
      else w+=$c; fi
      inword=yes ;;
    *) w+=$c; inword=yes ;;
  esac
  i=$((i + 1))
done
flush_cmd

[[ -n "$denies" ]] || exit 0
reason="worktree-guard: $denies. WAAAGH_WORKTREE_GUARD=off turns this check off."
reason=${reason//\\/\\\\}; reason=${reason//\"/\\\"}; reason=${reason//$'\n'/ }
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
exit 0
