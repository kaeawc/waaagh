#!/usr/bin/env bash
# PreToolUse hook enforcing the lane safety contract (skills/orchestrate/lane-safety.md) on Bash
# tool calls. Wired by hooks/hooks.json; reads the hook's JSON payload on stdin.
#
# Usage: lane-safety.sh < payload.json        (payload: {"tool_name","tool_input":{"command"},"cwd"})
# Denied everywhere: rm -r / find -delete on a protected root (/, $HOME, ~/Library, ~/.gradle,
#   ~/.android, the Android SDK, system dirs, $WAAAGH_PROTECTED_PATHS) or on an ancestor of one; rm
#   without -r and unlink on a protected root itself (a file below one is judged as a write);
#   pkill, killall, xargs kill, kill fed by pgrep/pidof/lsof/ps; adb kill-server, adb emu kill
#   without -s; quitting, killing or opening Simulator.app; simctl shutdown/erase/delete all.
# Also denied in a lane (cwd in a linked git worktree, or $WAAAGH_LANE_ROOT set): gradle --stop
#   (it stops every lane's daemons), rm -r targets
#   outside the lane root and temp dirs (or the lane root itself), rm -r targets built from a
#   variable the hook cannot expand, and shell writes (>, >>, tee, cp, mv, sed -i, dd of=, ...)
#   that resolve outside the lane root, temp dirs, the state dir and $WAAAGH_LANE_ALLOW (temp dirs:
#   $WAAAGH_LANE_TEMP, default /tmp:/private/tmp:/var/folders:$TMPDIR; lists are colon-separated),
#   or whose real target through a symlink does (anything under /dev aside); rm without -r and
#   unlink of an entry out of those bounds; ln whose link or target (a symlink's relative target
#   from the link's directory) is out of them (#384). A glob in any path part is expanded and every
#   match judged; over 100 matches in one command is too many to judge (#384). A brace expansion
#   ({a,b}, {1..3}) is judged word by word, a glob in a cd target by its one match; a glob with
#   more than 2 globbed path parts, unquoted zsh glob syntax (( ), ^, **/, # after a glob character,
#   ~ past the start), a brace around an unknown variable or beside a quoted brace or comma, and a
#   word over 4096 characters or 64 braces are refused unexpanded (#387; asked outside a lane).
#   A check undecided after 6 seconds fails closed (#388): denied in a known lane or for a
#   subagent's call, asked elsewhere, before the hook's 10-second timeout lets the call through.
#   Denied only in a known lane (payload agent_id, $WAAAGH_LANE_ROOT, or an active lanes.tsv row
#   under the state root); in any other linked worktree, the owner's own session, they ask.
# Forbidden roots (#218): the orchestrator's own checkout, from $WAAAGH_LANE_FORBID (colon list) and
#   <state root>/lane-forbidden (one absolute path per line; # comments; state root:
#   $ORCHESTRATE_STATE_DIR, default ~/.claude/orchestrate). They bind a subagent's calls (payload
#   agent_id) and a lane session whose worktree is not itself forbidden, never the orchestrator's
#   own calls. Bound: denied are shell writes and ln targets, rm, unlink, find -delete, mutating git (checkout, switch,
#   reset, pull, merge, rebase, commit, stash, restore, apply, am, cherry-pick, revert, clean, add,
#   rm, mv, branch -d/-m/-c/-f, worktree remove/move) and Edit/Write/MultiEdit/NotebookEdit under a forbidden root,
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

# lane_main: every check below, run in a worker process under the deadline at the end of this file.
lane_main() {
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
# Quote marks (#387 review): the tokenizer strips quotes, and spells each quoted or escaped
# { } , ( ) # ^ ~ * as its own control byte (MK, in that order), so brace and zsh glob checks see
# only the characters the shell would expand. unmark S sets um to S spelled back; a path is unmarked
# before it is resolved (subst_word), a bash -c or eval body before it is tokenized again (analyze),
# and the decision's reason before it is printed.
MK=$'\021\022\023\024\025\026\027\030\031' MKB=$'\021\022\023'
um=""
unmark() {
  local s=$1 c='{' d='}' e=',' f='(' g=')' h='#' i='^' j='~' k='*'
  case "$s" in *[$MK]*) ;; *) um=$s; return 0 ;; esac
  s=${s//$'\021'/$c} s=${s//$'\022'/$d} s=${s//$'\023'/$e} s=${s//$'\024'/$f} s=${s//$'\025'/$g}
  s=${s//$'\026'/$h} s=${s//$'\027'/$i} s=${s//$'\030'/$j} s=${s//$'\031'/$k}
  um=$s
}

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
# resolve ABS: ABS normalised the way the OS walks it, left to right (#380): a `..` after a
# directory that is or runs through a symlink climbs from that directory's physical path (with
# `<lane>/sl -> <checkout>/sub`, `<lane>/sl/../f` is `<checkout>/f`, not `<lane>/f`). The spelling
# stays lexical wherever both walks reach the same directory (/var vs /private/var on macOS).
resolve() {
  case "$1" in *..*) ;; *) norm "$1"; return 0 ;; esac
  local p=$1 out="" part lex q linked=no
  local IFS=/
  # shellcheck disable=SC2086
  set -f; set -- $p; set +f
  for part in "$@"; do
    case "$part" in
      "" | .) ;;
      ..)
        lex=${out%/*}
        # No symlink along OUT: its physical parent is its lexical one, no need to ask the OS.
        if [[ $linked == yes && -n "$out" && -d "$out" ]] && q=$(cd -P "$out/.." 2>/dev/null && pwd -P) &&
          [[ "$q" != "$(phys "${lex:-/}")" ]]; then out=${q%/} linked=no
        else out=$lex; fi ;;
      *) out="$out/$part"; [[ ! -L "$out" ]] || linked=yes ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}
# expand WORD BASE [lex]: prints an absolute path, or returns 1 when the word holds a variable or a
# command substitution the hook cannot expand. A file operand resolves as the OS walks it (resolve);
# with lex, a `cd` target normalises lexically, as the shell's logical cd applies `..` to its
# logical cwd (with `<lane>/esc -> /tmp/a/b`, `cd esc/../..` lands above the lane, not in /tmp).
expand() {
  local mode=${3:-} w
  subst_word "$1" "$2" || return 1
  w=$sw
  [[ "$w" == /* ]] || w="$2/$w"
  if [[ "$mode" == lex ]]; then norm "$w"; else resolve "$w"; fi
}
# subst_word WORD BASE: sets sw to WORD with ~, $HOME, $PWD (BASE) and $TMPDIR spelled out, still
# relative when WORD is; returns 1 when another variable or a command substitution remains.
sw=""
subst_word() {
  local w base=$2
  unmark "$1"; w=$um
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
  sw=$w
}
# Globs (#384). The shell expands a glob before the command runs, so a glob in a middle path part
# (`rm -rf <lane>/*/.ssh`, `echo x > <nest>/s*/../README`) reaches whatever it matches through, not
# the literal text. globbed WORD: WORD holds a glob character. deep_glob WORD: one sits before a
# later `/` (a final part's glob is judged by the directory it lists, check_delete). At most
# glob_max matches (and brace words) are judged in the whole command (each costs a few forks): more
# is too many. A timed-out PreToolUse hook does not block (hooks.json gives it 10 seconds), so the
# expansion is bounded before it runs (#387 review): the literal word is judged first and a word
# already refused is never expanded; a word with more than glob_parts_max globbed path parts is
# refused unexpanded (`/System/*/*/*/*/*/*/*/x` walks the disk for minutes); and once the hook has
# run hook_budget seconds ($SECONDS), what is left to expand or judge is refused.
glob_max=100 glob_left=100 glob_parts_max=2 hook_budget=3
globbed() { [[ "$1" == *[*?[]* ]]; }
deep_glob() { local x=${1#*[*?[]}; [[ "$1" != "$x" && "$x" == */* ]]; }
over_time() { ((SECONDS >= hook_budget)); }
# glob_refuse LABEL WHY: a word the hook cannot judge path by path: denied in a lane, asked elsewhere.
glob_refuse() {
  if [[ -n "$lane" ]]; then lane_deny "$1: $2"; else ask "$1: $2"; fi
}
# glob_parts WORD: sets gp to the number of WORD's path parts holding a glob character.
gp=0
glob_parts() {
  local part IFS=/
  gp=0
  set -f
  # shellcheck disable=SC2086
  for part in $1; do [[ "$part" != *[*?[]* ]] || gp=$((gp + 1)); done
  set +f
}
# glob_expand WORD BASE LABEL: glob_words WORD BASE within the bounds above; returns 1 after refusing
# LABEL (too many globbed parts, out of time, too many matches).
glob_expand() {
  glob_parts "$1"
  if ((gp > glob_parts_max)); then
    glob_refuse "$3" "glob too deep to check ($gp globbed path parts, over $glob_parts_max); name the paths"; return 1
  fi
  if over_time; then glob_refuse "$3" "glob left unexpanded: the hook ran out of time; name the paths"; return 1; fi
  glob_words "$1" "$2"
  if ((glob_left < 0)); then too_many "$3"; return 1; fi
  return 0
}
# zsh_glob WORD [braces]: WORD (a write, delete, ln or cd operand) holds unquoted glob syntax bash
# does not expand the way the user's zsh does (#387 review): a ( ) group (`h(m|x)`, `(hm)`,
# qualifiers, extglob; the tokenizer keeps a `(` that continues an argument word), `^`, a recursive
# `**/`, a `#` after a glob character (`*#`, extended_glob), or a `~` anywhere but a leading `~` or
# `~/` (`*~*.c`, `~user`). Quoted characters are marked (MK), so they never count (`'out/a (1).txt'`).
# A lone `#` is literal (extended_glob is off by default: `out/b#1`), and so is one in `${...}`
# (`${HOME#/}`); `**` not before a `/` is `*` in both shells (`out/**` is judged as `out/*`); a
# trailing `~` (a backup file, `rm -f *~`) is no glob. With braces, the `~` test waits for each
# brace word (`{~,zz}` is `~` and `zz`).
zsh_glob() {
  local w=${1//'$(...)'/} r p
  while [[ "$w" == *'${'*'}'* ]]; do p=${w%%'${'*} r=${w#*'${'} r=${r#*\}} w=$p$r; done
  case "$w" in *'('* | *')'* | *'^'* | *'**/'* | *[]*?]'#'*) return 0 ;; esac
  [[ "${2:-}" != braces ]] || return 1
  r=$w
  case "$r" in "~" | \~/*) r=${r#\~} ;; esac
  [[ "$r" == *'~'?* ]]
}
# Brace expansion (#387 review). The shell expands `{a,b}` and `{x..y[..step]}` before globbing and
# tilde expansion, so `rm -rf {~,zz}` removes $HOME. brace_words WORD: sets bw to WORD's brace
# expansion, done here by the same rule as bash (the leftmost `{` whose matching `}` holds a
# top-level comma or a sequence, repeated until none is left), so nothing is executed; returns 1
# when WORD has none, 2 when it makes more than glob_max words, 3 when the hook runs out of time.
# pre_words bounds the work first: a word over word_max characters or with over brace_max `{` is
# refused unexpanded (`{{{...` thousands deep made the split quadratic past the hook's timeout).
word_max=4096 brace_max=64
bw=() bs_pre="" bs_post="" bs_alts=()
brace_words() {
  local q=("$1") k=0 w a found=no rc
  bw=()
  while ((k < ${#q[@]})); do
    if over_time; then return 3; fi
    w=${q[k]}; k=$((k + 1))
    rc=0
    brace_split "$w" || rc=$?
    if ((rc == 0)); then
      found=yes
      for a in "${bs_alts[@]}"; do q+=("$bs_pre$a$bs_post"); done
      ((${#q[@]} - k + ${#bw[@]} <= glob_max)) || return 2
    elif ((rc == 3)); then return 3
    else bw+=("$w"); fi
  done
  [[ $found == yes ]] || return 1
}
# brace_split WORD: sets bs_pre, bs_alts and bs_post for WORD's leftmost brace expression; returns 1
# when it has none, 3 when the hook runs out of time. One pass pairs each `{` with its `}` on a stack
# and keeps the leftmost pair holding a top-level comma or a sequence, so a deep or unmatched nest
# costs one walk of the word, not one per `{`.
brace_split() {
  local w=$1 n=${#1} j c top=0 op=() cm=() i p start best=-1 alts=()
  for ((j = 0; j < n; j++)); do
    if ((!(j & 1023))) && over_time; then return 3; fi
    c=${w:j:1}
    if [[ "$c" == "{" ]]; then op[top]=$j cm[top]=""; top=$((top + 1))
    elif [[ "$c" == , ]]; then ((top == 0)) || cm[top - 1]="${cm[top - 1]} $j"
    elif [[ "$c" == "}" ]] && ((top)); then
      top=$((top - 1)) i=${op[top]}
      ((best < 0 || i < best)) || continue
      if [[ -n "${cm[top]}" ]]; then
        alts=() start=$((i + 1))
        for p in ${cm[top]}; do alts+=("${w:start:p-start}"); start=$((p + 1)); done
        alts+=("${w:start:j-start}")
      else
        bs_alts=()
        brace_seq "${w:i+1:j-i-1}" || continue
        alts=("${bs_alts[@]}")
      fi
      best=$i bs_pre=${w:0:i} bs_post=${w:j+1}
    fi
  done
  ((best >= 0)) || return 1
  bs_alts=("${alts[@]}")
}
# brace_seq BODY: sets bs_alts to the sequence {BODY} makes (integers, zero-padded when either end
# is, or single letters; an optional step), at most glob_max + 1 of them; returns 1 when BODY is no
# sequence. No subshells: printf -v, so a long sequence costs no forks.
brace_seq() {
  local x y s=1 width=0 v cx cy pv
  if [[ "$1" =~ ^(-?[0-9]+)\.\.(-?[0-9]+)(\.\.(-?[0-9]+))?$ ]]; then
    x=${BASH_REMATCH[1]} y=${BASH_REMATCH[2]}
    [[ -z "${BASH_REMATCH[4]}" ]] || s=${BASH_REMATCH[4]#-}
    # Ends too long for shell arithmetic make more words than the hook judges.
    if ((${#x} > 9 || ${#y} > 9 || ${#s} > 9)); then
      for ((v = 0; v <= glob_max; v++)); do bs_alts+=("$v"); done
      return 0
    fi
    [[ "$x" != 0?* && "$x" != -0?* && "$y" != 0?* && "$y" != -0?* ]] || width=$((${#x} > ${#y} ? ${#x} : ${#y}))
    dec x "$x"; dec y "$y"; s=$((10#$s)); ((s > 0)) || s=1
    v=$x
    while ((${#bs_alts[@]} <= glob_max)); do
      if ((width)); then printf -v pv '%0*d' "$width" "$v"; bs_alts+=("$pv"); else bs_alts+=("$v"); fi
      if ((x <= y)); then v=$((v + s)); ((v <= y)) || break
      else v=$((v - s)); ((v >= y)) || break; fi
    done
    return 0
  fi
  if [[ "$1" =~ ^([A-Za-z])\.\.([A-Za-z])(\.\.(-?[0-9]+))?$ ]]; then
    printf -v cx '%d' "'${BASH_REMATCH[1]}"
    printf -v cy '%d' "'${BASH_REMATCH[2]}"
    [[ -z "${BASH_REMATCH[4]}" ]] || s=${BASH_REMATCH[4]#-}
    ((${#s} <= 9)) || s=1
    s=$((10#$s)); ((s > 0)) || s=1
    v=$cx
    while ((${#bs_alts[@]} <= glob_max)); do
      printf -v pv '%03o' "$v"
      # shellcheck disable=SC2059
      printf -v pv "\\$pv"
      bs_alts+=("$pv")
      if ((cx <= cy)); then v=$((v + s)); ((v <= cy)) || break
      else v=$((v - s)); ((v >= cy)) || break; fi
    done
    return 0
  fi
  return 1
}
# dec VAR N: sets VAR to the signed decimal N, leading zeros read as decimal.
dec() { local n=$2 sg=""; [[ "$n" != -* ]] || { sg=-; n=${n#-}; }; printf -v "$1" '%s' "$sg$((10#$n))"; }
# pre_words WORD BASE LABEL: the shell's own expansions judged before WORD's path (#387 review): a
# zsh glob is refused; a brace expansion sets bw to its words, taken from glob_left (returns 0: judge
# each word instead of WORD); one around a variable the hook cannot spell out, making too many
# words, beside a quoted or escaped brace or comma (`{hm/.ssh,'{'}`: bash keeps the quoted `{`
# literal, so the hook's own split would differ), or in a word over word_max characters or brace_max
# braces, is refused. Returns 1 to go on with WORD itself, 2 after refusing.
pre_words() {
  local w=$1 rc=0 zsh="zsh glob syntax the hook cannot expand faithfully; name the paths" lb=$3 t
  ((${#lb} <= 200)) || lb="${lb:0:200}..."
  if ((${#w} > word_max)); then glob_refuse "$lb" "word too long to check (over $word_max characters); name the paths"; return 2; fi
  if [[ "$w" != *'{'*'}'* ]]; then
    if zsh_glob "$w"; then glob_refuse "$lb" "$zsh"; return 2; fi
    return 1
  fi
  t=${w//[!\{]/}
  if ((${#t} > brace_max)); then glob_refuse "$lb" "too many braces to check (over $brace_max in one word); name the paths"; return 2; fi
  if [[ "$w" == *[$MKB]* ]]; then glob_refuse "$lb" "quoted brace in a brace expansion; name the paths"; return 2; fi
  if zsh_glob "$w" braces; then glob_refuse "$lb" "$zsh"; return 2; fi
  case "$w" in
    *'$'* | *'`'*)
      if subst_word "$w" "$2"; then w=$sw
      else
        brace_words "$w" || rc=$?
        if ((rc == 1)); then
          if zsh_glob "$w"; then glob_refuse "$lb" "$zsh"; return 2; fi
          return 1
        fi
        glob_refuse "$lb" "brace expansion around a variable or command substitution; expand it and name the paths"; return 2
      fi ;;
  esac
  brace_words "$w" || rc=$?
  if ((rc == 1)); then
    if zsh_glob "$1"; then glob_refuse "$lb" "$zsh"; return 2; fi
    return 1
  fi
  if ((rc == 3)); then glob_refuse "$lb" "brace expansion left unexpanded: the hook ran out of time; name the paths"; return 2; fi
  if ((rc == 0)); then glob_left=$((glob_left - ${#bw[@]})); fi
  if ((rc != 0 || glob_left < 0)); then glob_refuse "$lb" "brace expansion makes too many paths (over $glob_max); name them"; return 2; fi
  return 0
}
# glob_words WORD BASE: sets gw to the words the shell's own globbing makes of WORD (variables
# already spelled out) from the logical cwd BASE (nullglob), at most glob_max + 1 of them, and
# takes them from glob_left; below zero, the command's globs match too many paths.
gw=()
glob_words() {
  local m
  gw=()
  while IFS= read -r -d '' m; do gw+=("$m"); done < <(glob_list "$1" "$2")
  glob_left=$((glob_left - ${#gw[@]}))
}
glob_list() {
  (
    if [[ "$1" != /* ]]; then cd "$2" 2>/dev/null || exit 0; fi
    shopt -s nullglob; set +f
    IFS="" n=0
    # shellcheck disable=SC2086
    for m in $1; do
      printf '%s\0' "$m"; n=$((n + 1)); ((n <= glob_max)) || break
    done
  )
}
# too_many LABEL: a glob matched more paths than the hook judges.
too_many() { glob_refuse "$1" "glob matches too many paths (over $glob_max); name them"; }
# cwd_lost: set (to the command, e.g. `popd`) once the hook cannot know the shell's directory for
# the rest of the command line (popd, pushd other than `pushd DIR`, cd -, cd given both -L and -P);
# a later `cd ABS` clears it. While set, a relative write, delete or git work tree is denied: the
# hook cannot say where it lands.
cwd_lost=""
# lost_rel WORD: cwd_lost is set and WORD names a path relative to the cwd ($PWD counts; ~, $HOME
# and $TMPDIR do not; a word holding any other variable is left to the usual checks).
lost_rel() {
  [[ -n "$cwd_lost" ]] || return 1
  case "$1" in
    "~" | \~/* | '$HOME' | '${HOME}' | '$HOME/'* | '${HOME}/'*) return 1 ;;
    '$PWD' | '${PWD}' | '$PWD/'* | '${PWD}/'*) return 0 ;;
  esac
  if [[ -n "${TMPDIR:-}" ]]; then
    case "$1" in '$TMPDIR' | '${TMPDIR}' | '$TMPDIR/'* | '${TMPDIR}/'*) return 1 ;; esac
  fi
  case "$1" in *'$'* | *'`'* | /*) return 1 ;; esac
  return 0
}
lost_why() { printf '%s' "the working directory is unknown after \`$cwd_lost\`; use an absolute path"; }
# inside A B: A is B or below it.
inside() { [[ "$1" == "$2" || "$2" == / || "$1" == "$2"/* ]]; }
# phys ABS: ABS with its nearest existing directory resolved to its physical path (pwd -P), so a
# path spelled through a symlink (/var/... vs /private/var/... on macOS) compares with one git or
# pwd -P printed; ABS itself when nothing along it resolves.
phys() {
  local d=$1 rest="" p
  while [[ ! -d "$d" && "$d" == /*/* ]]; do rest="/${d##*/}$rest"; d=${d%/*}; done
  if p=$(cd "$d" 2>/dev/null && pwd -P); then norm "$p$rest"; else printf '%s\n' "$1"; fi
}
# real ABS: phys ABS with a symlink at ABS itself followed too, dangling or not (a write through
# `<lane>/f -> <checkout>/f` lands at its target), up to 40 links deep; a `..` in a link's target
# resolves as the OS walks it (resolve).
real() {
  local t=$1 l n=0
  while [[ -L "$t" ]] && ((n++ < 40)); do
    l=$(readlink "$t") || break
    [[ "$l" == /* ]] || l="$(phys "${t%/*}")/$l"
    t=$(resolve "$l")
  done
  phys "$t"
}
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

# logical_top TOP DIR: TOP, a physical path git printed, as spelled along DIR, a path at or below
# it that may run through a symlink (macOS: /var/... is /private/var/..., /tmp is /private/tmp),
# so it compares with the paths the command and cwd spell; TOP itself when DIR does not reach it.
logical_top() {
  local top d=$2 p
  top=$(norm "$1")
  while [[ "$d" == /* ]]; do
    p=$(cd "$d" 2>/dev/null && pwd -P) || break
    if [[ "$p" == "$top" ]]; then printf '%s\n' "$d"; return 0; fi
    [[ "$p" == "$top"/* && "$d" == /*/* ]] || break
    d=${d%/*}
  done
  printf '%s\n' "$top"
}
# Lane mode: the lane root is the linked worktree holding cwd (or $WAAAGH_LANE_ROOT), spelled as
# cwd spells it; lane_phys is its physical path (what git prints), allowed as well.
lane=${WAAAGH_LANE_ROOT:-} lane_phys=""
if [[ -z "$lane" ]] && command -v git >/dev/null 2>&1; then
  gd=$(git -C "$cwd" rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel 2>/dev/null || true)
  if [[ -n "$gd" ]]; then
    g1=$(sed -n 1p <<<"$gd") g2=$(sed -n 2p <<<"$gd") top=$(sed -n 3p <<<"$gd")
    if [[ "$g1" != "$g2" && -n "$top" ]]; then
      lane_phys=$(norm "$top")
      lane=$(logical_top "$top" "$(norm "$cwd")")
    fi
  fi
fi
[[ -z "$lane" ]] || lane=$(norm "$lane")
[[ -n "$lane_phys" ]] || lane_phys=$lane
allowed=()
if [[ -n "$lane" ]]; then
  allowed=("$lane" "${ORCHESTRATE_STATE_DIR:-$home/.claude/orchestrate}")
  [[ "$lane_phys" == "$lane" ]] || allowed+=("$lane_phys")
  temps=${WAAAGH_LANE_TEMP-/tmp:/private/tmp:/var/folders${TMPDIR:+:$TMPDIR}}
  if [[ -n "$temps${WAAAGH_LANE_ALLOW:-}" ]]; then
    IFS=: read -r -a extra <<<"$temps:${WAAAGH_LANE_ALLOW:-}"
    for v in "${extra[@]}"; do [[ -z "$v" ]] || allowed+=("$(norm "$v")"); done
  fi
fi
in_allowed() { local a; for a in "${allowed[@]}"; do inside "$1" "$a" && return 0; done; return 1; }
# allowed_p: each configured root (state, temp, WAAAGH_LANE_ALLOW) by its physical path, used only to
# judge the physical path a deletion reaches (del_ok, #380), never writes. A root whose physical path
# is /, $HOME or a system root (exacts), or holds one, is left out: a link to /Users must not let
# `rm -rf /Users/Shared/x` through.
allowed_p=() exacts_pp=()
if ((${#allowed[@]} > 1)); then
  for v in "${allowed[@]:1}"; do
    [[ "$v" != "$lane_phys" ]] || continue
    p=$(phys "$v")
    [[ "$p" != "$v" && "$p" != / ]] || continue
    if ((${#exacts_pp[@]} == 0)); then
      for r in "${exacts[@]}"; do exacts_pp+=("$r" "$(phys "$r")"); done
    fi
    for r in "${exacts_pp[@]}"; do inside "$r" "$p" && continue 2; done
    allowed_p+=("$p")
  done
fi
# The lane's own physical root ($WAAAGH_LANE_ROOT may spell it through /var or another link).
if [[ -n "$lane" ]]; then
  p=$(phys "$lane_phys")
  [[ "$p" == "$lane" || "$p" == "$lane_phys" || "$p" == / ]] || allowed_p+=("$p")
fi
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
  # git prints the physical path; the command goes on to spell the one it cd'd through.
  o=$(logical_top "$top" "$d")
  [[ "$o" == "$(norm "$top")" ]] || allowed+=("$o")
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
# The deadline's fail-closed decision is a deny in a known lane (see the end of this file).
[[ $known_lane == no || -z "${wd:-}" ]] || : >"$wd/lane"

# Forbidden roots (#218), each also by its physical path (/tmp vs /private/tmp). A lane's own
# worktree nested below one (.claude/worktrees/<lane>) stays writable: own.
forbid=() own="" own_phys="" lane_forbidden=no
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
    [[ "$lane" != "$v" && "$lane_phys" != "$v" ]] || lane_forbidden=yes
    [[ -z "$own" ]] || ! { inside "$v" "$own" || inside "$v" "$lane_phys"; } || own=""
  done
  # The lane's own physical root: only a path physically inside it is the lane's own (#380).
  [[ -z "$own" ]] || own_phys=$(phys "$lane_phys")
  # Unbound: the orchestrator's own call (no subagent, and its cwd is no lane or a forbidden root).
  if [[ -z "$agent" && ( -z "$lane" || $lane_forbidden == yes ) ]]; then forbid=(); fi
fi
# forbidden PATH: prints the bound forbidden root holding PATH's resolved target (real), or, when
# PATH is not spelled inside the caller's own lane, holding PATH as spelled. A target physically
# inside the own lane is never forbidden; a symlink in the lane into the checkout is no exemption,
# and one in the lane to anywhere else is judged by the lane rules, not here (#380).
forbidden() {
  local f p hit=""
  ((${#forbid[@]})) || return 1
  p=$(real "$1")
  [[ -z "$own" ]] || ! inside "$p" "$own_phys" || return 1
  for f in "${forbid[@]}"; do
    if inside "$p" "$f"; then hit=$f; break; fi
  done
  if [[ -n "$hit" ]]; then
    # Named as PATH spells it when it can be, so the message matches the command.
    for f in "${forbid[@]}"; do
      if inside "$1" "$f"; then hit=$f; break; fi
    done
    printf '%s\n' "$hit"; return 0
  fi
  [[ -z "$own" ]] || ! { inside "$1" "$own" || inside "$1" "$lane_phys" || inside "$1" "$own_phys"; } || return 1
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
# claude_memory PATH [HOME]: PATH is inside a Claude project's auto-memory dir
# (~/.claude/projects/<project>/memory, below HOME, default $HOME), which every session may write.
claude_memory() {
  local rest=${1#"${2:-$home}/.claude/projects/"}
  [[ "$rest" != "$1" && "$rest" == ?*/memory* && "${rest#*/}" =~ ^memory(/|$) ]]
}
# claude_memory_p PATH: claude_memory, PATH being physical ($HOME spelled either way).
claude_memory_p() { claude_memory "$1" || claude_memory "$1" "$(phys "$home")"; }
# sibling_worktree PATH: prints the linked worktree (not the main checkout, not this session's own
# worktree) of this repository that holds PATH, spelled as PATH spells it when PATH reaches it
# through a symlink git resolved. Listed once, lazily, from git worktree list.
siblings_listed=no siblings=()
sibling_worktree() {
  local w p rest
  if [[ $siblings_listed == no ]]; then
    siblings_listed=yes
    while IFS= read -r w; do
      [[ -n "$w" ]] || continue
      w=$(norm "$w")
      [[ "$w" != "$lane" && "$w" != "$lane_phys" ]] || continue
      siblings+=("$w")
      if p=$(cd "$w" 2>/dev/null && pwd -P) && [[ "$p" != "$w" ]]; then siblings+=("$p"); fi
    done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | sed 1d)
  fi
  for w in "${siblings[@]:-}"; do
    if [[ -n "$w" ]] && inside "$1" "$w"; then printf '%s\n' "$w"; return 0; fi
  done
  # By the physical path only when PATH itself is no symlink: removing a link that sits outside every
  # worktree removes the link, not the sibling it points into (#380).
  [[ ! -L "$1" ]] || return 1
  p=$(phys "$1")
  [[ "$p" != "$1" ]] || return 1
  for w in "${siblings[@]:-}"; do
    if [[ -n "$w" ]] && inside "$p" "$w"; then
      rest=${p#"$w"}
      if [[ "$1" == *"$rest" ]]; then printf '%s\n' "${1%"$rest"}"; else printf '%s\n' "$w"; fi
      return 0
    fi
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
  ! lost_rel "$target" || return 1
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

# check_delete WORD BASE WHAT [REC]: a deletion target; REC (default yes) is recursive (rm -r, find
# -delete), no a single entry (rm without -r, unlink, #384). A brace expansion is judged word by
# word, a zsh glob refused (pre_words). The literal word is judged first; when it passes, a glob
# before a later `/` is expanded within bounds and every match judged too (#384).
check_delete() {
  local w=$1 base=$2 what=$3 rec=${4:-yes} s ww m mk rc=0
  if lost_rel "$w"; then deny "$what $w: $(lost_why)"; return 0; fi
  pre_words "$w" "$base" "$what $w" || rc=$?
  if ((rc == 2)); then return 0; fi
  if ((rc == 0)); then
    local bl=("${bw[@]}")
    for m in "${bl[@]}"; do
      if over_time; then glob_refuse "$what $w" "brace words left unjudged: the hook ran out of time; name the paths"; break; fi
      [[ -z "$m" ]] || check_delete "$m" "$base" "$what" "$rec"
    done
    return 0
  fi
  if subst_word "$w" "$base"; then ww=$sw
  elif s=$(subst_var "$w"); then ww=$s
  else
    # A single entry built from a variable is judged like a write (check_write), which cannot see it.
    [[ $rec == no || -z "$lane" ]] || lane_deny "$what $w: path built from a variable; expand and echo the literal path first"
    return 0
  fi
  mk="${#denies}.${#asks}"
  judge_delete "$ww" "$base" "$what $w" "$rec"
  [[ "${#denies}.${#asks}" == "$mk" ]] || return 0
  if deep_glob "$ww" && glob_expand "$ww" "$base" "$what $w"; then
    for m in ${gw[@]+"${gw[@]}"}; do
      if over_time; then glob_refuse "$what $w" "glob matches left unjudged: the hook ran out of time; name the paths"; break; fi
      judge_delete "$m" "$base" "$what $w (glob match $m)" "$rec"
    done
  fi
}
# judge_delete WORD BASE LABEL REC: WORD (no variables left) judged as one deletion target.
judge_delete() {
  local w=$1 base=$2 what=$3 rec=$4 t glob=no prefix="" r
  t=$(expand "$w" "$base") || return 0
  # A glob is judged by the directory it lists (t) and the literal start of the globbed name
  # (prefix): "dir/*" empties dir, "dir/x*" reaches only the entries starting with x.
  case "$t" in
    *[*?[]*) glob=yes; t=${t%%[*?[]*}; prefix=${t##*/}; t=${t%/*}; t=${t:-/} ;;
  esac
  # rt: the entry the deletion acts on, physically (#380): T's directory resolved and T's own name
  # kept (rm -r removes a link, not its target), or all of T followed when it is a glob's directory
  # or the word ends in / (rm -r link/ walks into the target).
  local rt d
  if [[ $glob == yes || "$w" == */ || "$w" == */. ]]; then rt=$(real "$t")
  elif [[ "$t" == / ]]; then rt=/
  else d=${t%/*}; rt=$(norm "$(phys "${d:-/}")/${t##*/}"); fi
  # A single entry (REC no) takes nothing below it: only a protected root itself is denied here, and
  # a file below one is judged like a write (#384).
  local pg=$glob
  [[ $rec == yes ]] || pg=self
  if [[ $rec == yes || $glob == no ]]; then
    if r=$(protected "$t" "$pg" "$prefix"); then deny "$what: protected path $r"; return 0; fi
    [[ "$rt" == "$t" ]] || phys_roots
    if [[ "$rt" != "$t" ]] && r=$(protected "$rt" "$pg" "$prefix" phys); then
      deny "$what: protected path $r (through a symlink: $rt)"; return 0
    fi
  fi
  if r=$(forbidden "$t"); then deny "$what: $(forbid_why "$t" "$r")"; return 0; fi
  if [[ "$rt" != "$t" ]] && r=$(forbidden "$rt"); then deny "$what: $(forbid_why "$rt" "$r")"; return 0; fi
  if [[ $rec == yes ]]; then
    for r in "${forbid[@]:-}"; do
      if [[ -n "$r" ]] && reaches "$t" "$r" "$glob" "$prefix"; then deny "$what: $(forbid_why "$t" "$r")"; return 0; fi
    done
  fi
  [[ -n "$lane" ]] || return 0
  if [[ $rec == yes && $glob == no && "$t" == "$lane" ]]; then lane_deny "$what: that is the lane worktree itself; use git worktree remove"; return 0; fi
  # A single entry is in bounds at or below an allowed root, as a write is (and in Claude memory).
  local g=$glob
  [[ $rec == yes ]] || g=yes
  if { del_ok "$t" "$g" || { [[ $rec == no ]] && claude_memory "$t"; }; } &&
    { [[ "$rt" == "$t" ]] || del_ok "$rt" "$g" || { [[ $rec == no ]] && claude_memory_p "$rt"; }; }; then return 0; fi
  if [[ "$rt" != "$t" ]] && { del_ok "$t" "$g" || { [[ $rec == no ]] && claude_memory "$t"; }; }; then
    lane_deny "$what: outside the lane worktree $lane and temp dirs (through a symlink: $rt)"
  else lane_deny "$what: outside the lane worktree $lane and temp dirs"; fi
}
# protected T GLOB PREFIX [phys]: prints the protected root a deletion of T (GLOB, PREFIX: as in
# check_delete; GLOB self: a single entry, which takes only a root it is itself) would take; with
# phys, T is a physical path and each root counts by its physical
# path as well.
# phys_roots: fills exacts_p and trees_p (each root and its physical path) once, in this shell.
phys_roots=no exacts_p=() trees_p=()
phys_roots() {
  local r
  [[ $phys_roots == no ]] || return 0
  phys_roots=yes
  for r in "${exacts[@]}"; do exacts_p+=("$r"); r=$(phys "$r"); exacts_p+=("$r"); done
  for r in "${trees[@]}"; do r=$(norm "$r"); trees_p+=("$r"); r=$(phys "$r"); trees_p+=("$r"); done
}
protected() {
  local t=$1 glob=$2 prefix=$3 r ex tr
  if [[ "${4:-}" == phys ]]; then ex=("${exacts_p[@]}") tr=("${trees_p[@]}")
  else ex=("${exacts[@]}") tr=("${trees[@]}"); fi
  if [[ $glob == self ]]; then
    for r in "${ex[@]}" "${tr[@]}"; do
      [[ "$(norm "$r")" != "$t" ]] || { printf '%s\n' "$r"; return 0; }
    done
    return 1
  fi
  for r in "${ex[@]}"; do
    if [[ "$r" == "$t" ]]; then
      [[ $glob == yes && -n "$prefix" ]] || { printf '%s\n' "$r"; return 0; }
    elif reaches "$t" "$r" "$glob" "$prefix"; then printf '%s\n' "$r"; return 0; fi
  done
  for r in "${tr[@]}"; do
    r=$(norm "$r")
    if inside "$t" "$r" || reaches "$t" "$r" "$glob" "$prefix"; then printf '%s\n' "$r"; return 0; fi
  done
  return 1
}
# del_ok PATH GLOB: in a lane, deleting PATH stays in bounds: strictly below an allowed root or its
# physical path (allowed_p) (with GLOB, at or below one), or below a sibling worktree the owner's
# session opened.
del_ok() {
  local a
  ! owner_sibling "$1" || return 0
  for a in "${allowed[@]}" ${allowed_p[@]+"${allowed_p[@]}"}; do
    if [[ $2 == yes ]]; then ! inside "$1" "$a" || return 0
    else [[ "$1" != "$a"/* ]] || return 0; fi
  done
  return 1
}
# check_write WORD BASE WHAT: a file a shell command writes (lane mode only). A brace expansion is
# judged word by word, a zsh glob refused (pre_words); the literal word is judged first and, when it
# passes, a glob anywhere in it is expanded within bounds and every match judged as well (#384).
check_write() {
  [[ -n "$lane" || ${#forbid[@]} -gt 0 ]] || return 0
  local w=$1 base=$2 what=$3 m mk rc=0
  case "$w" in /dev/null | /dev/stdout | /dev/stderr | /dev/tty | /dev/fd/* | "") return 0 ;; esac
  if lost_rel "$w"; then deny "$what $w: $(lost_why)"; return 0; fi
  pre_words "$w" "$base" "$what $w" || rc=$?
  if ((rc == 2)); then return 0; fi
  if ((rc == 0)); then
    local bl=("${bw[@]}")
    for m in "${bl[@]}"; do
      if over_time; then glob_refuse "$what $w" "brace words left unjudged: the hook ran out of time; name the paths"; break; fi
      check_write "$m" "$base" "$what"
    done
    return 0
  fi
  subst_word "$w" "$base" || return 0
  local ww=$sw
  mk="${#denies}.${#asks}"
  judge_write "$ww" "$base" "$what $w"
  [[ "${#denies}.${#asks}" == "$mk" ]] || return 0
  if globbed "$ww" && glob_expand "$ww" "$base" "$what $w"; then
    for m in ${gw[@]+"${gw[@]}"}; do
      if over_time; then glob_refuse "$what $w" "glob matches left unjudged: the hook ran out of time; name the paths"; break; fi
      judge_write "$m" "$base" "$what $w (glob match $m)"
    done
  fi
}
# judge_write WORD BASE LABEL [OUTSIDE]: WORD (no variables left) judged as a written path: a
# forbidden root (by its resolved target, forbidden), then in a lane the path as spelled, then the
# file it really lands on through a symlink (#384), which must also be in bounds: an allowed root or
# its physical path, Claude memory, an opened sibling worktree, or anything under /dev. OUTSIDE is
# the reason's text for a path out of bounds.
judge_write() {
  local t f rt why=${4:-"writes outside the lane worktree $lane; enter the worktree (EnterWorktree) and use the edit tools"}
  t=$(expand "$1" "$2") || return 0
  if f=$(forbidden "$t"); then deny "$3: $(forbid_why "$t" "$f")"; return 0; fi
  [[ -n "$lane" ]] || return 0
  if ! { in_allowed "$t" || claude_memory "$t" || owner_sibling "$t"; }; then lane_deny "$3: $why"; return 0; fi
  rt=$(real "$t")
  [[ "$rt" != "$t" ]] || return 0
  case "$rt" in /dev | /dev/*) return 0 ;; esac
  real_ok "$rt" || lane_deny "$3: $why (through a symlink: $rt)"
}
# real_ok PATH: PATH, a physical path a write reaches through a symlink, is in bounds.
real_ok() {
  local a
  ! in_allowed "$1" || return 0
  for a in ${allowed_p[@]+"${allowed_p[@]}"}; do ! inside "$1" "$a" || return 0; done
  claude_memory_p "$1" || owner_sibling "$1"
}
# check_ln BASE ARG...: ln (#384). Each link is a write at the link path; its target (a relative
# symlink target resolves against the link's directory, a hard link's or ln -r's against BASE) is
# judged as a write too, so a link created and used in one command (`ln -s <checkout> nl && echo x
# > nl/f`) cannot lead out of bounds.
check_ln() {
  local base=$1 sym=no rel=no tdir="" notdir=no ends=no ops=() t srcs=() links=() k L ld tw s o ch v x rc
  shift
  while (($#)); do
    t=$1; shift
    if [[ $ends == no ]]; then
      case "$t" in
        --) ends=yes; continue ;;
        --symbolic) sym=yes; continue ;;
        --relative) rel=yes; continue ;;
        --no-target-directory) notdir=yes; continue ;;
        --target-directory=*) tdir=${t#*=}; continue ;;
        --target-directory | --suffix) [[ "$t" == --suffix ]] || tdir=${1:-}; (($# == 0)) || shift; continue ;;
        --*) continue ;;
        -?*)
          # A cluster: -t DIR and -S SUFFIX take the rest of the word, or the next one (-tDIR, -sfTt DIR).
          o=${t#-}
          while [[ -n "$o" ]]; do
            ch=${o:0:1} o=${o:1}
            case "$ch" in
              s) sym=yes ;;
              r) rel=yes ;;
              T) notdir=yes ;;
              t | S)
                if [[ -n "$o" ]]; then v=$o; else v=${1:-}; (($# == 0)) || shift; fi
                [[ "$ch" == S ]] || tdir=$v
                o="" ;;
            esac
          done
          continue ;;
      esac
    fi
    [[ -z "$t" ]] || ops+=("$t")
  done
  ((${#ops[@]})) || return 0
  # Operand words as the shell globbed them, from BASE.
  local words=()
  for t in "${ops[@]}"; do
    rc=0
    pre_words "$t" "$base" "ln $t" || rc=$?
    if ((rc == 2)); then return 0; fi
    local bl=("$t")
    if ((rc == 0)); then bl=("${bw[@]}"); fi
    for x in "${bl[@]}"; do
      [[ -n "$x" ]] || continue
      if subst_word "$x" "$base" && globbed "$sw"; then
        glob_expand "$sw" "$base" "ln $x" || return 0
        if ((${#gw[@]})); then words+=("${gw[@]}"); else words+=("$x"); fi
      else words+=("$x"); fi
    done
  done
  ((${#words[@]})) || return 0
  if [[ -n "$tdir" ]]; then
    srcs=("${words[@]}")
    for t in "${srcs[@]}"; do t=${t%/}; links+=("$tdir/${t##*/}"); done
  elif ((${#words[@]} == 1)); then
    t=${words[0]%/}; srcs=("${words[0]}") links=("${t##*/}")
  else
    L=${words[${#words[@]} - 1]} srcs=("${words[@]:0:${#words[@]}-1}")
    if [[ $notdir == no ]] && t=$(expand "$L" "$base") && [[ -d "$t" ]]; then
      for t in "${srcs[@]}"; do t=${t%/}; links+=("$L/${t##*/}"); done
    else
      for t in "${srcs[@]}"; do links+=("$L"); done
    fi
  fi
  for ((k = 0; k < ${#srcs[@]}; k++)); do
    check_write "${links[k]}" "$base" "ln"
    s=${srcs[k]}
    if subst_word "$s" "$base"; then tw=$sw
    elif tw=$(subst_var "$s"); then :
    else continue; fi
    ld=$base
    if [[ $sym == yes && $rel == no && "$tw" != /* ]]; then
      # resolve (via expand) walks a `..` in the target from the link directory's physical path.
      L=$(expand "${links[k]}" "$base") || continue
      ld=${L%/*}
      ld=${ld:-/}
    fi
    case "$tw" in /dev | /dev/*) continue ;; esac
    judge_write "$tw" "$ld" "ln $s (target of the link ${links[k]})" \
      "links outside the lane worktree $lane and temp dirs; a link created and used in one command is not checked when used"
  done
}
# check_git BASE ARG...: a mutating git command whose work tree (BASE, -C, --work-tree) lies under a
# bound forbidden root. Read-only commands, fetch and worktree add stay allowed there.
check_git() {
  local dir=$1 sub="" f lost=no; shift
  ((${#forbid[@]})) || return 0
  # lost: the work tree is the unknown cwd, or relative to it (cwd_lost).
  [[ -z "$cwd_lost" ]] || lost=yes
  while (($#)); do
    case "$1" in
      -C | --work-tree) (($# >= 2)) || return 0; lost_rel "$2" || lost=no; dir=$(expand "$2" "$dir") || return 0; shift 2 ;;
      --work-tree=*) lost_rel "${1#*=}" || lost=no; dir=$(expand "${1#*=}" "$dir") || return 0; shift ;;
      -c | --git-dir | --namespace) shift; if (($#)); then shift; fi ;;
      -*) shift ;;
      *) sub=$1; shift; break ;;
    esac
  done
  case "$sub" in
    checkout | switch | reset | pull | merge | rebase | commit | stash | restore | apply | am | cherry-pick | revert | clean | add | rm | mv) ;;
    branch)
      # Deleting, moving, copying or forcing a branch: a reviewer deleted the branch it had checked
      # out there and left the checkout on a detached HEAD (#317). Listing stays allowed.
      local b mut=no
      for b in "$@"; do
        case "$b" in --delete | --move | --copy | --force | -[dDmMcCf]* | -[!-]*[dDmMcCf]*) mut=yes ;; esac
      done
      [[ $mut == yes ]] || return 0
      sub="branch -d/-m/-c/-f" ;;
    worktree)
      case "${1:-}" in remove | move) ;; *) return 0 ;; esac
      shift
      while (($#)) && [[ "$1" == -* ]]; do shift; done
      (($#)) || return 0
      [[ $lost == yes ]] || ! lost_rel "$1" || lost=yes
      [[ "$1" != /* ]] || lost=no
      dir=$(expand "$1" "$dir") || return 0
      sub="worktree remove/move" ;;
    *) return 0 ;;
  esac
  if [[ $lost == yes ]]; then deny "git $sub: $(lost_why)"; return 0; fi
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
  awk -v US="$US" -v OP="$OP" -v NL=$'\035' -v MK="$MK" '
  # mk(c): c quoted or escaped, marked when the shell would expand it unquoted (MK above).
  function mk(c,   k) { k = index("{},()#^~*", c); return k ? substr(MK, k, 1) : c }
  function flush() { if (have) { toks = toks (ntok ? US : "") word; ntok++; last = word; word = ""; have = 0 } }
  function emit(term) { flush(); if (ntok) print term "\036" toks "\036" cmdsubs; toks = ""; ntok = 0; cmdsubs = ""; last = "" }
  function optok(o) { flush(); toks = toks (ntok ? US : "") OP o; ntok++; last = OP o }
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
      if (sq) { if (c == "\047") sq = 0; else word = word (c == "\n" ? NL : mk(c)); continue }
      if (dq) {
        if (c == "\"") { dq = 0; continue }
        if (c == "\\" && (n == "\"" || n == "\\" || n == "$" || n == "`")) { word = word n; i++; continue }
        if (c == "$" && n == "(") { i = grab(s, i + 2, ")"); word = word "$(...)"; continue }
        if (c == "`") { i = grab(s, i + 1, "`"); word = word "$(...)"; continue }
        word = word (c == "\n" ? NL : mk(c)); continue
      }
      if (c == "\047") { sq = 1; have = 1; continue }
      if (c == "\"") { dq = 1; have = 1; continue }
      if (c == "\\") { if (n == "\n") { i++; continue } word = word mk(n); have = 1; i++; continue }
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
      if (c == "(" || c == ")") {
        # A ( inside or starting an argument word (not the command word, an assignment, a
        # redirection target or after a keyword) is zsh glob or extglob syntax (`h(m|x)`, `(hm)`):
        # it stays in the command as a word holding "(" for zsh_glob. The split below is unchanged,
        # so what follows is still judged as commands.
        if (c == "(" && ntok > 0) {
          if (have && word !~ /^[A-Za-z_][A-Za-z0-9_]*\+?=$/) word = word "("
          else if (!have && substr(last, 1, 1) != OP && last !~ /^(in|time|!|if|then|else|elif|do|while|until|\{|function|coproc)$/) { word = "("; have = 1 }
        }
        emit("sub"); print "paren\036\036"; continue
      }
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
  # A bash -c or eval body starts where its caller stands: a lost cwd stays lost in it.
  local cwd_lost=$cwd_lost
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
  # A bash -c or eval body arrives with its quoted characters marked: the shell reads it afresh.
  unmark "$text"; text=$um
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
      expand "${toks[1]}" "$cur" lex >/dev/null; then inert=yes is_cd=yes; fi
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
    cd | pushd)
      # The shell's cd is logical: it applies `..` to the logical cwd, lexically, so the target
      # normalises lexically (expand lex); cd -P walks it as the OS does (#380). The file operands
      # after it resolve from that logical cwd as the OS walks them. Given both -L and -P, bash
      # takes the last and zsh takes -P, so the hook cannot know which; nor where `cd -`, `cd ±N`,
      # a bare `pushd` (swap), `pushd ±N`, `pushd -n`, a `~-`/`~N`/`~+N` target or one the hook cannot
      # expand leave the shell: each sets cwd_lost.
      local sawp=no sawl=no lost=""
      j=0
      while ((j < n)) && [[ "${a[j]}" == -[LPe@]* ]]; do
        [[ "${a[j]}" != *P* ]] || sawp=yes
        [[ "${a[j]}" != *L* ]] || sawl=yes
        ((j += 1))
      done
      if ((j < n)) && [[ "${a[j]}" == -- ]]; then ((j += 1)); fi
      [[ $c == cd ]] || plain=no
      if [[ $sawp == yes && $sawl == yes ]]; then lost="$c ${a[*]:0:j}"
      elif ((j == n)); then [[ $c == cd ]] || lost=pushd
      elif [[ "${a[j]}" == -* || "${a[j]}" =~ ^\+[0-9]+$ || "${a[j]}" =~ ^~[-+0-9] ]]; then lost="$c ${a[j]}"; fi
      # The target as the shell makes it (#387 review): a zsh glob is refused and loses the cwd; a
      # brace expansion or glob that makes one word is that word, any other count loses the cwd.
      local tw=${a[j]:-} rc=0
      if [[ -z "$lost" ]] && ((j < n)); then
        pre_words "$tw" "$base" "$c $tw" || rc=$?
        if ((rc == 2)); then lost="$c $tw"
        elif ((rc == 0)); then
          if ((${#bw[@]} == 1)); then tw=${bw[0]}; else lost="$c $tw"; fi
        fi
        if [[ -z "$lost" ]] && subst_word "$tw" "$base" && globbed "$sw"; then
          if glob_expand "$sw" "$base" "$c $tw" && ((${#gw[@]} == 1)); then tw=${gw[0]}; else lost="$c $tw"; fi
        fi
      fi
      if [[ -n "$lost" ]]; then
        cwd_lost=$lost plain=no inert=no
      elif ((j == n)); then cur=$home cwd_lost=""
      else
        # A relative target from a lost cwd stays lost; an absolute one the hook expands is known again.
        local known=yes
        if [[ $sawp == yes ]] && cur=$(expand "$tw" "$base"); then cur=$(phys "$cur")
        # A target the hook cannot expand ($OLDPWD, $(dirs …), `…`) may lead anywhere: lost.
        else cur=$(expand "$tw" "$base" lex) || { cur=$base; plain=no; known=no; cwd_lost="$c ${a[j]}"; }; fi
        [[ $known == no ]] || lost_rel "$tw" || cwd_lost=""
      fi
      if [[ -n "$cwd_lost" ]]; then plain=no inert=no
      else
        [[ -d "$cur" ]] || plain=no
        enter_worktree "$cur"
      fi ;;
    popd) cwd_lost=popd plain=no inert=no ;;
    export) ((i == 0)) && record_vars "$term" "$depth" $nredir "${a[@]:-}" ;;
    for | case | select | function | source | .)
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
      else
        # Without -r: one entry each, judged as a write is but by the entry rm removes (#384).
        for t in "${files[@]:-}"; do [[ -z "$t" ]] || check_delete "$t" "$base" "rm" no; done
      fi ;;
    unlink)
      destructive=yes
      for t in "${a[@]:-}"; do [[ -z "$t" || "$t" == -* ]] || check_delete "$t" "$base" "unlink" no; done ;;
    ln) check_ln "$base" "${a[@]:-}" ;;
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
    cp | mv | install | rsync)
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
  if [[ "$c" =~ ^(rm|unlink|kill|avdmanager|git|xcrun|simctl|adb|find)$ && $destructive == yes ]]; then
    if [[ "$term" == "&" ]]; then ask "backgrounded destructive command ($c ...): run it in the foreground and read its output"
    elif [[ $silenced == yes && $kill_literal == yes ]]; then :
    elif [[ $silenced == yes && $kill_quiet == yes ]]; then quiet_kills+=("$base"$'\036'"$cmd_subs")
    elif [[ $silenced == yes && $stop_named == yes ]]; then :
    elif [[ $silenced == yes ]]; then ask "silenced destructive command ($c ... >/dev/null): let its output show"; fi
  fi
  destructive=no
}

# Test hook: stall the checks this many seconds (since the hook started) to exercise the deadline.
if [[ "${WAAAGH_LANE_SAFETY_TEST_STALL:-}" =~ ^[0-9]$ ]]; then
  while ((SECONDS < WAAAGH_LANE_SAFETY_TEST_STALL)); do :; done
fi
# The tokenizer marks quoted characters with the bytes \021-\031, so a command that already holds
# one could forge a mark (an unquoted `#` read as a comment hides the rest of the line). No real
# command needs them: refuse it.
mark_re=$'[\021-\031]'
if [[ "$tool" == Bash && "$cmd" =~ $mark_re ]]; then
  deny "the command holds control characters (\\021-\\031) the check cannot judge; remove them"
elif [[ "$tool" == Bash ]]; then
  analyze "$cmd" "$cwd"
elif t=$(expand "$cmd" "$cwd") && f=$(forbidden "$t"); then
  deny "$tool $cmd: $(forbid_why "$t" "$f")"
fi

decision="" reason=""
if [[ -n "$denies" ]]; then decision=deny reason="lane safety (lane-safety.md): $denies"
elif [[ -n "$asks" ]]; then decision=ask reason="lane safety (lane-safety.md): $asks"; fi
[[ -n "$decision" ]] || exit 0
unmark "$reason"
jq -cn --arg d "$decision" --arg r "$um" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
}

# --- deadline (#387 review, #388) ---------------------------------------------------------------
# Claude Code gives the hook 10 seconds (hooks.json), and a hook that times out does not block: the
# call goes ahead. So the checks run in a worker process (lane_main, its output to a file) while a
# watchdog, which spawns nothing, waits deadline seconds (default 6) and then signals this process,
# its recorded parent ($$, never a pattern). On that signal this process kills the worker (its own
# recorded PID) and prints the fail-closed decision: deny when the call is a subagent's or the
# session a known lane (lane_main marks it in the temp dir), ask otherwise. Exactly one decision is
# printed, and only by this process: the normal path ignores the signal before it prints the
# worker's decision. Without a temp dir or a FIFO there is no watchdog, and the checks run inline.
# WAAAGH_LANE_SAFETY_DEADLINE (1-6) shortens the deadline for tests.
deadline=${WAAAGH_LANE_SAFETY_DEADLINE:-6}
[[ "$deadline" =~ ^[1-6]$ ]] || deadline=6
wd=""
# An unwritable TMPDIR falls back to /tmp, so the deadline still holds.
if ! { wd=$(mktemp -d "${TMPDIR:-/tmp}/lane-safety.XXXXXX" 2>/dev/null) || wd=$(mktemp -d /tmp/lane-safety.XXXXXX 2>/dev/null); } ||
  ! mkfifo "$wd/f" 2>/dev/null; then
  [[ -z "$wd" || ! -d "$wd" ]] || rm -rf "$wd"
  wd=""
  lane_main
  exit 0
fi
main=$$
lane_main >"$wd/out" &
worker=$!
# The watchdog reads a FIFO it holds open for writing too: no data, no EOF, only the timeout.
(
  [[ -p "$wd/f" ]] || exit 0
  read -r -t "$deadline" _ <>"$wd/f" || true
  kill -TERM "$main" 2>/dev/null || true
) </dev/null >/dev/null 2>&1 &
wdog=$!
# `|| true`: the watchdog may already be gone, and a failing kill under set -e would turn the
# deadline's exit 0 into exit 1.
trap 'kill "$wdog" 2>/dev/null || true; rm -rf "$wd"' EXIT
timed_out() {
  trap '' TERM
  kill "$worker" 2>/dev/null || true
  local d=ask
  if [[ -n "$agent" || -n "${WAAAGH_LANE_ROOT:-}" || -e "$wd/lane" ]]; then d=deny; fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$d" "lane safety: the check took too long; split the command or name the paths"
  exit 0
}
trap timed_out TERM
rc=0
wait "$worker" || rc=$?
trap '' TERM
out=""
IFS= read -r -d '' out <"$wd/out" || true
[[ -z "$out" ]] || printf '%s' "$out"
exit "$rc"
