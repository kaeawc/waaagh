# Learnings — what the campaign writes down for its next session

An orchestrator loses most of its state on compaction, and a new session starts with none. The
campaign's operating knowledge — owner rules, hazards, procedural fixes — therefore lives on disk,
one file per learning, in `<state dir>/learnings/`, written with `scripts/learning.sh`. Memory
keeps the repository's standing configuration; learnings keep what the campaign found out while
running.

## When to write one

Write a learning at once, in the same turn, on either trigger:

1. **An owner instruction that changes how work is routed, delegated or closed** (`--trigger
   owner`). Examples: "no cloud lanes for this repo", "dispatch without asking me to click",
   "close only after device evidence". An amendment to an earlier rule is a new learning that
   supersedes the old one (below), not an edit in place.
2. **A failure whose fix is procedural, not code** (`--trigger procedural`): a tool limit, a rate
   limit, a delivery gap, a permission the session does not have. Examples: "merge-freeze messages
   to another session can expire undelivered", "lane drivers report interim 'waiting on background
   work' stops", "scheduled routines cannot be deleted by the tool". A failure fixed by a code
   change is an issue or a PR, not a learning.

Do not write learnings for one-off events, for anything a script already enforces, or for facts
the next session can read from GitHub.

```bash
"$SCRIPTS/learning.sh" add --title "Merge-freeze messages can expire undelivered" \
  --rule "After sending a merge freeze to another session, confirm it arrived before merging." \
  --why "A queued message expired while the target was busy; it merged into a freeze." \
  --how "Re-read the target's transcript for the freeze; re-send if absent." \
  --source "2026-11-07 auto-mobile: PR 412 merged during a freeze" \
  --trigger procedural --scope global --roles merge-bot,orchestrator
```

Every learning carries the rule, **Why** (the event or reason, so a later reader can judge edge
cases), **How to apply**, its date and the source event. `--roles` tags who must read it: role
template names (`merge-bot`, `implementation-lane`, `review`, ...), `orchestrator` for you, or
`all`.

## Scope: local or upstream

- `--scope repo`: true of this repository only (its CI, its devices, its owner's preferences).
  It stays in the state directory.
- `--scope global`: true of every repository a campaign could run on (a GitHub or tool
  behaviour, a gap in this doctrine). Propose it upstream as a waaagh doctrine change:
  `learning.sh upstream --id ID` prints the issue; with the owner's go-ahead for writes to
  kaeawc/waaagh, `--create` opens it and records the URL in the learning, once. Keep applying the
  learning locally until a waaagh release carries the change.

## Consolidation

`learning.sh status` says `consolidation_due=yes` once `ORCHESTRATE_LEARNINGS_CONSOLIDATE_EVERY`
(default 10) learnings were added since the last pass. Run the pass at the next quiet checkpoint:

1. `learning.sh consolidate` lists `dup` pairs (same normalized title or rule) and global
   learnings not yet upstreamed. Read the index for near-duplicates it cannot see.
2. Fold each duplicate or amended rule into the one that stays: `learning.sh supersede --id OLD
   --by NEW --note "why"`. Drop a rule nothing replaces (the owner reversed it, the tool was
   fixed): `learning.sh retire --id ID --note "why"`. The old file goes; one history line stays
   in the keeper and in `learnings/history.log` (`learning.sh list --all` shows them).
3. `learning.sh consolidate --done` records the pass.

## What briefs load

The index (`learnings/INDEX.md`, recorded in `campaign.json` as `.learnings.index`) is one line
per active learning. A brief never loads the whole store: every role runs
`learning.sh brief --role <its role>` once, which prints the index plus the full text of the
entries tagged with that role or `all` (`roles/_common.md` rule 12). You load
`learning.sh brief --role orchestrator` at session start and after a compaction, then
`learning.sh show --id ID` for any other entry the index points to.
