#!/usr/bin/env bash
# Line coverage of the scripts under the BATS suites, measured with bashcov (Bash xtrace).
# Writes coverage/.resultset.json and prints one line per script, least covered first, then the total.
#
# Usage: dev/coverage.sh [-j N] [FILE.bats...]
#        dev/coverage.sh --changed [BASE] [-j N]
#        dev/coverage.sh --check FLOOR [--resultset FILE]
#   -j N         suites to run at once (passed to dev/test.sh; default 1). Keep 1: bashcov reads
#                every trace line through one ruby process, and more suites at once are slower, not
#                faster (#194: the same 18 suites took 2.5 min at -j 1 and 9.7 min at -j 4)
#   FILE         run only these suites (passed to dev/test.sh; default every suite). The numbers are
#                partial: a script another suite also exercises reads low. The table says so, and the
#                suites run are listed in coverage/subset.txt beside the resultset. A FILE that is
#                not a path is looked for in skills/orchestrate/scripts/ (a bare gh-read.bats works).
#   --changed B  measure only what a branch changed (#194): the scripts that differ from the merge
#                base with B (default origin/main; committed, staged, unstaged or untracked), the
#                suites that name one of them outside a comment, directly or through a *.bash helper
#                they load (gh-shim/gh: suites that name gh-shim), then --check dev/coverage-floor.tsv
#                for those scripts only. Partial numbers as with FILE; the changed scripts are listed
#                in coverage/changed.txt. No changed script: nothing runs, exit 0. A changed script
#                no suite names is reported and not judged (CI's full run still measures it).
#   --check F    run no suites: compare an existing resultset to the floors in F (script<TAB>min%,
#                # comments and blank lines allowed). Fails when a script is below its floor or a
#                measured script has no row, and names each one. A row for a script that was not
#                measured is reported as stale but does not fail. A resultset with a subset.txt
#                beside it is judged the same way, and the check says plainly the numbers are partial.
#   --resultset  the resultset --check reads (default coverage/.resultset.json)
# Env: GITHUB_STEP_SUMMARY  when set, the table (or the check's findings) is appended to it as Markdown.
# Needs: bashcov (gem install bashcov; not for --check), jq. Off PATH, it is looked for in gem's
# EXECUTABLE DIRECTORY, then in `gem environment gemdir`/bin, and the one used is named on stderr.
# Reading the numbers: xtrace reports one line of a multi-line command (often its last), so bashcov
# counts the rest (a jq or awk program, a `\`-continued call, a heredoc) as uncovered though it ran.
# Each script is reported twice: raw (bashcov's numbers) and credited, where the uncovered lines of
# a multi-line command count as covered when a line of that command ran. Floors check credited.
# A command continues past a line that ends in \, |, && or || or inside an open quote, and a
# heredoc runs to its terminator. An unbalanced command stays raw, and so does a script whose source
# is neither at the resultset's path nor under the repo root.
# Runtime (#194): a full run takes about 20 minutes at -j 1, in CI (coverage.yml: about 18 on #193)
# and in a 4-CPU cloud sandbox alike; at -j 4 the sandbox ran over an hour without finishing. For a
# lane's check use --changed: seconds for a script one suite names, about 2.5 minutes for _lib.sh,
# gh-read.sh and pr-ready.sh together (18 suites, the selftest-* ones among them).
# Exit: 0 report printed, or every floor held | 1 a suite failed (report still printed) | 2 usage,
#       a FILE missing, BASE unknown, or bashcov missing | 3 --check or --changed: a script below its
#       floor or with no floor row | 4 --check: the resultset or floor file is missing or malformed
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

jobs=(-j 1)
floor="" resultset="" suites=() changed="" base=""
while (($#)); do
  case "$1" in
    -j) jobs=(-j "${2:-}"); shift 2 ;;
    --check) [[ -n "${2:-}" ]] || { echo "dev/coverage.sh: --check needs a floor file" >&2; exit 2; }
      floor=$2; shift 2 ;;
    --resultset) [[ -n "${2:-}" ]] || { echo "dev/coverage.sh: --resultset needs a file" >&2; exit 2; }
      resultset=$2; shift 2 ;;
    --changed) changed=yes base=origin/main; shift
      # An optional BASE: the next word, unless it is a flag or a suite.
      if [[ -n "${1:-}" && "$1" != -* && "$1" != *.bats ]]; then base=$1; shift; fi ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    -*) echo "dev/coverage.sh: unknown argument: $1" >&2; exit 2 ;;
    *) s=$1; shift
      # A bare suite name: every suite lives in skills/orchestrate/scripts/.
      [[ -f "$s" || ! -f "$root/skills/orchestrate/scripts/$s" ]] || s=$root/skills/orchestrate/scripts/$s
      [[ -f "$s" ]] || { echo "dev/coverage.sh: no such suite: $s" >&2; exit 2; }
      # Absolute, since the run starts from the repo root.
      suites+=("$(cd "$(dirname "$s")" && pwd)/$(basename "$s")") ;;
  esac
done
[[ -z "$resultset" || -n "$floor" ]] || { echo "dev/coverage.sh: --resultset needs --check" >&2; exit 2; }
[[ -z "$floor" || ${#suites[@]} -eq 0 ]] || { echo "dev/coverage.sh: --check runs no suites; drop the suite files" >&2; exit 2; }
[[ -z "$changed" || -z "$floor" ]] || { echo "dev/coverage.sh: --changed and --check do not go together" >&2; exit 2; }
[[ -z "$changed" || ${#suites[@]} -eq 0 ]] || { echo "dev/coverage.sh: --changed picks the suites itself; drop the suite files" >&2; exit 2; }

# The measured scripts as [{f, rel, hit, raw}], paths relative to the repo root whatever root the
# resultset was written under (so a resultset from CI or a fixture checks the same way). hit counts
# credited lines, raw bashcov's; $ext is what credit_extents wrote.
ROWS='def path($root): ltrimstr($root) | capture("(?:^|/)(?<f>skills/orchestrate/scripts/gh-shim/gh|skills/orchestrate/scripts/.*\\.sh|bin/[^/]*\\.sh)$").f;
def credit($x): if $x == null then . else
  reduce $x.ext[] as $e (.; ([.[$e[0] - 1:$e[1]][] | select(. != null)] | max // 0) as $m
    | if $m > 0 then reduce range($e[0] - 1; $e[1]) as $i (.; if .[$i] == 0 then .[$i] = $m else . end) else . end) end;
def rows($root; $ext):
  [.[] | .coverage | to_entries[]
   | {f: (.key | path($root)), l: (.value.lines // .value)} | $ext[.f] as $x | .c = (.l | credit($x))
   | {f, rel: ([.l[] | select(. != null)] | length), hit: ([.c[] | select(. != null and . > 0)] | length),
      raw: ([.l[] | select(. != null and . > 0)] | length)}];
def pct: if .rel == 0 then null else (.hit * 1000 / .rel | floor) / 10 end;
def rawpct: if .rel == 0 then null else (.raw * 1000 / .rel | floor) / 10 end;'

# Each multi-line command of a script as "start<TAB>end" (1-based, inclusive).
# A command still open at the end of the file (an unbalanced quote or heredoc) is not printed.
EXTENTS='function word_start(i) { return i == 1 || substr(line, i - 1, 1) ~ /[ \t;|&()<>]/ }
{
  line = $0
  if (st == "heredoc") {
    t = line; if (hd_tabs) sub(/^\t+/, "", t)
    if (t == hd_term) { st = ""; if (!hd_cont) { if (NR > start) print start "\t" NR; start = 0 } }
    next
  }
  if (start == 0) start = NR
  n = length(line); i = 1; last = ""; hd_term = ""
  while (i <= n) {
    c = substr(line, i, 1)
    if (st == "sq") { if (c == "\047") st = ""; i++; continue }
    if (st == "aq") { if (c == "\\") i++; else if (c == "\047") st = ""; i++; continue }
    if (st == "dq") { if (c == "\\") i++; else if (c == "\"") st = ""; i++; continue }
    if (c == " " || c == "\t") { i++; continue }
    if (c == "#" && word_start(i)) break
    if (c == "\\") { if (i == n) { last = "\\"; break } last = "x"; i += 2; continue }
    if (c == "\047") { st = "sq"; last = "x"; i++; continue }
    if (c == "$" && substr(line, i + 1, 1) == "\047") { st = "aq"; last = "x"; i += 2; continue }
    if (c == "\"") { st = "dq"; last = "x"; i++; continue }
    if (substr(line, i, 3) == "<<<") { last = "x"; i += 3; continue }
    if (substr(line, i, 2) == "<<") {
      j = i + 2; tabs = 0
      if (substr(line, j, 1) == "-") { tabs = 1; j++ }
      while (substr(line, j, 1) ~ /[ \t]/) j++
      w = substr(line, j)
      if (match(w, /^[\047"\\]?[A-Za-z0-9_]+[\047"]?/)) {
        t = substr(w, 1, RLENGTH); gsub(/[\047"\\]/, "", t)
        hd_term = t; hd_tabs = tabs; i = j + RLENGTH; last = "x"; continue
      }
    }
    if (substr(line, i, 2) == "&&" || substr(line, i, 2) == "||") { last = "op"; i += 2; continue }
    if (c == "|") { last = "op"; i++; continue }
    last = "x"; i++
  }
  cont = (st != "" || last == "\\" || last == "op")
  if (hd_term != "" && st == "") { st = "heredoc"; hd_cont = cont; next }
  if (!cont) { if (NR > start) print start "\t" NR; start = 0 }
}'

# credit_extents RESULTSET OUT: writes {"<repo-relative path>": {ext: [[start, end]]}} to OUT for
# each measured script whose source it finds, at the resultset's path or under the repo root. The
# resultset's line count is not checked against the source: xtrace can report lines past the end.
credit_extents() {
  local key f src
  jq -r --arg root "$root/" "$ROWS"'[.[] | .coverage | keys[] | {k: ., f: path($root)} | "\(.k)\t\(.f)"] | unique[]' "$1" |
    while IFS=$'\t' read -r key f; do
      src=$key
      [[ -f "$src" ]] || src=$root/$f
      [[ -f "$src" ]] || continue
      awk "$EXTENTS" "$src" | awk -v f="$f" '{ print f "\t" $0 }'
    done | jq -Rn 'reduce (inputs | split("\t")) as $r ({}; .[$r[0]].ext += [[($r[1] | tonumber), ($r[2] | tonumber)]])' >"$2"
}

# Reads its input to the end either way: a producer piped into it must never see a closed pipe.
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >/dev/null; fi; }

ext="" # credit_extents' output, made where it is needed: the bashcov check runs with a minimal PATH
trap '[[ -z "$ext" ]] || rm -f "$ext"' EXIT

# check_floors: the --check verdict for $floor and $resultset; returns 0 or 3, exits 4 on bad input.
# With $only set (newline-separated paths, --changed), only those scripts are judged.
only=""
check_floors() {
  resultset=${resultset:-$root/coverage/.resultset.json}
  [[ -f "$resultset" ]] || { echo "dev/coverage.sh: no resultset at $resultset (run dev/coverage.sh first)" >&2; exit 4; }
  [[ -f "$floor" ]] || { echo "dev/coverage.sh: no floor file at $floor" >&2; exit 4; }
  # Floor rows: script<TAB>number, nothing else.
  bad=$(awk -F'\t' '/^[[:space:]]*(#|$)/ { next }
    NF != 2 || $2 !~ /^[0-9]+(\.[0-9]+)?$/ || $2 > 100 { print FILENAME ":" NR ": " $0 }' "$floor")
  [[ -z "$bad" ]] || { printf 'dev/coverage.sh: malformed floor row (want script<TAB>min%%):\n%s\n' "$bad" >&2; exit 4; }
  ext=$(mktemp)
  credit_extents "$resultset" "$ext" 2>/dev/null \
    || { echo "dev/coverage.sh: cannot read $resultset as a bashcov resultset" >&2; exit 4; }
  # One finding per line: "below\tpath\tpct\tfloor" | "missing\tpath\tpct" | "stale\tpath" (credited %).
  findings=$(jq -r --arg root "$root/" --rawfile floors "$floor" --slurpfile ext "$ext" --arg only "$only" "$ROWS"'
    ($only | split("\n") | map(select(. != ""))) as $o
    | def judged: if ($o | length) == 0 then . else with_entries(select(.key as $k | $o | index([$k]))) end;
    (rows($root; $ext[0]) | map({key: .f, value: pct}) | from_entries) as $all
    | if ($all | length) == 0 then error("no measured scripts in the resultset") else . end
    | ($all | judged) as $got
    | ([$floors | split("\n")[] | select(test("^\\s*(#|$)") | not) | split("\t") | {key: .[0], value: (.[1] | tonumber)}]
       | from_entries | judged) as $min
    | ($got | to_entries[] | select($min[.key] == null) | "missing\t\(.key)\t\(.value // "n/a")"),
      ($got | to_entries[] | select($min[.key] != null and .value != null and .value < $min[.key])
       | "below\t\(.key)\t\(.value)\t\($min[.key])"),
      ($min | keys[] | select(. as $k | $got | has($k) | not) | "stale\t\(.)")' "$resultset" 2>/dev/null) \
    || { echo "dev/coverage.sh: cannot read $resultset as a bashcov resultset" >&2; exit 4; }
  # A subset run's resultset: same verdicts, but say plainly that the numbers are partial.
  partial=""
  if [[ -f "$(dirname "$resultset")/subset.txt" ]]; then
    partial="partial resultset: only $(grep -c . "$(dirname "$resultset")/subset.txt" || true) suite(s) ran ($(dirname "$resultset")/subset.txt), so a script another suite exercises reads low"
    echo "dev/coverage.sh: $partial" >&2
  fi
  report=$(awk -F'\t' '
    $1 == "below"   { print "below floor: " $2 " at " $3 "% (floor " $4 "%)" }
    $1 == "missing" { print "no floor row: " $2 " at " $3 "% (add a row to the floor file)" }
    $1 == "stale"   { print "stale floor row: " $2 " was not measured" }' <<<"$findings")
  fails=$(grep -c -E '^(below|missing)' <<<"$findings" || true)
  if ((fails > 0)); then
    printf '%s\n' "$report" >&2
    echo "dev/coverage.sh: $fails coverage floor failure(s) against $floor" >&2
    { echo "### Coverage floor: $fails failure(s)"; [[ -z "$partial" ]] || { echo; echo "_${partial}_"; }; echo; sed 's/^/- /' <<<"$report"; } | summary
    return 3
  fi
  [[ -z "$report" ]] || printf '%s\n' "$report" >&2
  echo "coverage floors held ($floor)"
  { echo "### Coverage floor: every script at or above its floor"; [[ -z "$partial" ]] || { echo; echo "_${partial}_"; }; [[ -z "$report" ]] || { echo; sed 's/^/- /' <<<"$report"; }; } | summary
}
if [[ -n "$floor" ]]; then check_floors && exit 0 || exit $?; fi

# --changed: the scripts that differ from the merge base with $base, and the suites that name them.
if [[ -n "$changed" ]]; then
  mb=$(git -C "$root" merge-base "$base" HEAD 2>/dev/null) ||
    { echo "dev/coverage.sh: --changed: no merge base with $base (git fetch it, or name another BASE)" >&2; exit 2; }
  only=$({ git -C "$root" diff --name-only "$mb" --; git -C "$root" ls-files --others --exclude-standard; } |
    grep -E '^(skills/orchestrate/scripts/gh-shim/gh|skills/orchestrate/scripts/[^/]*\.sh|bin/[^/]*\.sh)$' |
    sort -u | while IFS= read -r f; do [[ ! -f "$root/$f" ]] || echo "$f"; done) || true
  if [[ -z "$only" ]]; then
    echo "dev/coverage.sh: no changed scripts against $base ($mb); nothing to measure"
    exit 0
  fi
  sdir=$root/skills/orchestrate/scripts
  # names FILE PATTERN: FILE has a non-comment line matching PATTERN (awk reads to the end: no early-exit pipe).
  names() { awk -v p="$2" '!/^[[:space:]]*#/ && $0 ~ p { hit = 1 } END { exit !hit }' "$1"; }
  unnamed="" picked=""
  while IFS= read -r f; do
    b=${f##*/}
    if [[ "$f" == */gh-shim/gh ]]; then pat='gh-shim'; else pat="(^|[^A-Za-z0-9_.-])${b//./[.]}([^A-Za-z0-9_-]|\$)"; fi
    found=""
    for s in "$sdir"/*.bats; do if names "$s" "$pat"; then found+="$s"$'\n'; fi; done
    # A helper that names it counts for every suite that loads the helper.
    for h in "$sdir"/*.bash; do
      names "$h" "$pat" || continue
      hb=${h##*/}; hb=${hb%.bash}
      for s in "$sdir"/*.bats; do if names "$s" "(^|[[:space:];])load[[:space:]]+[\"']?$hb([\"'.;[:space:]]|\$)"; then found+="$s"$'\n'; fi; done
    done
    if [[ -z "$found" ]]; then unnamed+="$f"$'\n'; else picked+="$found"; fi
  done <<<"$only"
  # cli-contract.bats runs every script's -h and unknown-flag lines without naming the script.
  [[ -z "$picked" || ! -f "$sdir/cli-contract.bats" ]] || picked+="$sdir/cli-contract.bats"$'\n'
  while IFS= read -r s; do [[ -z "$s" ]] || suites+=("$s"); done < <(printf '%s' "$picked" | sort -u)
  echo "dev/coverage.sh: --changed against $base: $(grep -c . <<<"$only" || true) script(s), ${#suites[@]} suite(s)" >&2
  if [[ -n "$unnamed" ]]; then
    printf '%s' "$unnamed" | sed 's/^/dev\/coverage.sh: not measured, no suite names it: /' >&2
    # Judge only what the run can measure.
    only=$(grep -vxF -f <(printf '%s' "$unnamed") <<<"$only" || true)
    if ((${#suites[@]} == 0)); then echo "dev/coverage.sh: no suite to run; nothing measured"; exit 0; fi
  fi
fi

bashcov=bashcov
if ! command -v bashcov >/dev/null; then
  # gem installs executables into its EXECUTABLE DIRECTORY, which is often not on PATH (rbenv,
  # --user-install): look there, then in the gem directory's bin, and say which bashcov ran (#171).
  gembin="" gemdir=""
  if command -v gem >/dev/null; then
    gembin=$(gem environment 2>/dev/null | sed -n 's/^[[:space:]]*- EXECUTABLE DIRECTORY: //p') || gembin=""
    gemdir=$(gem environment gemdir 2>/dev/null) || gemdir=""
  fi
  for d in "$gembin" "${gemdir:+$gemdir/bin}"; do
    if [[ -n "$d" && -x "$d/bashcov" ]]; then bashcov=$d/bashcov; break; fi
  done
  if [[ "$bashcov" == bashcov ]]; then
    if [[ -n "$gembin" ]]; then
      echo "dev/coverage.sh: bashcov not found (gem install bashcov, then put gem's executable directory $gembin on PATH)" >&2
    else
      echo "dev/coverage.sh: bashcov not found (gem install bashcov, then put the EXECUTABLE DIRECTORY from 'gem environment' on PATH)" >&2
    fi
    exit 2
  fi
  echo "dev/coverage.sh: bashcov not on PATH; using $bashcov" >&2
fi

cd "$root"
rm -rf coverage
rc=0
"$bashcov" --root "$root" -- dev/test.sh ${jobs[@]+"${jobs[@]}"} ${suites[@]+"${suites[@]}"} >coverage.log 2>&1 || rc=$?
mkdir -p coverage && mv coverage.log coverage/test.log
[[ -f coverage/.resultset.json ]] || { echo "dev/coverage.sh: bashcov wrote no results (see coverage/test.log)" >&2; exit 1; }
subset=""
if ((${#suites[@]})); then
  printf '%s\n' "${suites[@]#"$root"/}" >coverage/subset.txt
  all=("$root"/skills/orchestrate/scripts/*.bats)
  subset="subset: ${#suites[@]} of ${#all[@]} suites ran (coverage/subset.txt); a script another suite exercises reads low"
fi
[[ -z "$changed" ]] || printf '%s\n' "$only" >coverage/changed.txt
((rc == 0)) || echo "dev/coverage.sh: a suite failed under coverage (see coverage/test.log)" >&2

ext=$(mktemp)
credit_extents coverage/.resultset.json "$ext"
# Columns: credited %, credited lines/relevant lines, raw %, script; the total row last.
table=$(jq -r --arg root "$root/" --slurpfile ext "$ext" "$ROWS"'
  def p: if . == null then "  n/a" else tostring + "%" end;
  rows($root; $ext[0]) | (map(.rel) | add) as $r | (map(.hit) | add) as $h | (map(.raw) | add) as $w
  | (sort_by(if .rel == 0 then 1 else .hit / .rel end)[]
     | "\(pct | p)\t\(.hit)/\(.rel)\traw \(rawpct | p)\t\(.f)"),
    "total\t\($h)/\($r)\t\(($h * 1000 / $r | floor) / 10)%\traw \(($w * 1000 / $r | floor) / 10)%"' coverage/.resultset.json)
printf '%s\n' "$table"
[[ -z "$subset" ]] || echo "$subset"
{
  echo "### Line coverage (bashcov)"
  echo
  [[ -z "$subset" ]] || { echo "_${subset}_"; echo; }
  awk -F'\t' '$1 == "total" { sub(/^raw /, "", $4); print "**Total: " $3 " credited, " $4 " raw** (" $2 " lines)\n\n| Credited | Lines | Raw | Script |\n|---:|---:|---:|---|"; exit }' <<<"$table"
  awk -F'\t' '$1 != "total" { sub(/^raw /, "", $3); print "| " $1 " | " $2 " | " $3 " | `" $4 "` |" }' <<<"$table"
} | summary
((rc == 0)) || exit 1
[[ -n "$changed" ]] || exit 0
# --changed: judge the changed scripts against the repo's floors.
rm -f "$ext"; ext=""
floor=$root/dev/coverage-floor.tsv resultset=$root/coverage/.resultset.json
check_floors && exit 0 || exit $?
