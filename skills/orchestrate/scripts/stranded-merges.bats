#!/usr/bin/env bats
# stranded-merges.sh (#410): a PR merged into a stacked base after that base's own PR had merged
# never reaches the default branch (#404 merged into wt-session-hint-395 after #403 was
# squash-merged). Stubbed gh: pulls, compare, files and contents come from fixture files in $FX.
# Run: bats stranded-merges.bats

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_READ_SLEEP=0
  export ORCHESTRATE_NOW=1795000000   # 2026-11-18T07:06:40Z
  # gh stub. Fixtures: closed.json (closed PRs, REST shape), parent-<branch>.json (PRs whose head is
  # <branch>), compare-<base>...<head> (the status), files-<n> (added files, "<blob sha><TAB><path>"
  # lines, as the script's --jq prints them), tree (main's files, "<path>[<TAB><blob sha>]"), tree-truncated (the tree read says truncated), have-<path with / as _> (the contents
  # read finds the path on main), fail-<n> (pulls/<n>/files answers 500).
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"; all=${all% --include}   # gh-read.sh adds --include to api reads
echo "$all" >>"$FX/calls"
case "$all" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  "api repos/o/r/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1") cat "$FX/closed.json" ;;
  "api repos/o/r/pulls?state=closed&sort=updated&direction=desc&per_page=100&page="*) echo '[]' ;;
  "api repos/o/r/pulls?head=o:"*) b=${all#*head=o:}; b=${b%%&*}; cat "$FX/parent-${b//\//_}.json" 2>/dev/null || echo '[]' ;;
  "api repos/o/r/compare/"*) s=${all#api repos/o/r/compare/}; s=${s%% *}; cat "$FX/compare-${s//\//_}" ;;
  "api --paginate repos/o/r/pulls/"*"/files?per_page=100 --jq "*)
    n=${all#api --paginate repos/o/r/pulls/}; n=${n%%/*}
    [ ! -f "$FX/fail-$n" ] || { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    cat "$FX/files-$n" 2>/dev/null || true ;;
  "api repos/o/r/git/trees/main?recursive=1")
    if [ -f "$FX/tree-truncated" ]; then echo '{"truncated":true,"tree":[]}'
    else jq -Rn '{truncated: false, tree: [inputs | split("\t") | {path: .[0], sha: (.[1] // "x"), type: "blob"}]}' <"$FX/tree" 2>/dev/null || echo '{"truncated":false,"tree":[]}'; fi ;;
  "api repos/o/r/contents/"*"?ref=main --silent")
    p=${all#api repos/o/r/contents/}; p=${p%%\?*}
    [ -f "$FX/have-${p//\//_}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# pr N BASE MERGED_AT MERGE_SHA [HEAD_SHA]: one closed PR in REST shape.
pr() { jq -n --argjson n "$1" --arg b "$2" --arg m "$3" --arg c "$4" --arg h "${5:-h$1}" \
  '{number: $n, base: {ref: $b}, head: {ref: "br\($n)", sha: $h}, merged_at: (if $m == "" then null else $m end), merge_commit_sha: $c}'; }
closed() { jq -s . >"$FX/closed.json"; }
sm() { run "$SCRIPTS/stranded-merges.sh" --repo o/r "$@"; }

@test "a child merged into a base whose PR already merged without it is STRANDED (exit 3)" {
  { pr 404 hint-395 2026-11-17T01:11:58Z c404; pr 403 main 2026-11-17T01:11:54Z m403; pr 9 main "" ""; } | closed
  pr 403 main 2026-11-17T01:11:54Z m403 p403head | jq -s . >"$FX/parent-hint-395.json"
  echo behind >"$FX/compare-c404...p403head"
  printf 's1\tscripts/wt-root.sh\ns2\tscripts/worktree-guard.sh\n' >"$FX/files-404"
  sm
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = $'404\tSTRANDED\tbase=hint-395\tparent=#403\tmissing on main: 2/2 added files (scripts/wt-root.sh scripts/worktree-guard.sh); retarget a new PR with its changes to main' ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "checked=1 stranded=1 relanded=0 unverified=0 ok=0 since=2026-10-19" ]
}

@test "a child the parent's final head contains is OK; one whose added files reached main another way is RELANDED" {
  { pr 11 stack-a 2026-11-17T05:09:00Z c11; pr 12 stack-b 2026-11-17T05:38:00Z c12; } | closed
  pr 21 main 2026-11-17T06:00:00Z m21 p21 | jq -s . >"$FX/parent-stack-a.json"
  pr 22 stack-a 2026-11-17T05:09:00Z m22 p22 | jq -s . >"$FX/parent-stack-b.json"
  echo ahead >"$FX/compare-c11...p21"
  echo behind >"$FX/compare-c12...p22"
  printf 'sa\tsrc/a.go\nsb\tapps/old/b.rs\n' >"$FX/files-12"; printf 'src/a.go\tsa\napps/new/b.rs\tzz\n' >"$FX/tree"
  sm
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'11\tOK\tbase=stack-a\tparent=#21\tcontained in the head #21 merged with' ]
  [ "${lines[1]}" = $'12\tRELANDED\tbase=stack-b\tparent=#22\tnot in #22'"'"'s merged head, but its 2 added files are on main (1 under another directory)' ]
  [ "${lines[2]}" = "checked=2 stranded=0 relanded=1 unverified=0 ok=1 since=2026-10-19" ]
}

@test "no added files to check is UNVERIFIED; a base with no PR is ORPHAN; an open parent is PENDING" {
  { pr 31 stack-c 2026-11-17T05:00:00Z c31; pr 32 lonely 2026-11-17T05:00:00Z c32; pr 33 stack-d 2026-11-17T05:00:00Z c33; } | closed
  pr 41 main 2026-11-17T04:00:00Z m41 p41 | jq -s . >"$FX/parent-stack-c.json"
  echo diverged >"$FX/compare-c31...p41"
  jq -n '[{number: 43, state: "open", merged_at: null, head: {sha: "p43"}}]' >"$FX/parent-stack-d.json"
  sm
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = $'31\tUNVERIFIED\tbase=stack-c\tparent=#41\tnot in #41'"'"'s merged head and it added no files: compare its diff with main by hand' ]
  [ "${lines[1]}" = $'32\tORPHAN\tbase=lonely\tparent=-\tno PR from lonely ever merged or is open: its changes are only on lonely' ]
  [ "${lines[2]}" = $'33\tPENDING\tbase=stack-d\tparent=#43\tthe base'"'"'s PR is still open' ]
}

@test "--since drops older merges; PRs into the default branch and unmerged ones are never checked" {
  { pr 51 stack-e 2026-09-01T00:00:00Z c51; pr 52 main 2026-11-17T00:00:00Z c52; pr 53 stack-e "" ""; } | closed
  sm --since 30
  [ "$status" -eq 0 ]
  [ "$output" = "checked=0 stranded=0 relanded=0 unverified=0 ok=0 since=2026-10-19" ]
  run grep -c 'head=o:' "$FX/calls"
  [ "$output" = 0 ]
  sm --since 120
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = $'51\tORPHAN\tbase=stack-e\tparent=-\tno PR from stack-e ever merged or is open: its changes are only on stack-e' ]
}

@test "a truncated tree falls back to one contents read per added file, at most 20" {
  pr 71 stack-g 2026-11-17T00:00:00Z c71 | closed
  pr 72 main 2026-11-17T00:00:00Z m72 p72 | jq -s . >"$FX/parent-stack-g.json"
  echo behind >"$FX/compare-c71...p72"
  touch "$FX/tree-truncated" "$FX/have-f1"
  for i in $(seq 1 25); do printf 's%s\tf%s\n' "$i" "$i"; done >"$FX/files-71"
  sm
  [ "$status" -eq 3 ]
  [[ "${lines[0]}" == $'71\tSTRANDED\tbase=stack-g\tparent=#72\tmissing on main: 19/20 added files (f2 f3 '* ]]
  run grep -c '/contents/' "$FX/calls"
  [ "$output" = 20 ]
}

@test "review #417: a moved file is its blob or a unique name, never a generic one like SKILL.md" {
  pr 81 stack-h 2026-11-17T00:00:00Z c81 | closed
  pr 82 main 2026-11-17T00:00:00Z m82 p82 | jq -s . >"$FX/parent-stack-h.json"
  echo behind >"$FX/compare-c81...p82"
  printf 'k1\tskills/new/SKILL.md\nk2\tskills/new/index.ts\n' >"$FX/files-81"
  printf 'skills/old/SKILL.md\tother1\nweb/index.ts\tother2\n' >"$FX/tree"
  sm
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = $'81\tSTRANDED\tbase=stack-h\tparent=#82\tmissing on main: 2/2 added files (skills/new/SKILL.md skills/new/index.ts); retarget a new PR with its changes to main' ]
  # The same blob under another path, even with a generic name, is the file moved.
  printf 'skills/moved/SKILL.md\tk1\nweb/index.ts\tk2\n' >"$FX/tree"
  sm
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == $'81\tRELANDED\t'*"(2 under another directory)" ]]
}

@test "review #417: a base with an open PR besides merged ones is PENDING, not STRANDED" {
  pr 91 develop 2026-11-17T05:00:00Z c91 | closed
  { pr 92 main 2026-11-10T00:00:00Z m92 p92; jq -n '{number: 93, state: "open", merged_at: null, head: {sha: "p93"}}'; } | jq -s . >"$FX/parent-develop.json"
  echo behind >"$FX/compare-c91...p92"
  echo ahead >"$FX/compare-c91...p93"
  sm
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'91\tPENDING\tbase=develop\tparent=#93\tnot in #92'"'"'s merged head; the base'"'"'s open PR #93 carries it' ]
  # An open PR whose head does not hold the child (abandoned, or the base made again) hides nothing.
  echo diverged >"$FX/compare-c91...p93"
  sm
  [ "$status" -eq 3 ]
  [[ "${lines[0]}" == $'91\tUNVERIFIED\tbase=develop\tparent=#92\t'* ]]
}

@test "review #417: a truncated tree with every checked file present is UNVERIFIED; paths are URL-encoded" {
  pr 71 stack-g 2026-11-17T00:00:00Z c71 | closed
  pr 72 main 2026-11-17T00:00:00Z m72 p72 | jq -s . >"$FX/parent-stack-g.json"
  echo behind >"$FX/compare-c71...p72"
  touch "$FX/tree-truncated"
  for i in $(seq 1 25); do printf 's%s\tdocs/f#%s\n' "$i" "$i"; touch "$FX/have-docs_f%23$i"; done >"$FX/files-71"
  sm
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = $'71\tUNVERIFIED\tbase=stack-g\tparent=#72\tnot in #72'"'"'s merged head; 20 of its 25 added files checked (all on main), the rest were not: compare by hand' ]
  grep -q '^api repos/o/r/contents/docs/f%231?ref=main --silent$' "$FX/calls"
}

@test "an unreadable read is reported, not guessed (exit 4); usage errors are exit 2" {
  pr 61 stack-f 2026-11-17T00:00:00Z c61 | closed
  pr 62 main 2026-11-17T00:00:00Z m62 p62 | jq -s . >"$FX/parent-stack-f.json"
  echo behind >"$FX/compare-c61...p62"
  touch "$FX/fail-61"
  run --separate-stderr "$SCRIPTS/stranded-merges.sh" --repo o/r
  [ "$status" -eq 4 ]
  [ "${lines[0]}" = $'61\tunreadable\tbase=stack-f\tparent=#62\tthe PR\'s files could not be read' ]
  run "$SCRIPTS/stranded-merges.sh" --repo o/r --since x
  [ "$status" -eq 2 ]
  run "$SCRIPTS/stranded-merges.sh" --bogus
  [ "$status" -eq 2 ]
}
