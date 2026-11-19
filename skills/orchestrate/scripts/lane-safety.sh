#!/usr/bin/env bash
# PreToolUse hook enforcing the lane safety contract (skills/orchestrate/lane-safety.md) on Bash
# tool calls. Wired by hooks/hooks.json; reads the hook's JSON payload on stdin.
#
# Usage: lane-safety.sh < payload.json        (payload: {"tool_name","tool_input":{"command"},"cwd"})
# Denied everywhere: rm -r / find -delete on a protected root (/, $HOME, ~/Library, ~/.gradle,
#   ~/.android, the Android SDK, system dirs, $WAAAGH_PROTECTED_PATHS) or on an ancestor of one;
#   pkill, killall, xargs kill, kill fed by pgrep/pidof/lsof/ps; adb kill-server, adb emu kill
#   without -s; quitting, killing or opening Simulator.app; simctl shutdown/erase/delete all.
# Also denied in a lane (cwd in a linked git worktree, or $WAAAGH_LANE_ROOT set): gradle --stop
#   (it stops every lane's daemons), rm -r targets
#   outside the lane root and temp dirs (or the lane root itself), rm -r targets built from a
#   variable the hook cannot expand, and shell writes (>, >>, tee, cp, mv, sed -i, dd of=, ...)
#   that resolve outside the lane root, temp dirs, the state dir and $WAAAGH_LANE_ALLOW (temp dirs:
#   $WAAAGH_LANE_TEMP, default /tmp:/private/tmp:/var/folders:$TMPDIR; lists are colon-separated).
#   Denied only in a known lane (payload agent_id, $WAAAGH_LANE_ROOT, or an active lanes.tsv row
#   under the state root); in any other linked worktree, the owner's own session, they ask.
# Forbidden roots (#218): the orchestrator's own checkout, from $WAAAGH_LANE_FORBID (colon list) and
#   <state root>/lane-forbidden (one absolute path per line; # comments; state root:
#   $ORCHESTRATE_STATE_DIR, default ~/.claude/orchestrate). They bind a subagent's calls (payload
#   agent_id) and a lane session whose worktree is not itself forbidden, never the orchestrator's
#   own calls. Bound: denied are shell writes, rm -r / find -delete, mutating git (checkout, switch,
#   reset, pull, merge, rebase, commit, stash, restore, apply, am, cherry-pick, revert, clean, add,
#   rm, mv, worktree remove/move) and Edit/Write/MultiEdit/NotebookEdit under a forbidden root,
#   except inside the caller's own lane worktree nested below it.
# Asked (flagged for review): a destructive command that is backgrounded (&) or silenced
#   (output to /dev/null), even when its path looks safe. Not asked: `kill $(cat PIDFILE)
#   2>/dev/null` (stderr only; no wrapper; only resolved `cd DIR`s and read-only commands such as
#   grep, tail or ls before it) when the hook has read PIDFILE and it holds only PIDs above 1 (a
#   missing or malformed pidfile is asked, naming the path); a silenced kill whose PIDs are all
#   literal numbers above 1; a silenced stop of one named device (`adb -s SERIAL emu kill`,
#   `simctl shutdown UDID`), which loses nothing. Never a kill: signal 0 (kill -0, -s 0, -n 0)
#   and kill -l. A literal-PID kill is not "fed by a search", and ps -p/-q PID is a check, not one.
# A resolved `cd` into another linked worktree of the same repository makes that worktree
#   writable too: a lane subagent starts in the orchestrator's working directory and reaches its
#   own worktree by cd.
# Quieter writes: ~/.claude/projects/<project>/memory is writable from every session; in the
#   owner's session `cp .../android/local.properties <linked worktree>/android/` is allowed, and
#   WAAAGH_OWNER_SIBLING_WORKTREES=allow (default ask) allows writes and rm -r below another linked
#   worktree of the same repository without a cd into it. `rm -r "$VAR"` is judged by VAR's value
#   when a straight-line top-level literal assignment (VAR=..., export VAR=...) set it and VAR
#   appears nowhere else.
# Output: nothing (allow; the normal permission flow continues) or one hookSpecificOutput JSON
#   object with permissionDecision deny|ask and the reason. WAAAGH_LANE_SAFETY=off disables it.
# Exit: 0 decided (or not a Bash or edit call); 1 cannot run (no jq, unreadable payload; non-blocking);
#   2 bad usage: any argument but -h (the hook takes none; exit 2 blocks the call, so a mis-wired
#   hook is loud rather than silently off).
set -euo pipefail

case "${1:-}" in
  -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
  "") ;;
  *) echo "lane-safety.sh: reads a hook payload on stdin; no arguments" >&2
    echo "Usage: lane-safety.sh < payload.json" >&2; exit 2 ;;
esac
[[ "${WAAAGH_LANE_SAFETY:-on}" != off ]] || exit 0
command -v jq >/dev/null 2>&1 || { echo "lane-safety.sh: jq not found; lane safety not enforced" >&2; exit 1; }

payload=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || { echo "lane-safety.sh: unreadable payload" >&2; exit 1; }
case "$tool" in Bash | Edit | Write | MultiEdit | NotebookEdit) ;; *) exit 0 ;; esac
cmd=$(jq -r 'if .tool_name == "Bash" then .tool_input.command // empty
  else .tool_input.file_path // .tool_input.notebook_path // empty end' <<<"$payload")
cwd=$(jq -r '.cwd // empty' <<<"$payload")
agent=$(jq -r '.agent_id // empty' <<<"$payload")
[[ -n "$cwd" ]] || cwd=$PWD
[[ -n "$cmd" ]] || exit 0

home=${HOME:-/nonexistent}
state_root=${ORCHESTRATE_STATE_DIR:-$home/.claude/orchestrate}
# Raw forbidden roots; an edit tool call has nothing else to check, so it stops here without any.
forbid_raw=()
if [[ -n "${WAAAGH_LANE_FORBID:-}" ]]; then
  IFS=: read -r -a extra <<<"$WAAAGH_LANE_FORBID"
  ((${#extra[@]} == 0)) || forbid_raw+=("${extra[@]}")
fi
if [[ -r "$state_root/lane-forbidden" ]]; then
  while IFS= read -r v || [[ -n "$v" ]]; do forbid_raw+=("$v"); done <"$state_root/lane-forbidden"
fi
[[ "$tool" == Bash || ${#forbid_raw[@]} -gt 0 ]] || exit 0
US=$'\037' OP=$'\002'

# --- path helpers -------------------------------------------------------------------------------
# norm ABS: lexical normalisation (., .., //, trailing /).
norm() {
  local p=$1 out="" part
  local IFS=/
  # shellcheck disable=SC2086
  set -f; set -- $p; set +f
  for part in "$@"; do
    case "$part" in
      "" | .) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}
# expand WORD BASE: prints an absolute path, or returns 1 when the word holds a variable or a
# command substitution the hook cannot expand.
expand() {
  local w=$1 base=$2
  case "$w" in
    "~") w=$home ;;
    \~/*) w="$home/${w#\~/}" ;;
    '$HOME' | '${HOME}') w=$home ;;
    '$HOME/'*) w="$home/${w#\$HOME/}" ;;
    '${HOME}/'*) w="$home/${w#\$\{HOME\}/}" ;;
    '$PWD' | '${PWD}') w=$base ;;
    '$PWD/'*) w="$base/${w#\$PWD/}" ;;
    '${PWD}/'*) w="$base/${w#\$\{PWD\}/}" ;;
  esac
  if [[ -n "${TMPDIR:-}" ]]; then
    case "$w" in
      '$TMPDIR' | '${TMPDIR}') w=$TMPDIR ;;
      '$TMPDIR/'*) w="$TMPDIR/${w#\$TMPDIR/}" ;;
      '${TMPDIR}/'*) w="$TMPDIR/${w#\$\{TMPDIR\}/}" ;;
    esac
  fi
  case "$w" in *'$'* | *'`'*) return 1 ;; esac
  [[ "$w" == /* ]] || w="$base/$w"
  norm "$w"
}
# inside A B: A is B or below it.
inside() { [[ "$1" == "$2" || "$2" == / || "$1" == "$2"/* ]]; }
# reaches T R GLOB PREFIX: R lies strictly below T, and deleting T (with GLOB: T's entries whose
# names start with PREFIX) takes R with it.
reaches() {
  local rest
  [[ "$2" != "$1" ]] && inside "$2" "$1" || return 1
  [[ $3 == yes ]] || return 0
  rest=${2#"${1%/}"/}
  [[ "${rest%%/*}" == "$4"* ]]
}

# Roots a deletion may never reach. Trees: no deleting them, anything in them, or an ancestor.
# Exact: no deleting them or an ancestor (their contents are fine, e.g. /tmp/x, ~/src/x).
trees=("$home/Library" "$home/.gradle" "$home/.android" "$home/.m2" "$home/.ssh" "$home/Android"
  /Applications /System /Library /usr /bin /sbin /etc /opt /private/etc)
for v in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do [[ -z "$v" ]] || trees+=("$v"); done
if [[ -n "${WAAAGH_PROTECTED_PATHS:-}" ]]; then
  IFS=: read -r -a extra <<<"$WAAAGH_PROTECTED_PATHS"
  for v in "${extra[@]}"; do [[ -z "$v" ]] || trees+=("$v"); done
fi
exacts=(/ "$home" "$home/.claude" "$home/.config" /var /private /tmp /private/tmp /Users /home /Volumes)

# Lane mode: the lane root is the linked worktree holding cwd (or $WAAAGH_LANE_ROOT).
lane=${WAAAGH_LANE_ROOT:-}
if [[ -z "$lane" ]] && command -v git >/dev/null 2>&1; then
  gd=$(git -C "$cwd" rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel 2>/dev/null || true)
  if [[ -n "$gd" ]]; then
    g1=$(sed -n 1p <<<"$gd") g2=$(sed -n 2p <<<"$gd") top=$(sed -n 3p <<<"$gd")
    [[ "$g1" == "$g2" || -z "$top" ]] || lane=$top
  fi
fi
[[ -z "$lane" ]] || lane=$(norm "$lane")
allowed=()
if [[ -n "$lane" ]]; then
  allowed=("$lane" "${ORCHESTRATE_STATE_DIR:-$home/.claude/orchestrate}")
  temps=${WAAAGH_LANE_TEMP-/tmp:/private/tmp:/var/folders${TMPDIR:+:$TMPDIR}}
  if [[ -n "$temps${WAAAGH_LANE_ALLOW:-}" ]]; then
    IFS=: read -r -a extra <<<"$temps:${WAAAGH_LANE_ALLOW:-}"
    for v in "${extra[@]}"; do [[ -z "$v" ]] || allowed+=("$(norm "$v")"); done
  fi
fi
in_allowed() { local a; for a in "${allowed[@]}"; do inside "$1" "$a" && return 0; done; return 1; }
# enter_worktree DIR: a resolved `cd` into another linked worktree of this repository makes that
# worktree writable too. A lane subagent starts in the orchestrator's working directory (rule 7),
# itself a linked worktree in the desktop app, and reaches its own worktree by cd: without this its
# every shell write there is "outside the lane". The main checkout is no linked worktree, and a
# forbidden root stays denied (check_write and check_delete test it first).
enter_worktree() {
  local d=$1 o t1 t2 top
  [[ -n "$lane" && -n "${g2:-}" ]] || return 0
  ! in_allowed "$d" || return 0
  # `mkdir -p WT/scratch; cd WT/scratch`: the directory may not exist yet, so ask its nearest parent.
  while [[ ! -d "$d" && "$d" == /*/* ]]; do d=${d%/*}; done
  o=$(git -C "$d" rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel 2>/dev/null) || return 0
  t1=$(sed -n 1p <<<"$o") t2=$(sed -n 2p <<<"$o") top=$(sed -n 3p <<<"$o")
  [[ -n "$top" && "$t1" != "$t2" && "$t2" == "$g2" ]] || return 0
  allowed+=("$(norm "$top")")
}
# A known lane gets lane-mode denials: a subagent's call (payload agent_id), $WAAAGH_LANE_ROOT, or
# a worktree with a live row in a lanes.tsv under the state root (lane-claim.sh add; live = any
# status but done, merged, closed or abandoned, as lane-claim.sh counts it). A row matches when its
# worktree holds this lane or sits inside it (either way errs toward deny); a relative row resolves
# against the repository's main checkout, where lane-claim.sh runs. Any other linked worktree is the
# owner's own session (the desktop app runs every session in one): there the same rules ask instead,
# so the owner approves or declines in the permission prompt.
known_lane=no
if [[ -n "$lane" ]]; then
  if [[ -n "$agent" || -n "${WAAAGH_LANE_ROOT:-}" ]]; then known_lane=yes
  else
    lane_p=$(cd "$lane" 2>/dev/null && pwd -P || printf '%s' "$lane")
    main_co=""
    [[ -z "${g2:-}" ]] || main_co=$(dirname "$g2")
    for f in "$state_root/lanes.tsv" "$state_root"/*/lanes.tsv; do
      [[ -r "$f" ]] || continue
      while IFS= read -r row || [[ -n "$row" ]]; do
        row=${row%$'\r'}
        [[ -n "$row" && "$row" != \#* && "$row" == *$'\t'* ]] || continue
        wt=${row%%$'\t'*} st=${row##*$'\t'}
        st=${st%"${st##*[![:space:]]}"}
        case "$st" in done | merged | closed | abandoned) continue ;; esac
        case "$wt" in
          /*) ;;
          "~" | \~/*) wt="$home${wt#\~}" ;;
          *) [[ -n "$main_co" ]] || continue; wt="$main_co/$wt" ;;
        esac
        wt=$(norm "$wt")
        wt_p=$(cd "$wt" 2>/dev/null && pwd -P || printf '%s' "$wt")
        for v in "$wt" "$wt_p"; do
          if inside "$lane" "$v" || inside "$lane_p" "$v" || inside "$v" "$lane" || inside "$v" "$lane_p"; then
            known_lane=yes; break 3
          fi
        done
      done <"$f"
    done
  fi
fi

# Forbidden roots (#218), each also by its physical path (/tmp vs /private/tmp). A lane's own
# worktree nested below one (.claude/worktrees/<lane>) stays writable: own.
forbid=() own="" lane_forbidden=no
for v in "${forbid_raw[@]:-}"; do
  case "$v" in /* | "~" | \~/*) ;; *) continue ;; esac
  v=$(expand "$v" /) || continue
  [[ "$v" != / ]] || continue
  forbid+=("$v")
  if p=$(cd "$v" 2>/dev/null && pwd -P) && [[ "$p" != "$v" ]]; then forbid+=("$p"); fi
done
if ((${#forbid[@]})); then
  own=$lane
  for v in "${forbid[@]}"; do
    [[ "$lane" != "$v" ]] || lane_forbidden=yes
    [[ -z "$own" ]] || ! inside "$v" "$own" || own=""
  done
  # Unbound: the orchestrator's own call (no subagent, and its cwd is no lane or a forbidden root).
  if [[ -z "$agent" && ( -z "$lane" || $lane_forbidden == yes ) ]]; then forbid=(); fi
fi
# forbidden PATH: prints the bound forbidden root holding PATH (none inside the caller's own lane).
forbidden() {
  local f
  ((${#forbid[@]})) || return 1
  [[ -z "$own" ]] || ! inside "$1" "$own" || return 1
  for f in "${forbid[@]}"; do
    if inside "$1" "$f"; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}
forbid_why() { printf '%s' "$1 is in the orchestrator's checkout $2 ($state_root/lane-forbidden): never edit, check out, pull, commit or build there; work in your own worktree"; }

denies="" asks=""
deny() { denies="${denies:+$denies; }$1"; }
ask() { asks="${asks:+$asks; }$1"; }
# lane_deny MSG: a lane-mode rule; denied in a known lane, asked in the owner's own worktree session.
lane_deny() {
  if [[ $known_lane == yes ]]; then deny "$1"
  else ask "$1 (this worktree is no registered lane: approve only if you are the owner)"; fi
}
# claude_memory PATH: PATH is inside a Claude project's auto-memory dir
# (~/.claude/projects/<project>/memory), which every session may write.
claude_memory() {
  local rest=${1#"$home/.claude/projects/"}
  [[ "$rest" != "$1" && "$rest" == ?*/memory* && "${rest#*/}" =~ ^memory(/|$) ]]
}
# sibling_worktree PATH: prints the linked worktree (not the main checkout, not this session's own
# worktree) of this repository that holds PATH. Listed once, lazily, from git worktree list.
siblings_listed=no siblings=()
sibling_worktree() {
  local w p
  if [[ $siblings_listed == no ]]; then
    siblings_listed=yes
    while IFS= read -r w; do
      [[ -n "$w" ]] || continue
      w=$(norm "$w")
      [[ "$w" != "$lane" ]] || continue
      siblings+=("$w")
      if p=$(cd "$w" 2>/dev/null && pwd -P) && [[ "$p" != "$w" ]]; then siblings+=("$p"); fi
    done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | sed 1d)
  fi
  for w in "${siblings[@]:-}"; do
    if [[ -n "$w" ]] && inside "$1" "$w"; then printf '%s\n' "$w"; return 0; fi
  done
  return 1
}
# owner_sibling PATH: in the owner's own session (no known lane), WAAAGH_OWNER_SIBLING_WORKTREES=allow
# lets writes and deletions below another linked worktree of the same repository through (the
# orchestrator driving its lanes' scratch dirs); default ask.
owner_sibling() {
  local w
  [[ $known_lane == no && "${WAAAGH_OWNER_SIBLING_WORKTREES:-ask}" == allow ]] || return 1
  w=$(sibling_worktree "$1") && [[ "$1" != "$w" ]]
}
# local_props TARGET BASE SRC...: the documented Android worktree setup step in the owner's session,
# `cp <checkout>/android/local.properties <worktree>/android/` (the file is gitignored and every
# new worktree needs it): every source is an android/local.properties and the target is the
# android dir (or android/local.properties) of a linked worktree of this repository.
local_props() {
  local target=$1 base=$2 src t w; shift 2
  [[ $known_lane == no && -n "$lane" && $# -gt 0 ]] || return 1
  for src in "$@"; do
    [[ "$src" == android/local.properties || "$src" == */android/local.properties ]] || return 1
  done
  t=$(expand "$target" "$base") || return 1
  w=$(sibling_worktree "$t") || return 1
  [[ "$t" == "$w/android" || "$t" == "$w/android/local.properties" ]]
}
# Literal assignments (NAME=WORD, export NAME=WORD) the hook can expand, so `B=$PWD/scratch/x;
# rm -rf "$B"` is judged by its real path. Recorded only in a straight-line top-level prefix (only
# `;` or newlines before it, no pipe, subshell, loop, conditional or failed cd), and used only when
# NAME appears nowhere else in the command but as $NAME / ${NAME} (no read, for, second assignment,
# ${NAME:=}...), and nothing is sourced.
var_names=() var_vals=() vars_text=""
# bare_count NAME: occurrences of NAME in vars_text other than $NAME and ${NAME}.
bare_count() {
  awk -v n="$1" 'BEGIN { RS = "\001" } { s = " " $0 " "; c = 0; L = length(n)
    for (i = 2; i <= length(s) - L; i++) if (substr(s, i, L) == n) {
      b = substr(s, i - 1, 1); a = substr(s, i + L, 1)
      if (b ~ /[A-Za-z0-9_]/ || a ~ /[A-Za-z0-9_]/ || b == "$") continue
      if (b == "{" && substr(s, i - 2, 1) == "$") { if (a == "=" || a == ":" || a == "-" || a == "+") c += 2; continue }
      c++
    }
    print c }' <<<"$vars_text"
}
# subst_var WORD: WORD with a leading $NAME or ${NAME} replaced by its recorded literal value.
subst_var() {
  local w=$1 name rest k
  # Only the top-level shell holds them: bash -c and eval bodies run where they may be unset.
  [[ "${depth:-0}" == 0 ]] || return 1
  if [[ "$w" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ || "$w" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)(/.*)?$ ]]; then
    name=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]}
  else return 1; fi
  for ((k = ${#var_names[@]} - 1; k >= 0; k--)); do
    [[ "${var_names[k]}" == "$name" ]] || continue
    [[ "$(bare_count "$name")" == 1 ]] || return 1
    printf '%s\n' "${var_vals[k]}$rest"; return 0
  done
  return 1
}

# check_delete WORD BASE WHAT: a recursive deletion target.
check_delete() {
  local w=$1 base=$2 what=$3 t glob=no prefix="" r s
  if ! t=$(expand "$w" "$base") && { ! s=$(subst_var "$w") || ! t=$(expand "$s" "$base"); }; then
    [[ -z "$lane" ]] || lane_deny "$what $w: path built from a variable; expand and echo the literal path first"
    return 0
  fi
  # A glob is judged by the directory it lists (t) and the literal start of the globbed name
  # (prefix): "dir/*" empties dir, "dir/x*" reaches only the entries starting with x.
  case "$t" in
    *[*?[]*) glob=yes; t=${t%%[*?[]*}; prefix=${t##*/}; t=${t%/*}; t=${t:-/} ;;
  esac
  for r in "${exacts[@]}"; do
    if [[ "$r" == "$t" ]]; then
      [[ $glob == yes && -n "$prefix" ]] || { deny "$what $w: protected path $r"; return 0; }
    elif reaches "$t" "$r" "$glob" "$prefix"; then deny "$what $w: protected path $r"; return 0; fi
  done
  for r in "${trees[@]}"; do
    r=$(norm "$r")
    if inside "$t" "$r" || reaches "$t" "$r" "$glob" "$prefix"; then deny "$what $w: protected path $r"; return 0; fi
  done
  if r=$(forbidden "$t"); then deny "$what $w: $(forbid_why "$t" "$r")"; return 0; fi
  for r in "${forbid[@]:-}"; do
    if [[ -n "$r" ]] && reaches "$t" "$r" "$glob" "$prefix"; then deny "$what $w: $(forbid_why "$t" "$r")"; return 0; fi
  done
  [[ -n "$lane" ]] || return 0
  if [[ $glob == no && "$t" == "$lane" ]]; then lane_deny "$what $w: that is the lane worktree itself; use git worktree remove"; return 0; fi
  if owner_sibling "$t"; then return 0; fi
  if [[ $glob == no ]]; then
    local a ok=no
    for a in "${allowed[@]}"; do [[ "$t" == "$a"/* ]] && ok=yes; done
    [[ $ok == yes ]] || lane_deny "$what $w: outside the lane worktree $lane and temp dirs"
  else
    in_allowed "$t" || lane_deny "$what $w: outside the lane worktree $lane and temp dirs"
  fi
}
# check_write WORD BASE WHAT: a file a shell command writes (lane mode only).
check_write() {
  [[ -n "$lane" || ${#forbid[@]} -gt 0 ]] || return 0
  local w=$1 base=$2 what=$3 t f
  case "$w" in /dev/null | /dev/stdout | /dev/stderr | /dev/tty | /dev/fd/* | "") return 0 ;; esac
  t=$(expand "$w" "$base") || return 0
  if f=$(forbidden "$t"); then deny "$what $w: $(forbid_why "$t" "$f")"; return 0; fi
  [[ -n "$lane" ]] || return 0
  in_allowed "$t" || claude_memory "$t" || owner_sibling "$t" || lane_deny "$what $w: writes outside the lane worktree $lane; enter the worktree (EnterWorktree) and use the edit tools"
}
# check_git BASE ARG...: a mutating git command whose work tree (BASE, -C, --work-tree) lies under a
# bound forbidden root. Read-only commands, fetch and worktree add stay allowed there.
check_git() {
  local dir=$1 sub="" f; shift
  ((${#forbid[@]})) || return 0
  while (($#)); do
    case "$1" in
      -C | --work-tree) (($# >= 2)) || return 0; dir=$(expand "$2" "$dir") || return 0; shift 2 ;;
      --work-tree=*) dir=$(expand "${1#*=}" "$dir") || return 0; shift ;;
      -c | --git-dir | --namespace) shift; if (($#)); then shift; fi ;;
      -*) shift ;;
      *) sub=$1; shift; break ;;
    esac
  done
  case "$sub" in
    checkout | switch | reset | pull | merge | rebase | commit | stash | restore | apply | am | cherry-pick | revert | clean | add | rm | mv) ;;
    worktree)
      case "${1:-}" in remove | move) ;; *) return 0 ;; esac
      shift
      while (($#)) && [[ "$1" == -* ]]; do shift; done
      (($#)) || return 0
      dir=$(expand "$1" "$dir") || return 0
      sub="worktree remove/move" ;;
    *) return 0 ;;
  esac
  if f=$(forbidden "$dir"); then deny "git $sub: $(forbid_why "$dir" "$f")"; fi
}

# --- tokenizer ----------------------------------------------------------------------------------
# One line per simple command: "<terminator>\036<tok>\037<tok>...\036<ids>". Operator tokens start
# with \002. Command substitutions ($(...), `...`) leave "$(...)" in the word and are emitted as
# their own commands after a "subid\036<id>\036" line; <ids> lists (comma-separated) the
# substitutions in that command's words. A "paren\036\036" line marks a ( or ) (subshell, function,
# array, case pattern). Heredoc bodies and comments are skipped; a quoted newline
# stays in its word as \035, so one command is always one line.
tokenize() {
  awk -v US="$US" -v OP="$OP" -v NL=$'\035' '
  function flush() { if (have) { toks = toks (ntok ? US : "") word; ntok++; word = ""; have = 0 } }
  function emit(term) { flush(); if (ntok) print term "\036" toks "\036" cmdsubs; toks = ""; ntok = 0; cmdsubs = "" }
  function optok(o) { flush(); toks = toks (ntok ? US : "") OP o; ntok++ }
  # read a $( ... ) or ` ... ` body starting at position i (just after the opener); returns end index
  function grab(s, i, closer,   depth, c, body, q) {
    depth = 1; body = ""; q = ""
    for (; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q != "") { if (c == q) q = ""; body = body c; continue }
      if (closer == ")" && (c == "\047" || c == "\"")) { q = c; body = body c; continue }
      if (closer == ")" && c == "(") depth++
      if (c == closer) { depth--; if (depth == 0) break }
      body = body c
    }
    subs[++nsubs] = body; cmdsubs = cmdsubs (cmdsubs == "" ? "" : ",") nsubs
    return i
  }
  function scan(s,   i, c, n, n2, sq, dq, hd, line, k, j, delim, strip) {
    sq = 0; dq = 0; word = ""; have = 0; toks = ""; ntok = 0; nhd = 0; wantdelim = 0; cmdsubs = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1); n = substr(s, i + 1, 1); n2 = substr(s, i + 2, 1)
      if (sq) { if (c == "\047") sq = 0; else word = word (c == "\n" ? NL : c); continue }
      if (dq) {
        if (c == "\"") { dq = 0; continue }
        if (c == "\\" && (n == "\"" || n == "\\" || n == "$" || n == "`")) { word = word n; i++; continue }
        if (c == "$" && n == "(") { i = grab(s, i + 2, ")"); word = word "$(...)"; continue }
        if (c == "`") { i = grab(s, i + 1, "`"); word = word "$(...)"; continue }
        word = word (c == "\n" ? NL : c); continue
      }
      if (c == "\047") { sq = 1; have = 1; continue }
      if (c == "\"") { dq = 1; have = 1; continue }
      if (c == "\\") { if (n == "\n") { i++; continue } word = word n; have = 1; i++; continue }
      if (c == " " || c == "\t") { flush(); if (wantdelim) { } continue }
      if (c == "#" && !have) { while (i <= length(s) && substr(s, i, 1) != "\n") i++; i--; continue }
      if (c == "\n") {
        emit("nl")
        for (k = 1; k <= nhd; k++) {
          delim = hdd[k]; strip = hds[k]
          while (i < length(s)) {
            j = index(substr(s, i + 1), "\n"); if (j == 0) { line = substr(s, i + 1); i = length(s) } else { line = substr(s, i + 1, j - 1); i += j }
            if (strip) sub(/^\t+/, "", line)
            if (line == delim) break
          }
        }
        nhd = 0; continue
      }
      if (c == ";") { emit(";"); continue }
      if (c == "&") {
        if (n == "&") { emit("&&"); i++; continue }
        if (n == ">") { if (n2 == ">") { optok("&>>"); i += 2 } else { optok("&>"); i++ } continue }
        emit("&"); continue
      }
      if (c == "|") { if (n == "|") { emit("||"); i++ } else { if (n == "&") i++; emit("|") } continue }
      if (c == "(" || c == ")") { emit("sub"); print "paren\036\036"; continue }
      if (c == "$" && n == "(") { i = grab(s, i + 2, ")"); word = word "$(...)"; have = 1; continue }
      if (c == "`") { i = grab(s, i + 1, "`"); word = word "$(...)"; have = 1; continue }
      if (c == ">" || c == "<") {
        fd = ""; if (have && word ~ /^[0-9]+$/) { fd = word; word = ""; have = 0 }
        o = c
        if (c == ">" && (n == ">" || n == "|" || n == "&")) { o = o n; i++ }
        else if (c == "<" && n == "<") { o = "<<"; i++; if (n2 == "<") { o = "<<<"; i++ } else if (n2 == "-") { o = "<<-"; i++ } }
        else if (c == "<" && (n == ">" || n == "&")) { o = o n; i++ }
        optok(fd o)
        if (o == "<<" || o == "<<-") {
          # the next word is a heredoc delimiter
          while (substr(s, i + 1, 1) == " " || substr(s, i + 1, 1) == "\t") i++
          delim = ""
          for (i++; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "&" || c == "|" || c == ")" || c == "<" || c == ">") { i--; break }
            if (c != "\047" && c != "\"" && c != "\\") delim = delim c
          }
          hdd[++nhd] = delim; hds[nhd] = (o == "<<-")
          word = delim; have = 1; flush()
        }
        continue
      }
      word = word c; have = 1
    }
    emit("end")
  }
  { buf = buf (NR > 1 ? "\n" : "") $0 }
  END {
    nsubs = 0; scan(buf)
    for (q = 1; q <= nsubs; q++) { print "subid\036" q "\036"; scan(subs[q]) }
  }'
}

# --- analysis -----------------------------------------------------------------------------------
# analyze TEXT BASE [DEPTH]: every simple command in TEXT; a cd changes the base (cur) for the
# commands after it. saw_kill/saw_pidsrc/cur/cmd_subs/quiet_kills are read and set by
# analyze_simple (dynamic scope).
destructive=no
analyze() {
  local text=$1 cur=$2 depth=${3:-0} line term rest toks
  local saw_kill=no saw_pidsrc=no cmd_subs="" cursub=0 quiet_kills=() subn=() subtoks=() q
  # prefix_ok: every top-level command so far is inert (a plain `cd DIR` the hook resolved, a quiet
  # kill, or a read-only command with no file redirection), so nothing in this text can have
  # changed a pidfile or the cwd behind the hook's back. A cd counts only when the shell is sure to
  # run it in this shell: not in a pipeline or after ||, after && only when a cd precedes it (a
  # failed cd leaves no pidfile to find), and never near a parenthesis (a subshell's cd is undone).
  local prefix_ok=yes inert=no prev_term="" prev_cd=no
  # straight: every top-level command so far was plain and ended by `;` or a newline (the cumulative
  # form of prev_term), so a literal assignment now runs unconditionally in this shell (see
  # subst_var). plain: set by analyze_simple for the command it judged.
  local straight=no plain=yes t
  ((depth < 4)) || return 0
  if ((depth == 0)); then
    vars_text=$text var_names=() var_vals=()
    local o1='$(' o2='<(' o3='>('
    t=${text//"$o1"/}; t=${t//"$o2"/}; t=${t//"$o3"/}
    [[ "$t" == *'('* ]] || straight=yes
  fi
  while IFS= read -r line; do
    term=${line%%$'\036'*} rest=${line#*$'\036'}
    cmd_subs=${rest##*$'\036'} rest=${rest%$'\036'*}
    if [[ "$term" == subid ]]; then cursub=$rest; continue; fi
    if [[ "$term" == paren ]]; then ((cursub > 0)) || prefix_ok=no; continue; fi
    IFS=$US read -r -a toks <<<"$rest"
    ((${#toks[@]})) || continue
    if ((cursub > 0)); then subn[cursub]=$((${subn[cursub]:-0} + 1)); subtoks[cursub]=$rest; fi
    inert=no
    local is_cd=no
    if ((cursub == 0 && ${#toks[@]} == 2)) && [[ "${toks[0]}" == cd && "${toks[1]}" != -* && "$term" =~ ^(\;|nl|\&\&|end)$ ]] &&
      [[ "$prev_term" != "|" && "$prev_term" != "||" && ( "$prev_term" != "&&" || $prev_cd == yes ) ]] &&
      expand "${toks[1]}" "$cur" >/dev/null; then inert=yes is_cd=yes; fi
    plain=yes
    analyze_simple "$term" "$cur" "$depth" "${toks[@]}"
    ((cursub > 0)) || [[ $inert == yes ]] || prefix_ok=no
    if ((cursub == 0)); then
      [[ $plain == yes && "$term" =~ ^(\;|nl|end)$ ]] || straight=no
      prev_term=$term prev_cd=$is_cd
    fi
  done < <(tokenize <<<"$text")
  for q in ${quiet_kills[@]+"${quiet_kills[@]}"}; do quiet_kill "${q%%$'\036'*}" "${q#*$'\036'}"; done
  if [[ $saw_kill == yes && $saw_pidsrc == yes ]]; then
    deny "kill fed by a process search (pgrep/pidof/lsof/ps): kill only PIDs you recorded at start"
  fi
}

# quiet_kill BASE IDS: a `kill $(cat PIDFILE) 2>/dev/null` (substitution IDS, cwd BASE). Silence
# hides only "no such process" when every PID comes from a pidfile the hook has read: each
# substitution is exactly `cat FILE` or `<FILE` (its own 2>/dev/null allowed), and FILE exists and
# holds only PIDs above 1 (0 is the caller's process group, 1 is init). Anything else is asked,
# naming a missing or malformed pidfile (a mistyped path is caught here, before the command runs).
# analyze_simple only sends a kill here when the file the hook reads is the file the shell will
# read: the kill is the command's first word at the top level (no sudo, env, bash -c or eval), its
# one redirection is 2>/dev/null, it is not piped, and only resolved `cd DIR` commands, other quiet
# kills and read-only commands precede it in the text (nothing that could write the pidfile or move
# the cwd).
quiet_kill() {
  local base=$1 ids=$2 id st f path why=""
  for id in ${ids//,/ }; do
    st=()
    [[ "${subn[id]:-0}" != 1 ]] || IFS=$US read -r -a st <<<"${subtoks[id]}"
    if ((${#st[@]} == 4)) && [[ "${st[2]}" == "${OP}2>" && "${st[3]}" == /dev/null ]]; then st=("${st[0]}" "${st[1]}"); fi
    f=""
    if ((${#st[@]} == 2)) && [[ "${st[0]}" == cat || "${st[0]}" == "$OP<" ]] && [[ "${st[1]}" != -* ]]; then f=${st[1]}; fi
    if [[ -z "$f" ]] || ! path=$(expand "$f" "$base"); then why="let its output show"; break; fi
    if [[ ! -f "$path" || ! -r "$path" ]]; then why="pidfile $f not found ($path): fix the path, or let kill's output show"; break; fi
    if ! awk '{ for (i = 1; i <= NF; i++) { n++; if ($i !~ /^[0-9]+$/ || $i + 0 < 2) bad = 1 } }
      END { exit (n && !bad) ? 0 : 1 }' "$path"; then
      why="pidfile $f ($path) does not hold only PIDs above 1: let kill's output show"; break
    fi
  done
  [[ -z "$why" ]] || ask "silenced destructive command (kill ... >/dev/null): $why"
}

# record_vars TERM DEPTH NREDIR WORD...: record NAME=VALUE words whose value the hook can expand,
# when the command runs unconditionally in the top-level shell (straight, cursub and plain come from
# analyze by dynamic scope). Any other word, or an unexpandable value, records nothing for it.
record_vars() {
  local term=$1 d=$2 nr=$3 w v; shift 3
  [[ $d == 0 && $cursub == 0 && $straight == yes && $nr == 0 && "$term" =~ ^(\;|nl|\&\&|end)$ ]] || return 0
  for w in "$@"; do
    [[ "$w" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 0
  done
  for w in "$@"; do
    [[ "$w" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]
    local name=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    [[ -n "$val" ]] || continue
    if v=$(expand "$val" "$cur") || { v=$(subst_var "$val") && v=$(expand "$v" "$cur"); }; then
      var_names+=("$name") var_vals+=("$v")
    fi
  done
}

analyze_simple() {
  local term=$1 base=$2 depth=$3; shift 3
  local args=() t i via_xargs=no silenced=no nredir=0 only_err=no kill_quiet=no kill_literal=no filered=no stop_named=no
  # split redirections from words
  while (($#)); do
    t=$1; shift
    if [[ "$t" == "$OP"* ]]; then
      t=${t#"$OP"}
      local target=${1:-}
      (($#)) && shift
      ((nredir += 1))
      case "$t" in
        *'>&') [[ "$target" =~ ^[0-9-]+$ ]] || { filered=yes; check_write "$target" "$base" "redirect"; } ;;
        *'>' | *'>|')
          if [[ "$target" == /dev/null ]]; then
            silenced=yes
            [[ "$t" != '2>' ]] || only_err=yes
          else filered=yes; check_write "$target" "$base" "redirect"; fi ;;
      esac
    else
      args+=("$t")
    fi
  done
  ((${#args[@]})) || return 0
  # strip prefixes: assignments, wrappers, keywords
  i=0
  while ((i < ${#args[@]})); do
    t=${args[i]}
    case "$t" in
      [A-Za-z_]*=*) [[ "${t%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || break; ((i += 1)) ;;
      command | builtin | exec | nohup | time | noglob | caffeinate) ((i += 1)) ;;
      '{' | '}' | '!' | then | do | else | elif | if | while | until) plain=no; ((i += 1)) ;;
      sudo | doas)
        ((i += 1))
        while ((i < ${#args[@]})) && [[ "${args[i]}" == -* ]]; do
          case "${args[i]}" in -u | -g | -C | -h | -p) ((i += 2)) ;; *) ((i += 1)) ;; esac
        done ;;
      env)
        ((i += 1))
        while ((i < ${#args[@]})) && [[ "${args[i]}" == -* || "${args[i]}" == *=* ]]; do
          case "${args[i]}" in -u | -C | -S) ((i += 2)) ;; *) ((i += 1)) ;; esac
        done ;;
      nice) ((i += 1)); [[ "${args[i]:-}" != -n ]] || ((i += 2)); [[ "${args[i]:-}" != -[0-9]* ]] || ((i += 1)) ;;
      timeout | gtimeout)
        ((i += 1))
        while ((i < ${#args[@]})) && [[ "${args[i]}" == -* ]]; do
          case "${args[i]}" in -s | -k) ((i += 2)) ;; *) ((i += 1)) ;; esac
        done
        ((i += 1)) ;;
      xargs | gxargs)
        via_xargs=yes; ((i += 1))
        while ((i < ${#args[@]})) && [[ "${args[i]}" == -* ]]; do
          case "${args[i]}" in -I | -n | -P | -L | -d | -E | -s | -a) ((i += 2)) ;; *) ((i += 1)) ;; esac
        done ;;
      *) break ;;
    esac
  done
  if ((i == ${#args[@]})); then
    # Assignments only: record the literal ones (subst_var).
    [[ $plain == yes ]] && record_vars "$term" "$depth" $nredir "${args[@]}"
    return 0
  fi
  local c=${args[i]##*/}
  local a=("${args[@]:i+1}")
  local n=${#a[@]} low j

  case "$c" in
    cd)
      if ((n == 0)); then cur=$home; elif [[ "${a[0]}" != - ]]; then
        cur=$(expand "${a[0]}" "$base") || { cur=$base; plain=no; }
      else plain=no; fi
      [[ -d "$cur" ]] || plain=no
      enter_worktree "$cur" ;;
    export) ((i == 0)) && record_vars "$term" "$depth" $nredir "${a[@]:-}" ;;
    for | case | select | function | source | . | pushd | popd)
      plain=no
      [[ "$c" != source && "$c" != . ]] || { var_names=() var_vals=(); } ;;
    grep | egrep | fgrep | head | tail | cut | cat | echo | printf | ls | wc | tr | sleep | date | pwd)
      # Read-only with no file redirection, wrapper or substitution: it cannot write a pidfile or
      # move the cwd, so a quiet kill may follow it.
      if [[ $filered == no && $i == 0 && "${args[0]}" == "$c" && -z "$cmd_subs" && $cursub == 0 && $depth == 0 &&
        "$term" =~ ^(\;|nl|\&\&|\|\||\||end)$ ]]; then inert=yes; fi ;;
    gradle | gradlew)
      # --stop stops every compatible daemon on the host, other lanes' running builds included (#318).
      if [[ -n "$lane" && " ${a[*]:-} " == *" --stop "* ]]; then
        lane_deny "$c --stop stops every lane's Gradle daemons: let an idle daemon time out"
      fi ;;
    pkill | killall)
      deny "$c kills by name or pattern: kill only PIDs you recorded at start"
      [[ "$c" != killall ]] || { low=$(tr '[:upper:]' '[:lower:]' <<<"${a[*]:-}"); [[ "$low" != *simulator* ]] || deny "never quit Simulator.app: it shuts down every booted simulator"; } ;;
    kill)
      [[ $via_xargs == no ]] || deny "xargs kill kills whatever a search matched: kill only PIDs you recorded at start"
      for t in "${a[@]:-}"; do [[ "$t" != -1 ]] || deny "kill -1 signals every process you own"; done
      # Signal 0 (kill -0, -s 0, -n 0) and kill -l only probe or list: nothing is signalled. A kill
      # whose every PID is a literal number above 1 was not fed by a search in this command, and
      # silencing it hides only "no such process".
      local probe=no literal=yes nlit=0 sk=no
      for t in "${a[@]:-}"; do
        if [[ $sk == yes ]]; then sk=no; [[ "$t" != 0 ]] || probe=yes; continue; fi
        case "$t" in
          -0 | -l | -L | -l*) probe=yes ;;
          -s | -n) sk=yes ;;
          --) ;;
          -*) ;;
          *) if [[ "$t" =~ ^[0-9]+$ ]] && ((10#$t > 1)); then ((nlit += 1)); else literal=no; fi ;;
        esac
      done
      if [[ $probe == yes && $via_xargs == no ]]; then return 0; fi
      destructive=yes
      if [[ $literal == yes && $nlit -gt 0 && $via_xargs == no ]]; then kill_literal=yes; else saw_kill=yes; fi
      # Only stderr silenced, and every PID argument is one whole substitution: quiet_kill decides.
      if [[ $nredir == 1 && $only_err == yes && $i == 0 && $depth == 0 && $cursub == 0 && $prefix_ok == yes &&
        "$term" =~ ^(\;|nl|\&\&|\|\||end)$ && -n "$cmd_subs" ]]; then
        local npid=0 nsub=0 skip=no
        for t in "${a[@]:-}"; do
          if [[ $skip == yes ]]; then skip=no; continue; fi
          case "$t" in
            -s | -n) skip=yes ;;
            -*) ;;
            '$(...)') ((npid += 1)); ((nsub += 1)) ;;
            *) ((npid += 1)) ;;
          esac
        done
        t=${cmd_subs//[^,]/}
        if ((npid > 0 && npid == nsub && nsub == ${#t} + 1)); then kill_quiet=yes inert=yes; fi
      fi ;;
    pgrep | pidof | lsof) saw_pidsrc=yes ;;
    ps)
      # ps -p/-q PID only reports on PIDs it was given (a check before a kill); any other
      # selection (-A, -a, -e, -x, -u, BSD `aux`, ...) is a process search.
      local bypid=no sel=no
      for ((j = 0; j < n; j++)); do
        t=${a[j]}
        case "$t" in
          -p | -q | --pid) bypid=yes; ((j += 1)) ;;
          -o | -O | --format) ((j += 1)) ;;
          -p[0-9]* | --pid=*) bypid=yes ;;
          -[wfjlcMmrSvhLT]*) [[ "${t#-}" != *[AaexUuGgtNdp]* ]] || sel=yes ;;
          *) sel=yes ;;
        esac
      done
      [[ $bypid == yes && $sel == no ]] || saw_pidsrc=yes ;;
    rm)
      destructive=yes
      local rec=no ends=no files=()
      for t in "${a[@]:-}"; do
        if [[ $ends == no && "$t" == -- ]]; then ends=yes
        elif [[ $ends == no && "$t" == --* ]]; then [[ "$t" != --recursive ]] || rec=yes
        elif [[ $ends == no && "$t" == -?* ]]; then [[ "$t" != *[rR]* ]] || rec=yes
        else files+=("$t"); fi
      done
      if [[ $rec == yes ]]; then
        [[ $via_xargs == no ]] || deny "xargs rm -r deletes paths the hook cannot see; list and delete literal paths"
        for t in "${files[@]:-}"; do [[ -z "$t" ]] || check_delete "$t" "$base" "rm -r"; done
      fi ;;
    find)
      local starts=() del=no
      for t in "${a[@]:-}"; do
        case "$t" in -delete) del=yes ;; esac
      done
      for ((j = 0; j < n; j++)); do
        [[ "${a[j]}" == -exec || "${a[j]}" == -execdir ]] && [[ "${a[j+1]:-}" == rm || "${a[j+1]:-}" == */rm ]] && del=yes
      done
      if [[ $del == yes ]]; then
        destructive=yes
        for t in "${a[@]:-}"; do case "$t" in -* | '!' | '(') break ;; *) starts+=("$t") ;; esac; done
        ((${#starts[@]})) || starts=(.)
        for t in "${starts[@]}"; do check_delete "$t" "$base" "find -delete"; done
      fi ;;
    osascript)
      low=$(tr '[:upper:]' '[:lower:]' <<<"${a[*]:-}")
      if [[ "$low" == *simulator* && ( "$low" == *quit* || "$low" == *kill* || "$low" == *close* ) ]]; then
        deny "never quit Simulator.app: it shuts down every booted simulator; use xcrun simctl on your own device"
      fi ;;
    open)
      low=$(tr '[:upper:]' '[:lower:]' <<<"${a[*]:-}")
      [[ "$low" != *simulator* ]] || deny "never open Simulator.app; boot your own device with xcrun simctl boot <udid>" ;;
    xcrun | simctl)
      local s=("${a[@]:-}")
      [[ "$c" != xcrun ]] || { [[ "${s[0]:-}" == simctl ]] && s=("${s[@]:1}") || s=(); }
      case "${s[0]:-}" in
        shutdown | erase | delete)
          destructive=yes
          for t in "${s[@]:1}"; do [[ "$t" != all ]] || deny "simctl ${s[0]} all touches every simulator: name your own UDID"; done
          # Shutting one named device down loses nothing; silence hides only "already shut down".
          if [[ "${s[0]}" == shutdown && ${#s[@]} == 2 && "${s[1]}" != all && "${s[1]}" != booted && "${s[1]}" != -* ]]; then stop_named=yes; fi ;;
      esac ;;
    adb)
      local hasdev=no
      for ((j = 0; j < n; j++)); do
        [[ "${a[j]}" == -s || "${a[j]}" == -t ]] || continue
        hasdev=yes
      done
      [[ -z "${ANDROID_SERIAL:-}" ]] || hasdev=yes
      [[ " ${a[*]:-} " != *" kill-server "* ]] || deny "adb kill-server drops every lane's devices"
      if [[ " ${a[*]:-} " == *" emu kill "* ]]; then
        destructive=yes
        [[ $hasdev == yes ]] || deny "adb emu kill without -s <serial> may stop another lane's emulator"
        # Stopping one named emulator loses nothing; silence hides only "OK" or "no such device".
        [[ $hasdev == no ]] || stop_named=yes
      fi ;;
    avdmanager) [[ " ${a[*]:-} " != *" delete "* ]] || destructive=yes ;;
    git)
      [[ " ${a[*]:-} " != *" worktree remove "* && " ${a[*]:-} " != *" clean "* ]] || destructive=yes
      ((n == 0)) || check_git "$base" "${a[@]}" ;;
    bash | sh | zsh | dash | ksh)
      for ((j = 0; j < n; j++)); do
        if [[ "${a[j]}" == -*c* && "${a[j]}" != --* ]]; then analyze "${a[j+1]:-}" "$base" $((depth + 1)); break; fi
      done ;;
    eval) analyze "${a[*]:-}" "$base" $((depth + 1)) ;;
    tee)
      for t in "${a[@]:-}"; do [[ "$t" == -* ]] || check_write "$t" "$base" "tee"; done ;;
    touch | truncate)
      for t in "${a[@]:-}"; do [[ "$t" == -* ]] || check_write "$t" "$base" "$c"; done ;;
    cp | mv | install | ln | rsync)
      local last="" tdir="" srcs=()
      for ((j = 0; j < n; j++)); do
        case "${a[j]}" in
          -t) tdir=${a[j+1]:-}; ((j += 1)) ;;
          --target-directory=*) tdir=${a[j]#*=} ;;
          -*) ;;
          *) [[ -z "$last" ]] || srcs+=("$last"); last=${a[j]} ;;
        esac
      done
      if [[ -n "$tdir" ]]; then [[ -z "$last" ]] || srcs+=("$last"); last=$tdir; fi
      if [[ -n "$last" ]] && ! { [[ $c == cp ]] && local_props "$last" "$base" "${srcs[@]:-}"; }; then
        check_write "$last" "$base" "$c"
      fi ;;
    dd)
      for t in "${a[@]:-}"; do [[ "$t" != of=* ]] || check_write "${t#of=}" "$base" "dd"; done ;;
    sed | gsed | perl)
      local inplace=no script=no
      for t in "${a[@]:-}"; do case "$t" in -i* | -pi* | -[a-z]*i*) inplace=yes ;; esac; done
      if [[ $inplace == yes ]]; then
        for ((j = 0; j < n; j++)); do
          t=${a[j]}
          case "$t" in
            -e | -f | --expression | --file) script=yes; ((j += 1)) ;;
            # BSD sed -i '' (an empty backup suffix): the empty word is the suffix, not the script.
            -i) [[ -n "${a[j+1]-x}" ]] || ((j += 1)) ;;
            -*) ;;
            *) if [[ $script == no ]]; then script=yes; else check_write "$t" "$base" "$c -i"; fi ;;
          esac
        done
      fi ;;
  esac
  if [[ "$c" =~ ^(rm|kill|avdmanager|git|xcrun|simctl|adb|find)$ && $destructive == yes ]]; then
    if [[ "$term" == "&" ]]; then ask "backgrounded destructive command ($c ...): run it in the foreground and read its output"
    elif [[ $silenced == yes && $kill_literal == yes ]]; then :
    elif [[ $silenced == yes && $kill_quiet == yes ]]; then quiet_kills+=("$base"$'\036'"$cmd_subs")
    elif [[ $silenced == yes && $stop_named == yes ]]; then :
    elif [[ $silenced == yes ]]; then ask "silenced destructive command ($c ... >/dev/null): let its output show"; fi
  fi
  destructive=no
}

if [[ "$tool" == Bash ]]; then
  analyze "$cmd" "$cwd"
elif t=$(expand "$cmd" "$cwd") && f=$(forbidden "$t"); then
  deny "$tool $cmd: $(forbid_why "$t" "$f")"
fi

decision="" reason=""
if [[ -n "$denies" ]]; then decision=deny reason="lane safety (lane-safety.md): $denies"
elif [[ -n "$asks" ]]; then decision=ask reason="lane safety (lane-safety.md): $asks"; fi
[[ -n "$decision" ]] || exit 0
jq -cn --arg d "$decision" --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
