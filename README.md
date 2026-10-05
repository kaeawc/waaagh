# waaagh

A Claude Code plugin that runs a repository's delivery loop with parallel agents: plan from the
issue tracker, implement in isolated lanes, review, merge, and verify what merged.

Codex lanes write the code. Claude subagents validate and review it. Merging, branch upkeep,
tracker hygiene and post-merge verification run as single-pass roles built on small, tested `gh`
scripts, so the expensive model reads verdict lines instead of raw API output.

## Install

```
/plugin marketplace add kaeawc/waaagh
/plugin install waaagh@waaagh
```

Then ask for it (`/waaagh:orchestrate`, or "orchestrate the open bugs in this repo").

### Requirements

- `gh` (authenticated), `jq`, `git`; `jj` is supported when the checkout is colocated
- the OpenAI [Codex CLI](https://github.com/openai/codex), authenticated, for implementation lanes
- `bats` and `shellcheck` only if you want to run the self-tests

## What is in it

| Path | What |
|---|---|
| `skills/orchestrate/SKILL.md` | The doctrine: roles and routing, isolation, briefs, evidence, the campaign loop, lane cap, merge policy, interrupts, PR lifecycle and takeover |
| `skills/orchestrate/roles/` | Brief templates for the standing roles: merge bot, rebase bot, hygiene bot, verification, implementation lane, PR doctor, conflict lane, reviewer |
| `skills/orchestrate/scripts/` | The scripts below, with a stubbed-`gh` self-test |
| `agents/sol-implementer.md` | The implementation lane: wraps one supervised `codex exec` run and verifies it |
| `bin/codex-lane-run.sh` | Lane runner: spec/worktree identity check, spec snapshot, stall and hard timeouts |

### Scripts

| Script | Purpose |
|---|---|
| `pr-ready.sh` | One verdict per open PR: `READY`, `WAIT`, `BLOCK` (with reasons) or `SKIP` |
| `pr-merge.sh` | Merge one PR after re-checking head, author, draft and fork state; honours the red-main hold; `--admin` only in the fast path and only with evidence |
| `main-health.sh` | Sets or clears the merge hold from the default branch's newest completed runs |
| `campaign.sh` | Campaign ledger: merge mode, lane cap, merged-since-verification, pause label |
| `issues-ranked.sh` | Open issues updated recently, priority labels and bugs first |
| `issue-candidates.sh` | Leads for already-fixed issues and duplicate titles |
| `issue-close.sh` | Close an issue as fixed or duplicate, with required evidence, and log it |
| `device-lock.sh` | Exclusive lock for emulators, simulators and attached hardware |
| `pr-intake.sh`, `pr-claim.sh` | Find and claim your own open PRs across sessions |
| `fingerprint.sh`, `excerpt.sh` | Key validation results by tree content; excerpt long logs |

## Defaults

| Setting | Default | Override |
|---|---|---|
| Implementation lanes | 16 when the bots are idle, 12 while one works, 4 during verification | `ORCHESTRATE_LANES=16,12,4` |
| Verification cadence | every 16 merged PRs | `ORCHESTRATE_VERIFY_EVERY` |
| Merge mode | conservative; fast path above 20 open PRs | `ORCHESTRATE_FAST_PATH_OVER` |
| Admin merges outside the fast path | refused | `ORCHESTRATE_ADMIN_MERGE=1` |
| Pause labels | `orchestrate-pause`, `fleet-pause` | `ORCHESTRATE_PAUSE_LABELS` |
| PR author | the authenticated `gh` user | `ORCHESTRATE_AUTHOR`, `--author` |
| State directory | `~/.claude/orchestrate/<owner>__<repo>/` | `ORCHESTRATE_STATE_DIR` |
| Codex model for the Sol lane | `gpt-6.1-sol` | `CODEX_LANE_SOL_MODEL` |

Repository-specific rules (advisory checks, CI classifier, device rules, forbidden test suites) are
not configured in this plugin. The skill reads them from your Claude memory for that repository
and from `<state dir>/lane-rules.md`.

## Safety properties

- Only PRs authored by the authenticated user (plus authors you name) are merged; fork-head PRs and
  drafts never are.
- A merge is refused when the head moved since it was judged, and while the default branch is red.
- Admin merges need the fast path (or explicit authorization) and a logged reason.
- The hygiene bot can close issues only as fixed-by-a-merged-PR or duplicate-of-an-open-issue, with
  evidence in the closing comment; every close is logged.
- No role kills processes by pattern, and a device has one owner at a time.

## Development

```
bats skills/orchestrate/scripts/selftest.bats
(cd skills/orchestrate/scripts && shellcheck -x ./*.sh)
claude --plugin-dir .
```

## License

MIT. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
