#!/usr/bin/env bats
# learning.sh import (#421): Claude Code feedback memories become campaign learnings, once each.
# Run: bats learning-import.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_NOW=1794096000 # 2026-11-08
  STATE="$ORCHESTRATE_STATE_DIR/o__r"
  M="$BATS_TEST_TMPDIR/memory"; mkdir -p "$M"
  cat >"$M/MEMORY.md" <<'EOF'
- [Ten lanes](feedback_ten_lanes_20261026.md) — index, never imported
EOF
  cat >"$M/feedback_ten_lanes_20261026.md" <<'EOF'
---
name: ten-lanes-20261026
description: "Owner 2026-10-26: keep up to 10 worklanes running"
metadata:
  type: feedback
---
The owner said on 2026-10-26: keep up to 10 worklanes going.

**Why:** throughput matters more than per-change device checks now.

**How to apply:**
- When a lane finishes, start another.
- Ignore the CPU cap.

## Notes
Not part of the learning.
EOF
  cat >"$M/feedback_old_rule.md" <<'EOF'
---
name: old-rule
description: SUPERSEDED by ten-lanes — Owner 2026-10-01 — four lanes max
type: feedback
---
Four lanes at most.

**Why:** the host was small.

**How to apply:** cap at 4.
EOF
  cat >"$M/feedback_no_why.md" <<'EOF'
---
name: no-why
description: A rule with no reason
type: feedback
modified: 2026-10-05T10:00:00Z
---
Do the thing.
EOF
  cat >"$M/project_layout.md" <<'EOF'
---
name: layout
description: Where the code lives
type: project
---
src/ holds the code.

**Why:** history.

**How to apply:** look there.
EOF
  cat >"$M/feedback_dated_by_modified.md" <<'EOF'
---
name: read-the-issue
description: Read the issue before writing Closes
metadata:
  type: feedback
  modified: 2026-09-14T08:00:00Z
---
Run gh issue view N first.

**Why:** a worktree name pointed at the wrong issue.

**How to apply:** check the title matches.
EOF
}
L() { "$SCRIPTS/learning.sh" "$1" --repo o/r "${@:2}"; }

@test "a dry run lists the feedback memories it would add and writes nothing" {
  run L import --memory-dir "$M"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'would add\t2026-09-14\tRead the issue before writing Closes' ]
  [ "${lines[1]}" = $'would add\t2026-10-26\tOwner 2026-10-26: keep up to 10 worklanes running' ]
  [ "${lines[2]}" = "memories=5 feedback=4 new=2 known=0 superseded=1 incomplete=1 failed=0" ]
  [ ! -e "$STATE" ]   # not even the state directory
}

@test "--apply writes each one with its rule, why and how, and a second run adds nothing" {
  run L import --memory-dir "$M" --apply --roles orchestrator,implementation-lane
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "memories=5 feedback=4 new=2 known=0 superseded=1 incomplete=1 failed=0" ]
  f="$STATE/learnings/2026-10-26-owner-2026-10-26-keep-up-to-10-worklanes-running.md"
  [ "${lines[1]}" = $'added\t'"$f" ]
  grep -qx 'source: memory:ten-lanes-20261026' "$f"
  grep -qx 'roles: orchestrator,implementation-lane' "$f"
  grep -qx 'trigger: owner' "$f"
  grep -qx 'scope: repo' "$f"
  grep -qx '\*\*Rule:\*\* The owner said on 2026-10-26: keep up to 10 worklanes going.' "$f"
  grep -qx '\*\*Why:\*\* throughput matters more than per-change device checks now.' "$f"
  grep -qx -- '- Ignore the CPU cap.' "$f"
  grep -qx 'Not part of the learning.' "$f"   # kept: later amendments live after How to apply
  run L import --memory-dir "$M" --apply
  [ "$status" -eq 0 ]
  [ "$output" = "memories=5 feedback=4 new=0 known=2 superseded=1 incomplete=1 failed=0" ]
  run L list
  [ "${#lines[@]}" -eq 2 ]
  # Retired after the import: still known, never imported again (review #423).
  L retire --id 2026-10-26-owner-2026-10-26-keep-up-to-10-worklanes-running --note "folded"
  run L import --memory-dir "$M" --apply
  [ "$output" = "memories=5 feedback=4 new=0 known=2 superseded=1 incomplete=1 failed=0" ]
}

@test "review #423: a taken id or an empty slug gets the memory's name; CRLF memories parse; long titles cut at a word" {
  N="$BATS_TEST_TMPDIR/n"; mkdir -p "$N"
  for x in a b; do printf -- '---\nname: dup-%s-20261101\ndescription: Same title\ntype: feedback\n---\nRule %s.\n\n**Why:** w.\n\n**How to apply:** h.\n' "$x" "$x" >"$N/f_$x.md"; done
  printf -- '---\nname: jp-20261102\ndescription: 日本語のルール\ntype: feedback\n---\nルール.\n\n**Why:** w.\n\n**How to apply:** h.\n' >"$N/f_jp.md"
  printf -- '---\r\nname: crlf-20261103\r\ndescription: Windows line ends\r\ntype: feedback\r\n---\r\nRule.\r\n\r\n**Why:** w.\r\n\r\n**How to apply:** h.\r\n' >"$N/f_crlf.md"
  # Two long titles that share their first 60 characters on one date (the slug keeps 50).
  for x in c d; do printf -- '---\nname: longdup-%s-20261105\ndescription: %s tail %s\ntype: feedback\n---\nR.\n\n**Why:** w.\n\n**How to apply:** h.\n' "$x" "$(printf 'same%.0s ' $(seq 1 15))" "$x" >"$N/g_$x.md"; done
  long=$(printf 'word%.0s ' $(seq 1 40))
  printf -- '---\nname: long-20261104\ndescription: %s\ntype: feedback\n---\nRule.\n\n```\n**Why:** inside a fence\n```\n\n**Why:** w.\n\n**How to apply:** h.\n' "$long" >"$N/f_long.md"
  run L import --memory-dir "$N"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'would add\t2026-11-01\tSame title' ]
  [ "${lines[1]}" = $'would add\t2026-11-01\tdup-b-20261101: Same title' ]
  [ "${lines[2]}" = $'would add\t2026-11-03\tWindows line ends' ]
  [ "${lines[3]}" = $'would add\t2026-11-02\tjp-20261102: 日本語のルール' ]
  [[ "${lines[4]}" == $'would add\t2026-11-04\tword word '*"word" ]]
  [[ "${lines[5]}" == $'would add\t2026-11-05\tsame same '* ]]
  [[ "${lines[6]}" == $'would add\t2026-11-05\tlongdup-d-20261105: same same '* ]]
  [ "${lines[7]}" = "memories=7 feedback=7 new=7 known=0 superseded=0 incomplete=0 failed=0" ]
  run L import --memory-dir "$N" --apply
  [ "${lines[7]}" = "memories=7 feedback=7 new=7 known=0 superseded=0 incomplete=0 failed=0" ]
  f=$(ls "$STATE"/learnings/2026-11-04-*.md)
  grep -qxF '**Rule:** Rule.' "$f"
  grep -qxF '**Why:** inside a fence' "$f"     # inside the fence: part of the rule, not its Why
  grep -qxF '**Why:** w.' "$f"
}

@test "review #423: a title cut under a C locale keeps valid UTF-8" {
  N="$BATS_TEST_TMPDIR/u"; mkdir -p "$N"
  printf -- '---\nname: cjk-20261106\ndescription: %s\ntype: feedback\n---\nR.\n\n**Why:** w.\n\n**How to apply:** h.\n' "x$(printf 'ルール%.0s' $(seq 1 50))" >"$N/f.md"   # the x makes the 120-byte cut split a character
  LC_ALL=C run L import --memory-dir "$N"
  [ "$status" -eq 0 ]
  printf '%s' "${lines[0]}" | iconv -f UTF-8 -t UTF-8 >/dev/null
  t=${lines[0]#*$'\t'*$'\t'}
  [ "$(printf '%s' "$t" | wc -c | tr -d ' ')" -le 120 ]   # cut, not doubled
  [[ "$t" == xルール* ]]
}

@test "import needs an existing --memory-dir" {
  run L import
  [ "$status" -eq 2 ]
  run L import --memory-dir "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 2 ]
}
