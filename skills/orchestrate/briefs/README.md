# Standard cloud briefs

`implement.md` and `repair.md` are the templates `cloud-dispatch.sh briefs install` writes into a
target repository as `.claude/briefs/K.md` (see `../roles/cloud-dispatch.md`, "Briefs in the
repository"). Their first line carries the version, `<!-- waaagh-brief K vV ... -->`, and
`briefs check` compares an installed copy's version with the template's: that version is how a cloud
session's repository learns its copy is outdated.

## The bump rule

Any change to a brief's body (everything below the first line) needs a version bump in the same PR:

1. Raise `vV` in the brief's first line by one.
2. Append the new row to `versions.tsv`: `K<TAB>V<TAB>hash`, where the hash is
   `tail -n +2 K.md | git hash-object --stdin`. Keep the old rows.

`brief-versions.bats` fails when a body changed but its version did not, when a version is not above
the highest one recorded, or when the row is missing, and its message prints the row to append. No
test hardcodes a version, so a bump needs no test edit. A whitespace-only change counts too: the hash
covers every byte of the body.

The check reads a committed manifest instead of diffing against the merge base, so it needs no git
history: CI's shallow checkout has none to compare against.

## Size

A brief here never travels in the dispatch payload: `payload --brief-ref K` sends the one-line
prompt, and the cloud session reads `.claude/briefs/K.md` from its checkout. The one documented
limit is on that first message: a routine run's text is capped at 65,536 characters (Anthropic's
routine fire API reference, `POST /v1/claude_code/routines/{id}/fire`, field `text`); RemoteTrigger
create documents none lower. `brief-size.bats` measures what `payload` renders, not the raw files:

- the inline brief (`payload` without `--brief-ref`) under 32768 bytes, half that limit;
- the `--brief-ref` prompt, fixtures named, one line under 512 bytes;
- each installed brief under 4096 bytes with 400 to spare. That cap is a readability budget, not a
  transport limit: every session reads the brief whole, so it carries only the rules every session
  needs. A short new rule fits without rewording other steps; detail a rare case needs belongs in a
  reference the brief links to.
