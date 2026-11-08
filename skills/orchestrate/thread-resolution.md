# Who resolves review threads

**The local orchestrator resolves review threads. Cloud sessions reply; they do not resolve.**

A cloud (CCR) session cannot resolve a review thread: GraphQL is unavailable there, and the REST
resolve route (`POST /pulls/{n}/ccr/comments/{id}/resolve`) is denied by the auto-mode classifier as
an external write. Comment POSTs are allowed. A cloud repair session sent to "resolve the threads"
on a PR blocked only by unresolved threads makes no progress, and the PR sits blocked (seen
2026-11-04: two runs, about 3 hours, while every thread already had a reply linking a follow-up
issue).

## In every cloud brief that touches review feedback

Paste this, as written:

> Reply on each review thread you address (a thread reply is a comment POST, which is allowed),
> and do not try to resolve threads: no GraphQL, no resolve route. End each reply with what
> settled it: `follow-up #<issue>` when you filed or found an issue for it, or
> `fixed in <commit sha>` after you pushed the fix to this PR's branch. The orchestrator
> resolves answered threads after your run.

Do not send a cloud session to a PR whose only blocker is threads that are already answered; that
is the orchestrator's job (below), not a repair.

## After each repair (and at every triage tick)

The orchestrator settles answered threads from the local checkout:

```bash
"$SCRIPTS/thread-sweep.sh" scan --repo <o/r>              # every open PR; or --pr N
"$SCRIPTS/thread-sweep.sh" resolve --repo <o/r> --pr <n>  # resolve the answered ones on PR n
```

A thread counts as answered when its last comment is a reply from someone other than the thread's
starter and it either links an issue (`#N` or an issues URL, not the PR's own number) or names a
commit that is on the PR (a 7-40 character sha or a commit URL). Everything else stays `open`: no
reply yet, the reviewer spoke last (the answer was disputed), or a reply that names neither.
`resolve` runs `thread-resolve.sh` per answered thread, which calls GraphQL
`resolveReviewThread`, reads the thread back, and logs it to `<state dir>/thread-actions.log`; it
posts no new reply. Exit 5 or 9: rerun the same command; it reconciles.

Where GitHub refuses GraphQL (an orchestrator that itself runs in a cloud session), both commands
work over REST on their own (#136): `scan` reads `ccr/review_threads` with the PR's review comments
and commits (`gh-rest-pr.sh thread-nodes`) and prints the same answers, with the thread's first
comment id in place of the `PRRT_` id; `resolve` then calls
`POST /pulls/{n}/ccr/comments/{id}/resolve`, reads the thread back and journals it the same way. A
cloud *repair* session still does not resolve: the auto-mode classifier denies that route there.

An `open` thread is a real repair target: a fix pass (local) or a cloud repair brief with the
paragraph above. Threads that arrive after the first review round go through
`review-followup.sh` instead (`roles/pr-doctor.md`).

## The tick snapshot

`triage-tick.sh snapshot` prints a `threads` line (`thread-sweep.sh scan --summary`):

```
threads unresolved=<n> answered=<n> resolve-now=#a,#b|- repair=#c|-
```

`resolve-now` lists PRs whose unresolved threads are all answered, and raises the reason
`resolve-now=<count>`: resolve them now (`thread-sweep.sh resolve`), do not dispatch a repair. Only
the `repair` PRs need a lane. A PR with more than 100 review threads is always listed as `repair`,
never guessed answered.
