# Shared by every .bats suite here (`load test_helper` in setup). Makes git hermetic for the test
# process and the scripts it runs: a test-local global config (fixed identity, no commit or tag
# signing, no hooks, main as the initial branch, no background gc or maintenance after commits and
# fetches: tests make thousands) and no system config, so a user's signing setup
# (1Password, gpg, ssh signers) or hooks can never run during fixtures. The user's real
# configuration files are not read or changed. Loaded in setup_file too, the config lives in the
# file's tmpdir until setup loads it again per test.
# Tests must also pass under dev/coverage.sh: bashcov exports SHELLOPTS with nounset and pipefail,
# so every bash a test starts (stubs included) runs with them. A stub that reads an unset variable
# (`$1` with no argument, an env var a test did not set) must use "${VAR:-}", and a test must not
# pipe into an early-exit reader such as `grep -q` or `head` (#140, linted by early-exit-pipes.bats).
# errexit reaches fewer of them: bats' `run` and command substitution `$(...)` drop errexit from the
# SHELLOPTS their children inherit, so under bashcov only a script or helper a test calls directly
# (not through `run`, not inside `$(...)`) runs with errexit. A wrapper called directly can then
# fail under coverage and pass everywhere else (#152, #153); dev/test.sh --bashcov-shellopts
# reproduces it.
hermetic_git() {
  local cfg="${BATS_TEST_TMPDIR:-$BATS_FILE_TMPDIR}/.gitconfig-hermetic"
  cat >"$cfg" <<'CFG'
[user]
	name = t
	email = t@example.com
[commit]
	gpgsign = false
[tag]
	gpgsign = false
[core]
	hooksPath = /dev/null
[init]
	defaultBranch = main
[advice]
	detachedHead = false
[maintenance]
	auto = false
[gc]
	auto = 0
CFG
  export GIT_CONFIG_GLOBAL="$cfg" GIT_CONFIG_NOSYSTEM=1
  unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
}
hermetic_git
# gh-read.sh in tests: log waits instead of sleeping, no jitter.
export GH_READ_FAKE_SLEEP=1 GH_READ_JITTER=0
# No suite reads or writes the user's real state directory (#292): _lib.sh falls back to
# $HOME/.claude/orchestrate when ORCHESTRATE_STATE_DIR is unset, and its gh-no-graphql memo there
# (left by an earlier GraphQL refusal) would switch orch_gh_api to REST, so a result would depend on
# the host. Always a fresh per-test directory (an inherited value is replaced); a test that wants a
# different one exports its own after loading this file.
export ORCHESTRATE_STATE_DIR="${BATS_TEST_TMPDIR:-$BATS_FILE_TMPDIR}/orch-state-default"
# No suite paces its stubbed gh through gh-budget.sh unless it puts the shim on PATH itself.
unset ORCHESTRATE_GH_BUDGET GH_BUDGET_ACTIVE
# Stubbing a sibling script (#233): put an executable stub of that one name in a directory and
# export ORCHESTRATE_SCRIPTS_DIR=<dir> (_lib.sh's orch_run); every other sibling still runs from
# the real tree, so coverage credits it. Never copy the scripts directory: a copy is credited
# nothing. Unset here, so no suite inherits another's stubs.
unset ORCHESTRATE_SCRIPTS_DIR
# No suite reaches githubstatus.com (gh-status.sh): an unreadable fixture unless a test writes it,
# and pr-merge.sh outage waits are logged ("pr-merge: wait <s>"), not slept.
export GITHUB_STATUS_URL="file://${BATS_TEST_TMPDIR:-$BATS_FILE_TMPDIR}/githubstatus.json" ORCHESTRATE_MERGE_FAKE_SLEEP=1
# A bare origin (branch main) and a clone of it, seed, with one pushed commit (f.txt "base"): built
# once in setup_file by seed_origin_template, copied into each test's $BATS_TEST_TMPDIR by
# seed_origin_copy, instead of git init, commit and push in every test (#112).
seed_origin_template() {
  local t="$BATS_FILE_TMPDIR/seed-template"
  git init -q --bare -b main "$t/origin.git"
  git clone -q "$t/origin.git" "$t/seed" 2>/dev/null
  echo base >"$t/seed/f.txt"
  git -C "$t/seed" add f.txt
  git -C "$t/seed" commit -qm init
  git -C "$t/seed" push -q origin HEAD:main
}
seed_origin_copy() {
  cp -R "$BATS_FILE_TMPDIR/seed-template/origin.git" "$BATS_FILE_TMPDIR/seed-template/seed" "$BATS_TEST_TMPDIR/"
  git -C "$BATS_TEST_TMPDIR/seed" remote set-url origin "$BATS_TEST_TMPDIR/origin.git"
}
# --- Stubbing spectra (#329, #330) ---------------------------------------------------------------
# waaagh requires spectra for host readings. No test reads the real host: SPECTRA points at
# $BATS_TEST_TMPDIR/bin/spectra, which does not exist until a test calls stub_spectra, so a suite
# that reaches spectra without stubbing it gets spectra's "not found" error, on a Mac that has
# spectra installed and on CI alike.
export SPECTRA="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR:-/nonexistent}}/bin/spectra"
# Nor the real lane worktrees: the checkout running the tests may have a .claude/worktrees of its
# own, CI's does not. A suite that wants a worktree root sets ORCHESTRATE_WORKTREE_ROOT or unsets it.
export ORCHESTRATE_WORKTREE_ROOT="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR:-/nonexistent}}/no-worktree-root"
# stub_spectra: that spectra. `capabilities --json` declares load, orphans, jvm, idle and owner
# (`owner --under` is described at its case below); `jvm --json` prints
# $BATS_TEST_TMPDIR/spectra-jvm.json, else no JVMs; `idle --json` prints
# $BATS_TEST_TMPDIR/spectra-idle.json (exit 3), else no idle holders. `load --json` prints
# an idle host: SPECTRA_STUB_LOAD1 (default 0.5), SPECTRA_STUB_CPUS (8), SPECTRA_STUB_FREE_GB (32;
# "null" when memory could not be read), read at each call, with $BATS_TEST_TMPDIR/spectra-load.json
# (cause, top_cpu, top_rss, families, ...) merged over it when it exists. `orphans --json` prints
# none, or $BATS_TEST_TMPDIR/spectra-orphans.json (and exits 3, as spectra does when it finds some).
# SPECTRA_STUB_FAIL=1 makes load and orphans print an error and exit 1. Every call is appended to
# $BATS_TEST_TMPDIR/spectra-calls.
stub_spectra() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/spectra" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/spectra-calls"
case "${1:-}" in
  capabilities) echo '{"schema":{"name":"spectra.capabilities","version":1},"spectra_version":"test","interfaces":[{"name":"load"},{"name":"orphans"},{"name":"jvm"},{"name":"idle"},{"name":"owner"}]}' ;;
  help) printf 'Subcommands:\n  load  x\n  orphans  x\n' ;;
  load)
    [ "${SPECTRA_STUB_FAIL:-0}" != 1 ] || { echo "spectra: load failed" >&2; exit 1; }
    over='{}'; [ ! -f "$BATS_TEST_TMPDIR/spectra-load.json" ] || over=$(cat "$BATS_TEST_TMPDIR/spectra-load.json")
    jq -n --argjson l "${SPECTRA_STUB_LOAD1:-0.5}" --argjson c "${SPECTRA_STUB_CPUS:-8}" --argjson g "${SPECTRA_STUB_FREE_GB:-32}" \
      --argjson o "$over" '{verdict: "admit", load1: $l, cpus: $c, available_gb: $g,
        cause: {kind: "none", detail: "host is idle"}, top_cpu: [], top_rss: [], families: []} + $o' ;;
  owner)
    # owner --under --json DIR...: the processes whose cwd is a DIR or below one. From
    # $BATS_TEST_TMPDIR/spectra-cwds ("PID<TAB>cwd" lines) when it exists, plus spectra-late-cwds
    # from call number spectra-late-at on; else this machine's own processes (lsof, else /proc), so
    # a test that parks a real process in a directory sees it. SPECTRA_STUB_FAIL=1: exit 1.
    [ "${SPECTRA_STUB_FAIL:-0}" != 1 ] || { echo "spectra: owner failed" >&2; exit 1; }
    [ "${2:-}" = --under ] && [ "${3:-}" = --json ] || { echo "spectra stub: owner needs --under --json" >&2; exit 2; }
    shift 3
    t=$BATS_TEST_TMPDIR n=$(( $(cat "$t/spectra-owner-n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$t/spectra-owner-n"
    if [ -f "$t/spectra-cwds" ] || [ -f "$t/spectra-late-cwds" ]; then
      { cat "$t/spectra-cwds" 2>/dev/null || true
        if [ -f "$t/spectra-late-cwds" ] && [ "$n" -ge "$(cat "$t/spectra-late-at" 2>/dev/null || echo 1)" ]; then cat "$t/spectra-late-cwds"; fi; }
    elif command -v lsof >/dev/null 2>&1; then
      lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }' || true
    else
      for p in /proc/[0-9]*; do d=$(readlink "$p/cwd" 2>/dev/null) && printf '%s\t%s\n' "${p##*/}" "$d"; done
    fi | DIRS="$(for d in "$@"; do (cd "$d" 2>/dev/null && pwd -P) || printf '%s\n' "$d"; done)" awk -F'\t' 'BEGIN { n = split(ENVIRON["DIRS"], D, "\n") }
      { for (i = 1; i <= n; i++) if (D[i] != "" && ($2 == D[i] || index($2, D[i] "/") == 1)) { print; break } }' |
      jq -Rn '[inputs | split("\t") | {pid: (.[0] | tonumber), cwd: .[1]}] | {holders: .}' >"$t/spectra-owner.out"
    cat "$t/spectra-owner.out"
    [ "$(jq '.holders | length' "$t/spectra-owner.out")" -gt 0 ] || exit 3 ;;
  idle) if [ -f "$BATS_TEST_TMPDIR/spectra-idle.json" ]; then cat "$BATS_TEST_TMPDIR/spectra-idle.json"; exit 3; fi
    echo '{"result":{"holders":[]}}' ;;
  jvm) if [ -f "$BATS_TEST_TMPDIR/spectra-jvm.json" ]; then cat "$BATS_TEST_TMPDIR/spectra-jvm.json"; else echo '[]'; fi ;;
  orphans)
    [ "${SPECTRA_STUB_FAIL:-0}" != 1 ] || { echo "spectra: orphans failed" >&2; exit 1; }
    if [ -f "$BATS_TEST_TMPDIR/spectra-orphans.json" ]; then cat "$BATS_TEST_TMPDIR/spectra-orphans.json"; exit 3; fi
    echo '{"roots":[],"groups":[],"total":0}' ;;
  *) echo "spectra stub: unexpected call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/spectra"
}

# --- Stubbing gh ----------------------------------------------------------------------------
# Tests stub gh with an executable $BATS_TEST_TMPDIR/bin/gh first on PATH. Every read that goes
# through gh-read.sh (most helpers' GitHub reads) gets `--include` appended to each `gh api` call
# without --paginate, for the status line and rate-limit headers: a stub that matches an exact
# `api <route>` argument list misses the call, and gh-read reports the miss as "transient" and
# retries it. Call gh_stub_args (below) or match with a trailing *. A stub need not
# print headers: output whose first line is not "HTTP/<v> <status>" is taken as the body.
#
# stub_gh_routes: the shared route stub. It writes that gh, exports FX=$BATS_TEST_TMPDIR/fx and
# puts the stub first on PATH. Each call drops `--include` and `-i` from a `gh api` call, appends
# the remaining arguments (a) to $FX/calls, then answers from, in order:
#   gh_route PATTERN FILE   the route table $FX/routes.tsv: the first PATTERN, a bash glob over a
#                           ("api repos/o/r/pulls/5", "pr list*"), that matches prints FILE
#                           (relative to $FX unless absolute) and exits 0
#   gh_routes <<'R' ... R   a whole `case "$a" in ... esac` statement, `case` and `esac` included
#                           ($FX/routes.sh, replaced on each call, sourced as is) for answers a
#                           file cannot give (computed, an error, an exit status); an arm must
#                           exit, or the call falls through
# and anything unmatched prints "unexpected gh call: <a>" on stderr and exits 9.
#
# gh_stub_args ARGS...: the argument handling every gh stub here shares (stub_gh_routes,
# selftest_helper.bash's stub_gh_router, rest_stub.bash's rest_wrap, #166), so one gh-read.sh call
# matches the same route through each: sets a to ARGS joined by spaces, with `--include` and `-i`
# dropped when ARGS is a `gh api` call (other subcommands keep -i). A stub gets it from
# gh_stub_header, which prints the shebang and this function's definition: write a stub as
# `{ gh_stub_header; cat <<'STUB' ... STUB; } >"$BATS_TEST_TMPDIR/bin/gh"` and call
# `gh_stub_args "$@"` first.
gh_stub_args() {
  a=""
  local x
  for x in "$@"; do
    if [[ "${1:-}" == api && ("$x" == --include || "$x" == -i) ]]; then continue; fi
    a="${a:+$a }$x"
  done
}
gh_stub_header() {
  echo '#!/usr/bin/env bash'
  declare -f gh_stub_args
}
stub_gh_routes() {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  {
    gh_stub_header
    cat <<'STUB'
gh_stub_args "$@"
echo "$a" >>"$FX/calls"
if [[ -f "$FX/routes.tsv" ]]; then
  while IFS=$'\t' read -r pat file; do
    # shellcheck disable=SC2053 # PATTERN is a glob on purpose
    if [[ -n "$pat" && "$a" == $pat ]]; then
      [[ "$file" == /* ]] || file="$FX/$file"
      cat "$file"
      exit 0
    fi
  done <"$FX/routes.tsv"
fi
if [[ -f "$FX/routes.sh" ]]; then
  # shellcheck source=/dev/null
  . "$FX/routes.sh"
fi
echo "unexpected gh call: $a" >&2
exit 9
STUB
  } >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
gh_route() { printf '%s\t%s\n' "$1" "$2" >>"$FX/routes.tsv"; }
gh_routes() { cat >"$FX/routes.sh"; }
# --- triage-tick.sh snapshot lines ----------------------------------------------------------
# Tests name the snapshot lines they check instead of counting or indexing them (#201, #225), so a
# new snapshot line needs no edit to any suite. The order is the one triage-tick.sh's header
# documents (the source of truth); the required lines are the ones it always prints. Optional lines
# (holds, hold-stale) and any line added later may follow.
REQUIRED_SNAPSHOT_LINES="verdict main prs merge_loop dispatch slots cron threads host"

# snap_line NAME: the one line of $output whose first word is NAME. Prints nothing and fails when
# there is none or more than one, so `[ "$(snap_line x)" = ... ]` fails either way.
snap_line() {
  awk -v k="$1" '$1 == k { n++; l = $0 }
    END { if (n == 1) { print l; exit 0 }
          printf "snapshot line %s: found %d times, want once\n", k, n > "/dev/stderr"; exit 1 }' <<<"$output"
}

# required_snapshot_lines: every required line is in $output exactly once, in the documented order,
# with the verdict first.
required_snapshot_lines() {
  awk -v want="$REQUIRED_SNAPSHOT_LINES" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) idx[w[i]] = i }
    ($1 in idx) { seen[$1]++; at[$1] = NR }
    END {
      bad = 0
      for (i = 1; i <= n; i++) if (seen[w[i]] != 1) { printf "%s: %d times, want once\n", w[i], seen[w[i]]; bad = 1 }
      if (!bad && at["verdict"] != 1) { print "verdict is line " at["verdict"] ", want 1"; bad = 1 }
      for (i = 2; !bad && i <= n; i++) if (at[w[i]] <= at[w[i-1]]) { printf "%s (line %d) before %s (line %d)\n", w[i], at[w[i]], w[i-1], at[w[i-1]]; bad = 1 }
      exit bad
    }' <<<"$output"
}

# snapshot_line_names SCRIPT: the line names SCRIPT's (triage-tick.sh's) usage header documents for
# `snapshot`, one per line, in order (the first word of each line at the header's 7-space indent
# between "prints:" and "Reasons:"). A bound on the snapshot's size uses their count, so it follows
# the header rather than a fixed number. The caller passes the path: a helper every suite loads must
# not name a script, or dev/coverage.sh --changed picks every suite for a change to it (#248).
snapshot_line_names() {
  awk '/^set -euo/ { exit } /prints:$/ { on = 1; next } /^#     Reasons:/ { on = 0 }
    on && /^#       [a-z]/ { print $2 }' "${1:?snapshot_line_names: SCRIPT path required}"
}

# `run ! cmd` is how a mid-test negative assertion fails (#134); bats >= 1.5 has it.
bats_require_minimum_version 1.5.0

# register_lane WORKTREE: an active lanes.tsv row (lane-claim.sh add) for WORKTREE, so lane-safety.sh
# treats the owner-less calls from it as a known lane (deny) rather than the owner's session (ask).
register_lane() {
  mkdir -p "$ORCHESTRATE_STATE_DIR/o__r"
  printf '%s\twork/1-x\t1\tsrc/\tlane-agent\tactive\n' "$1" >>"$ORCHESTRATE_STATE_DIR/o__r/lanes.tsv"
}
