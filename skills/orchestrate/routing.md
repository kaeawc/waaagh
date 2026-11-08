# Issue routing — exactly one route per actionable issue

A campaign that runs both local lanes (on the owner's machine, with devices) and cloud lanes (Linux
agents without devices) splits the tracker by **route label**, not by area. Per-area lanes let a
local lane and a cloud lane both fix the same issue; one route per issue removes that duplicate
work.

## Label schema

| Label | Meaning |
|---|---|
| `cloud-ready` | A Linux agent can finish it without a device: TypeScript, CI, scripts, docs, JVM unit tests, design or reading research |
| `needs-local:android-emulator` | Needs a local Android emulator |
| `needs-local:ios-simulator` | Needs a local iOS simulator |
| `needs-local:macos-xcode` | Needs macOS with Xcode (build, signing, Xcode-only tooling) |
| `needs-local:research` | Something must be measured locally before anyone can fix it |

A repository may use other local types: any label starting `needs-local:` is a local route. Put a
repository's own schema in `<state dir>/routes.tsv` (`<label><TAB><color><TAB><description>`);
without that file the five above are the schema.

**Bootstrap** once per repository, before the first router pass:
`"$SCRIPTS/issue-route.sh" labels --dry-run`, then without `--dry-run`. It runs `gh label create`
only for schema labels the repository lacks and never edits an existing label.

## The invariant

Every open, actionable issue carries **exactly one** route label. An issue labelled
`physical-device`, `needs-human`, `blocked`, `desktop`, `epic` or `needs-decision` is not actionable
and gets no route (it is skipped, not routed). Every local route also carries one comment:

> Local work needed: <what>. Type: <bug, feature, measurement…>. Requires: <device, OS or API level, setup>.

`"$SCRIPTS/issue-route.sh" status` checks it: route counts, then the `unrouted` and `multi` issues.
Run it at the start of a campaign and whenever the plan is refreshed. `unrouted` > 0 → launch the
router (`roles/router.md`). `multi` > 0 → the router fixes those first. Labels change only through
`issue-route.sh set`, which adds the new route and removes every other one in the same edit, posts
the local-work comment once, and retries through the REST API when `gh issue edit` hits a secondary
rate limit.

## Dispatch

- **Cloud dispatch takes only `cloud-ready`:**
  `"$SCRIPTS/issues-ranked.sh" --route cloud-ready --skip-in-pr`.
- **Local lanes take only `needs-local:*`:**
  `"$SCRIPTS/issues-ranked.sh" --route 'needs-local:*' --skip-in-pr`, and only types this host can
  serve (`--route needs-local:android-emulator`).
- **Sweep before local lanes.** Device time is scarce, and many `needs-local:*` issues are already
  fixed on the default branch. Before the first local lane, and again about every 16 merges, run
  the local sweep (`roles/local-sweep.md`), built on `"$SCRIPTS/issue-candidates.sh" sweep`. It
  sorts the local issues into A (merged fix plus a PASS device verdict on every touched platform:
  closed with evidence), B (merged fix, only device verification left), C (still needs
  implementation) and D (unclear). Schedule B as one verify batch per platform
  (`roles/verify-batch.md`: one device, one private daemon, a list of issues, a verdict comment per
  issue) and give implementation lanes only C. One batch replaces a lane start per issue.
- An unrouted issue is dispatched nowhere until it is routed. An issue whose route turns out wrong
  is re-routed with `issue-route.sh set`, never worked from both sides.
