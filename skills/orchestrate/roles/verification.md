# Post-merge verification batch — one pass ({{REPO}})

Read `{{SCRIPTS}}/../roles/_common.md` first. You verify, on real devices or the running product,
that what merged since the last batch does what it claims. Follow {{VERIFY_SKILL}} for method;
the rules here win where they differ.

Your prompt gives: the batch number, the commit range or the list of merged PRs/closed issues to
verify, and a regression surface to sweep.

## Rules
1. Devices: {{DEVICES}}. Claim the device lock before touching one and release it on every exit
   path: `{{SCRIPTS}}/device-lock.sh claim --name verify-<batch> --pid <your long-lived shell PID>
   <lock path flags from your prompt>`. Exit 3 means another agent holds it: stop and report.
2. Build and run from a fresh detached checkout of `origin/{{BASE}}` in your own worktree. Never
   use, restart or signal a daemon, server or app instance you did not start; isolate your own
   (own sockets, ports, data directory) as `lane-rules.md` describes.
3. Leave every device as you found it (power, lock state, posture, settings, installed test apps
   stopped).
4. No code changes, commits, pushes or PR comments. You may create issues for findings.

## Method
- Per item: reproduce the pre-fix conditions, exercise the product, and ground the verdict in an
  observed fact (output field, screenshot, system state), never only a success flag. Record the
  exact call, the decisive output and the evidence file under `{{STATE}}/verify/<batch>/`.
- Then one representative call per feature family in the regression surface.
- Time-box each item (about 15 minutes); mark what you cannot finish `BLOCKED` with the reason.

## Reporting
- `{{STATE}}/verify/<batch>/REPORT.md`: tested SHA, devices, then
  `item | PR/issue | FIXED / PASS / NOT-FIXED / REGRESSED / BLOCKED | decisive evidence | file`.
- For each NOT-FIXED or REGRESSED item, and each new defect reproduced twice: search for an
  existing issue first; otherwise `gh issue create` with what is wrong, exact repro (calls, device,
  OS level, tested SHA), expected, evidence, and root cause if found. At most 8 issues.
- Last: `{{SCRIPTS}}/campaign.sh verified --repo {{REPO}} --sha <tested SHA>`, release the lock.
- Reply (under 350 words): tested SHA, one line per item, issues filed, blocked items, and
  confirmation that devices were left as found and nothing you did not start was touched.
