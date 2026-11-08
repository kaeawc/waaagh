# Device-to-cloud handoff — captured fixtures travel with the issue

A local lane (research spike, verification, verify batch, implementation lane with a device)
often captures evidence on a device or simulator — UI hierarchy dumps, logs, protocol traces — and
splits off a `cloud-ready` follow-up (a parser, a fixture-driven test) for a Linux agent. A cloud
session reaches GitHub and the repository, **nothing else**: not the lane's worktree, not
`~/.claude/orchestrate/…/evidence-…`, not the host. A follow-up that quotes an excerpt and names a
local path leaves the cloud lane two choices, stall or invent fixtures, and invented fixtures break
the rule that parser fixtures are captured, never hand-written.

So the split has a contract with three sides.

## 1. The local lane attaches every fixture the cloud work needs

When you file (or ask the orchestrator to file) a `cloud-ready` follow-up that depends on output
you captured:

- **Every fixture goes onto GitHub.** A local path is never enough, and an excerpt is never the
  fixture. Text up to about 60,000 characters per comment (GitHub's limit is 65,536): post one
  issue comment per fixture or a few small ones together, each in its own `<details>` block:

  ````
  Fixtures for #<N>: captured <date> on <device, OS or API level> at <tested SHA>. Commit verbatim.
  <details><summary>path/in/repo/fixture-name.xml (<bytes> bytes, sha256 <hash>)</summary>

  ```xml
  …the complete captured output, untrimmed…
  ```
  </details>
  ````

  The summary names the repository path the cloud lane commits it to, its size and its sha256
  (`shasum -a 256`), so the cloud lane can prove it committed the bytes unchanged.
- **Too big or binary** (screenshots, recordings, archives): a small **fixtures-only PR** that adds
  just the files under the repository's fixtures directory, title containing "fixtures", body
  `Fixtures for #<N>` (that reference links it to the issue). A lane that may not push leaves the
  files under `{{STATE}}/handoff/<N>/` with a `MANIFEST` (repo path, bytes, sha256 per line) and
  reports it; the orchestrator opens the PR.
- **Say so in the issue body**: a line `Fixtures: <comment URL or PR URL>`. The body may quote an
  excerpt to explain the shape, but it points at the full fixtures.
- Your report names the follow-up issue and where its fixtures are. A follow-up you cannot attach
  fixtures to (capture failed, too sensitive to publish) stays `needs-local:*`, not `cloud-ready`.

## 2. The dispatcher checks before it creates the cloud session

Before each `RemoteTrigger create` (`roles/cloud-dispatch.md`), `cloud-dispatch.sh payload` runs
the check itself unless `--fixtures` is given; `cloud-dispatch.sh fixtures --issue N` runs it alone.
It reads the issue, its comments and (only when needed) its timeline through `gh-read.sh`:

- **Fixtures needed** when the issue carries the `needs-fixtures` label, `--require` is given, or
  the body or a comment mentions fixtures, captured output or a local evidence path.
- **Carried** when the body or a comment holds a `<details>` block, or an open or merged PR whose
  title names fixtures cross-references the issue. It prints `fixtures <url>...`, and the brief
  points the cloud lane at exactly those URLs.
- **Exit 5, refused**: needed but not carried (the message names any local path it found). Do not
  dispatch. `cloud-dispatch.sh queue drop N`, then route it back to the lane that captured them:
  `issue-route.sh set --issue N --route needs-local:<type> --what "attach the captured fixtures to
  this issue (device-cloud-handoff.md)" --requires "<the device the capture needs>"`. Once they are
  attached, route it `cloud-ready` again and re-queue it. If the files still exist on this host
  (the lane's evidence directory), the orchestrator may post them itself instead, as in section 1.
- **Exit 7**: the issue could not be read. Do not dispatch; retry on a later batch.

Every issue the check passes as `fixtures none` (no mention of fixtures) dispatches as before.

## 3. The cloud brief names the fixtures exactly

The per-issue brief (`roles/cloud-session-brief.md`) gets "Commit the captured fixtures from
<url>… verbatim; never hand-write, trim or regenerate them." in its implementation step — never a
vague "use the captured fixtures". A cloud lane that finds the fixtures missing or wrong (sha256
mismatch, truncated) does not invent replacements: it comments once on the issue and stops, as the
brief's blocked rule says.
