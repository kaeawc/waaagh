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
