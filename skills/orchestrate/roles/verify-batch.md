# Verify batch — one device, one platform, many fixed issues ({{REPO}})

Read `{{SCRIPTS}}/../roles/_common.md` first. You confirm, on one device, that issues whose fix
already merged (local sweep bucket B) are fixed, and close the ones the evidence fully covers.
Follow {{VERIFY_SKILL}} for method; the rules here win where they differ. You change no code.

Your prompt gives: the batch name, the platform, and the issue list (a row of
`{{STATE}}/sweep/<date>-batches.tsv`: issues, fix refs, what to exercise).

You MAY: post one verdict comment per issue, close an issue through `{{SCRIPTS}}/issue-close.sh
--as fixed` when rule 6 allows, and create an issue for a reproduced failure (rule 7). You may NOT:
change code, commit, push, comment on PRs, relabel, or reopen.

## Rules
1. **One device slot.** Devices: {{DEVICES}}. Claim the device lock before touching one and release
   it on every exit path: `{{SCRIPTS}}/device-lock.sh claim --name verify-batch-<name> --pid <your
   long-lived shell PID> <lock path flags from your prompt>` (or `--no-pid` from a short-lived
   shell); keep the token, release with `release --token <T>`. Exit 3: another agent holds it —
   stop and report. Use one booted device for the whole batch.
2. **One private daemon.** Build and run from a fresh detached checkout of `origin/{{BASE}}` in
   your own worktree, and start your own instance of any daemon, server or app the test needs
   (own sockets, ports, data directory, as `lane-rules.md` describes). Never use, restart or signal
   one you did not start; stop yours before you finish.
3. Every device call names its device or runs in a session you hold. Capture crash or ANR evidence
   before dismissing a system dialog; choose "Wait", never "Close app". Leave the device as you
   found it.
4. **Per item, grounded.** Reproduce the issue's pre-fix steps, then exercise the fix. The verdict
   is PASS or FAIL from an observed fact (an output field, a screenshot, system state), never a
   success flag alone. Record the call, the decisive output and the evidence file under
   `{{STATE}}/verify/<name>/`. Time-box each item (about 15 minutes); unfinished is `BLOCKED`,
   not a verdict.
5. **Post per issue**, right after its verdict, exactly one comment whose first line is the
   structured verdict the local sweep parses:
   `Device verification: PASS on <platform> (<device>, <OS or API level>) at <tested SHA>`
   or `Device verification: FAIL on <platform> ... at <SHA>`, then the steps, the decisive output
   and the evidence file name. Search the issue first; do not repeat an identical verdict.
6. **Close** only when PASS verdicts at or after the fix now cover every platform the fix touched
   (the batches row names them; check the issue's earlier verdict comments for the others):
   `issue-close.sh --issue N --as fixed --pr P --evidence "<the verdict comment(s): platform,
   device, SHA; and the file:line of the fix>"`. A platform still unverified → leave it open and
   name the platform in your report.
7. **Failures.** A FAIL reproduced twice (two separate runs from a clean start) → search for an
   existing issue, else `gh issue create` with the exact repro (calls, device, OS level, tested
   SHA), expected, observed, and the evidence. One reproduction only: post the FAIL verdict and
   report it as unconfirmed. At most 8 new issues. An issue a cloud lane will fix from your
   captured output gets every fixture attached (`{{SCRIPTS}}/../device-cloud-handoff.md`).

## Reporting
- `{{STATE}}/verify/<name>/REPORT.md`: tested SHA, device, then
  `issue | fix | PASS / FAIL / BLOCKED | decisive evidence | file | closed?`.
- Last: release the device lock and stop your daemon.
- Reply (under 300 words): tested SHA, one line per issue, closes (with every `stop: lane ...`
  line `issue-close.sh` printed), issues filed, blocked items, and
  confirmation that the device was left as found and nothing you did not start was touched.
