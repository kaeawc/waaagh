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
  [ "${lines[2]}" = "memories=5 feedback=4 new=2 known=0 superseded=1 incomplete=1" ]
  [ ! -e "$STATE/learnings" ]
}

@test "--apply writes each one with its rule, why and how, and a second run adds nothing" {
  run L import --memory-dir "$M" --apply --roles orchestrator,implementation-lane
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "memories=5 feedback=4 new=2 known=0 superseded=1 incomplete=1" ]
  f="$STATE/learnings/2026-10-26-owner-2026-10-26-keep-up-to-10-worklanes-running.md"
  [ "${lines[1]}" = $'added\t'"$f" ]
  grep -qx 'source: memory:ten-lanes-20261026' "$f"
  grep -qx 'roles: orchestrator,implementation-lane' "$f"
  grep -qx 'trigger: owner' "$f"
  grep -qx 'scope: repo' "$f"
  grep -qx '\*\*Rule:\*\* The owner said on 2026-10-26: keep up to 10 worklanes going.' "$f"
  grep -qx '\*\*Why:\*\* throughput matters more than per-change device checks now.' "$f"
  grep -qx -- '- Ignore the CPU cap.' "$f"
  run grep -c 'Not part of the learning' "$f"
  [ "$output" = 0 ]
  run L import --memory-dir "$M" --apply
  [ "$status" -eq 0 ]
  [ "$output" = "memories=5 feedback=4 new=0 known=2 superseded=1 incomplete=1" ]
  run L list
  [ "${#lines[@]}" -eq 2 ]
}

@test "import needs an existing --memory-dir" {
  run L import
  [ "$status" -eq 2 ]
  run L import --memory-dir "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 2 ]
}
