#!/usr/bin/env bash
# PreToolUse hook enforcing the lane safety contract (skills/orchestrate/lane-safety.md) on Bash
# tool calls. Wired by hooks/hooks.json; reads the hook's JSON payload on stdin.
#
# Usage: lane-safety.sh < payload.json        (payload: {"tool_name","tool_input":{"command"},"cwd"})
# Denied everywhere: rm -r / find -delete on a protected root (/, $HOME, ~/Library, ~/.gradle,
#   ~/.android, the Android SDK, system dirs, $WAAAGH_PROTECTED_PATHS) or on an ancestor of one;
#   pkill, killall, xargs kill, kill fed by pgrep/pidof/lsof/ps; adb kill-server, adb emu kill
#   without -s; quitting, killing or opening Simulator.app; simctl shutdown/erase/delete all.
# Also denied in a lane (cwd in a linked git worktree, or $WAAAGH_LANE_ROOT set): rm -r targets
#   outside the lane root and temp dirs (or the lane root itself), rm -r targets built from a
#   variable the hook cannot expand, and shell writes (>, >>, tee, cp, mv, sed -i, dd of=, ...)
#   that resolve outside the lane root, temp dirs, the state dir and $WAAAGH_LANE_ALLOW (temp dirs:
#   $WAAAGH_LANE_TEMP, default /tmp:/private/tmp:/var/folders:$TMPDIR; lists are colon-separated).
# Asked (flagged for review): a destructive command that is backgrounded (&) or silenced
#   (output to /dev/null), even when its path looks safe.
# Output: nothing (allow; the normal permission flow continues) or one hookSpecificOutput JSON
#   object with permissionDecision deny|ask and the reason. WAAAGH_LANE_SAFETY=off disables it.
# Exit: 0 decided (or not a Bash call); 1 cannot run (no jq, unreadable payload; non-blocking);
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
[[ "$tool" == Bash ]] || exit 0
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
cwd=$(jq -r '.cwd // empty' <<<"$payload")
[[ -n "$cwd" ]] || cwd=$PWD
[[ -n "$cmd" ]] || exit 0

home=${HOME:-/nonexistent}
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

denies="" asks=""
deny() { denies="${denies:+$denies; }$1"; }
ask() { asks="${asks:+$asks; }$1"; }

# check_delete WORD BASE WHAT: a recursive deletion target.
check_delete() {
  local w=$1 base=$2 what=$3 t glob=no prefix="" r
  if ! t=$(expand "$w" "$base"); then
    [[ -z "$lane" ]] || deny "$what $w: path built from a variable; expand and echo the literal path first"
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
  [[ -n "$lane" ]] || return 0
  if [[ $glob == no && "$t" == "$lane" ]]; then deny "$what $w: that is the lane worktree itself; use git worktree remove"; return 0; fi
  if [[ $glob == no ]]; then
    local a ok=no
    for a in "${allowed[@]}"; do [[ "$t" == "$a"/* ]] && ok=yes; done
    [[ $ok == yes ]] || deny "$what $w: outside the lane worktree $lane and temp dirs"
  else
    in_allowed "$t" || deny "$what $w: outside the lane worktree $lane and temp dirs"
  fi
}
# check_write WORD BASE WHAT: a file a shell command writes (lane mode only).
check_write() {
  [[ -n "$lane" ]] || return 0
  local w=$1 base=$2 what=$3 t
  case "$w" in /dev/null | /dev/stdout | /dev/stderr | /dev/tty | /dev/fd/* | "") return 0 ;; esac
  t=$(expand "$w" "$base") || return 0
  in_allowed "$t" || deny "$what $w: writes outside the lane worktree $lane; enter the worktree (EnterWorktree) and use the edit tools"
}

# --- tokenizer ----------------------------------------------------------------------------------
# One line per simple command: "<terminator>\036<tok>\037<tok>...". Operator tokens start with \002.
# Command substitutions ($(...), `...`) leave "$(...)" in the word and are emitted as their own
# commands; heredoc bodies and comments are skipped.
tokenize() {
  awk -v US="$US" -v OP="$OP" '
  function flush() { if (have) { toks = toks (ntok ? US : "") word; ntok++; word = ""; have = 0 } }
  function emit(term) { flush(); if (ntok) print term "\036" toks; toks = ""; ntok = 0 }
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
    subs[++nsubs] = body
    return i
  }
  function scan(s,   i, c, n, n2, sq, dq, hd, line, k, j, delim, strip) {
    sq = 0; dq = 0; word = ""; have = 0; toks = ""; ntok = 0; nhd = 0; wantdelim = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1); n = substr(s, i + 1, 1); n2 = substr(s, i + 2, 1)
      if (sq) { if (c == "\047") sq = 0; else word = word c; continue }
      if (dq) {
        if (c == "\"") { dq = 0; continue }
        if (c == "\\" && (n == "\"" || n == "\\" || n == "$" || n == "`")) { word = word n; i++; continue }
        if (c == "$" && n == "(") { i = grab(s, i + 2, ")"); word = word "$(...)"; continue }
        if (c == "`") { i = grab(s, i + 1, "`"); word = word "$(...)"; continue }
        word = word c; continue
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
      if (c == "(" || c == ")") { emit("sub"); continue }
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
    for (q = 1; q <= nsubs; q++) scan(subs[q])
  }'
}

# --- analysis -----------------------------------------------------------------------------------
# analyze TEXT BASE [DEPTH]: every simple command in TEXT; a cd changes the base (cur) for the
# commands after it. saw_kill/saw_pidsrc/cur are read and set by analyze_simple (dynamic scope).
destructive=no
analyze() {
  local text=$1 cur=$2 depth=${3:-0} line term rest toks
  local saw_kill=no saw_pidsrc=no
  ((depth < 4)) || return 0
  while IFS= read -r line; do
    term=${line%%$'\036'*} rest=${line#*$'\036'}
    IFS=$US read -r -a toks <<<"$rest"
    ((${#toks[@]})) || continue
    analyze_simple "$term" "$cur" "$depth" "${toks[@]}"
  done < <(tokenize <<<"$text")
  if [[ $saw_kill == yes && $saw_pidsrc == yes ]]; then
    deny "kill fed by a process search (pgrep/pidof/lsof/ps): kill only PIDs you recorded at start"
  fi
}

analyze_simple() {
  local term=$1 base=$2 depth=$3; shift 3
  local args=() t i via_xargs=no silenced=no
  # split redirections from words
  while (($#)); do
    t=$1; shift
    if [[ "$t" == "$OP"* ]]; then
      t=${t#"$OP"}
      local target=${1:-}
      (($#)) && shift
      case "$t" in
        *'>&') [[ "$target" =~ ^[0-9-]+$ ]] || check_write "$target" "$base" "redirect" ;;
        *'>' | *'>|')
          if [[ "$target" == /dev/null ]]; then silenced=yes; else check_write "$target" "$base" "redirect"; fi ;;
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
      command | builtin | exec | nohup | time | noglob | '{' | '}' | '!' | then | do | else | elif | if | while | until | caffeinate) ((i += 1)) ;;
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
  ((i < ${#args[@]})) || return 0
  local c=${args[i]##*/}
  local a=("${args[@]:i+1}")
  local n=${#a[@]} low j

  case "$c" in
    cd)
      if ((n == 0)); then cur=$home; elif [[ "${a[0]}" != - ]]; then
        cur=$(expand "${a[0]}" "$base") || cur=$base
      fi ;;
    pkill | killall)
      deny "$c kills by name or pattern: kill only PIDs you recorded at start"
      [[ "$c" != killall ]] || { low=$(tr '[:upper:]' '[:lower:]' <<<"${a[*]:-}"); [[ "$low" != *simulator* ]] || deny "never quit Simulator.app: it shuts down every booted simulator"; } ;;
    kill)
      destructive=yes
      [[ $via_xargs == no ]] || deny "xargs kill kills whatever a search matched: kill only PIDs you recorded at start"
      saw_kill=yes
      for t in "${a[@]:-}"; do [[ "$t" != -1 ]] || deny "kill -1 signals every process you own"; done ;;
    pgrep | pidof | lsof | ps) saw_pidsrc=yes ;;
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
          for t in "${s[@]:1}"; do [[ "$t" != all ]] || deny "simctl ${s[0]} all touches every simulator: name your own UDID"; done ;;
      esac ;;
    adb)
      local hasdev=no
      for t in "${a[@]:-}"; do [[ "$t" != -s && "$t" != -t ]] || hasdev=yes; done
      [[ -z "${ANDROID_SERIAL:-}" ]] || hasdev=yes
      [[ " ${a[*]:-} " != *" kill-server "* ]] || deny "adb kill-server drops every lane's devices"
      if [[ " ${a[*]:-} " == *" emu kill "* ]]; then
        destructive=yes
        [[ $hasdev == yes ]] || deny "adb emu kill without -s <serial> may stop another lane's emulator"
      fi ;;
    avdmanager) [[ " ${a[*]:-} " != *" delete "* ]] || destructive=yes ;;
    git)
      [[ " ${a[*]:-} " != *" worktree remove "* && " ${a[*]:-} " != *" clean "* ]] || destructive=yes ;;
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
      local last="" tdir=""
      for ((j = 0; j < n; j++)); do
        case "${a[j]}" in -t) tdir=${a[j+1]:-}; ((j += 1)) ;; --target-directory=*) tdir=${a[j]#*=} ;; -*) ;; *) last=${a[j]} ;; esac
      done
      [[ -n "$tdir" ]] && last=$tdir
      [[ -z "$last" ]] || check_write "$last" "$base" "$c" ;;
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
            -*) ;;
            *) if [[ $script == no ]]; then script=yes; else check_write "$t" "$base" "$c -i"; fi ;;
          esac
        done
      fi ;;
  esac
  if [[ "$c" =~ ^(rm|kill|avdmanager|git|xcrun|simctl|adb|find)$ && $destructive == yes ]]; then
    if [[ "$term" == "&" ]]; then ask "backgrounded destructive command ($c ...): run it in the foreground and read its output"
    elif [[ $silenced == yes ]]; then ask "silenced destructive command ($c ... >/dev/null): let its output show"; fi
  fi
  destructive=no
}

analyze "$cmd" "$cwd"

decision="" reason=""
if [[ -n "$denies" ]]; then decision=deny reason="lane safety (lane-safety.md): $denies"
elif [[ -n "$asks" ]]; then decision=ask reason="lane safety (lane-safety.md): $asks"; fi
[[ -n "$decision" ]] || exit 0
jq -cn --arg d "$decision" --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
