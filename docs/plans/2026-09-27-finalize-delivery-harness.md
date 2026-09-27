# Finalizing the delivery harness: remaining work

State on 2026-09-27, main at `e00ebe2`. This plan lists what is left to finish Phase 1 of
[the autonomous-delivery plan](2026-09-26-autonomous-delivery.md), the correctness gaps found on the way,
the decisions still pending, and the later phases. Each item names its acceptance evidence.

## Where things stand

| PR | Merged | What it settled |
|---|---|---|
| #75 | yes | Driven one-voice; open questions 1 (conductor liveness per prompt) and 2 (out-of-scope sessions stand down) closed |
| #76 | yes | E2E lane on GitHub and GitLab, ledger 62/62 per forge (proven at `3f514cc`, stale since #75) |
| #78 | yes | A linked worktree reads the repo's trusted config |
| #79 | yes | Stage protocol and owner CLIs (Phase 1, second deliverable) |
| #80 | yes | A session spawned by claude-remote-spawn starts from a clean Claude environment, so its transcript is saved |
| #81 | closed | Reusing an approval after a rebase: abandoned after four passes, lessons in the PR |
| #82 | yes | Proportionate review passes, breaker after two confirmations |
| #83 | yes | mr-watchdog: a forge error is not a closed MR (#77) |

## 1. Phase 1: the conductor skeleton (P0)

The Phase 1 deliverable is still open: **a need goes from prompt to `ready` (a green, reviewed PR/MR)
with zero intervention, surviving a compaction and a halt.** What #75 and #79 do not cover yet:

- **delivery-conductor plugin** (new): `conductor.py open` (verbatim prompt, criteria with probes,
  assumptions), `adopt`, the need ledger with its lock, the per-need worktree and branch (the first
  need starts from the base; a prompt may name pre-existing changes to adopt).
- **Hooks**: UserPromptSubmit (contract step; halt, resume, abandon, amendment, new need, neither),
  Stop (advance by one stage step through the `stage` CLIs), SessionStart (`compact`, `clear`,
  `resume` re-bind by `CLAUDE_PID`; `fork` and `startup` get the one-line notice).
- **Breakers and budgets**: the no-progress breaker (three blocking Stops with no change in work
  state or evidence), wall clock per need, attempts per stage, CI runs per need; escalation through
  the report instruction.
- **Waiting**: the need's background step matched by its `--need` token in `background_tasks`; the
  one-shot `CronCreate` wake-up (cron availability checked at `open`, confirmed through
  `session_crons` at the first wait).
- **Open question 3**, not closed yet: merge-review's fresh-eyes subagent has no `command` in
  `background_tasks`, so the waiting rule does not see it and three Stops trip the breaker at every
  review. Decide between matching the need token in the subagent's description and running the driven
  review in the foreground, with a turn-simulator case. #82 makes confirmations subagents too, so the
  same answer must cover them.
- **Report** at `ready`: need, PR/MR, head sha, per-criterion evidence, time, cost.
- `scripts/kernel-sync.py` vendors the kernel into the new plugin.

Acceptance: the harness suite and the turn simulator cover every transition listed in the plan's
Testing section; the E2E lane gains a `needs` space (need to ready, need to blocked to resumed) on both
forges.

## 2. E2E ledger refresh (P0, closes Phase 1)

The ledger is stale on both forges since #75. Run `bash tests/e2e/run.sh --fill` and
`bash tests/e2e/run.sh --forge gitlab --fill` once Phase 1 stops moving the harness, together with the
new `needs` space, and commit the refreshed `tests/e2e/coverage.json`.

Cost: one full campaign is about 110 GitHub runs (the GitHub sandbox is public, so its minutes are
free) and about 30 GitLab compute minutes (400 per month on the free tier). Run it deliberately, not
per PR.

## 3. Review correctness gaps on main (P1, under-review)

Found while working on #81; they predate it. Each gets a failing test before its fix, in the
merge-review suite.

1. **Stale local base.** `context` diffs against the local default branch. With a stale local main
   that still holds a commit origin dropped, even the full diff hides that commit. Direction: review
   against the fetched merge target (`<remote>/<default>` when it exists).
2. **Ancestor delta without a base check.** The delta path trusts a passing record without checking
   the base it was given against: merging a rewritten base into the branch hides a dropped commit.
   Direction: record the base the reviewed diff was taken against and shrink only while it is still in
   the current base's history.
3. **Non-UTF-8 diffs.** `context --packet` decodes the diff as UTF-8 and crashes on a Latin-1 file.
   Direction: read bytes, decode with replacement for the packet only.

Not planned: reusing an approval across a rebase. Until the rebase re-review cost shows up again, a
clean rebase is handled by hand (`git range-diff` all `=` plus the gate). If it is picked up again,
start from the object identity noted in #81 and its three failure modes.

## 4. Decisions pending (P1)

- **Embedded bare repository.** A cloned repo can carry a directory shaped like a bare repo; a session
  working inside it makes git treat it as the git dir, and a crafted `ship-when-done.json` there would
  be read as trusted config (its `gate` is a shell command). Proposed fix: refuse a trusted config dir
  that sits inside a working tree, with a failing test first.
- **claude-remote-spawn `stop`.** It kills the recorded process group without checking that the group
  is still that session's, and the suite uses generic session names that could match a real session.
  Proposed fix: verify the group's command line before signalling, and namespace the test sessions.

## 5. Smaller fixes (P2)

- mr-watchdog on GitLab: `mr_open` lists MRs by source branch name, so a stranger's fork MR with the
  same branch name counts as open. Reuse `gitlab_open_mr` (the suite's glab stubs need the
  `merge_requests?` shape).
- merge-review policy: "documentation" is undefined, and in this marketplace a SKILL.md is product.
  Define the inline-reviewable set (README, `docs/`, CHANGELOG), SKILL.md excluded.
- claude-remote-spawn: the `open` launcher's manual fallback does not scrub the parent markers, and
  `TRACEPARENT` is not in the list (matters only with OpenTelemetry on).
- ship-when-done: a presence file whose `script` is not a string raises in `handoff`; normalise in
  `read_marker` for every reader.
- mr-watchdog: `tick` could report `"mr": "error"`; a deadline reached during an MR lookup error reads
  "timeout while CI was error".
- Known limit, to document in `docs/architecture.md`: a session whose cwd stays in the main checkout
  while it edits a nested worktree by absolute path resolves to the main checkout. Working from inside
  the worktree is the supported shape.

## 6. Later phases (from the plan)

| Phase | Deliverable |
|---|---|
| 2 | Acceptance probes: proof-of-fix schema v2, env-aware and read-only probes; proving checks the contract's criteria |
| 3 | ship-to-prod: up-to-date, sha-bound merge, deployment watch, production verification, revert through a PR/MR |
| 4 | Supervisor: a need survives the death of its session |

## Order

1. Section 1, then section 2: together they close Phase 1.
2. Sections 3 and 4 in parallel with section 1, merged before the Phase 1 PR opens or after it lands,
   never while it is open (a merge on main forces a rebase and a new review of the open PR).
3. Section 5 opportunistically, section 6 after Phase 1.

## Working rules learned in Phase 1

- Work in a worktree; the main checkout stays on main (its code is live for every session).
- One PR open on the harness core at a time; a parallel merge to main forced #79 into two rebases and
  a review loop that exhausted the usage window.
- Reviews follow merge-review's proportionate passes (#82): a fresh-eyes first pass, at most two
  scoped confirmations, then stop and hand the open findings to a human.
- After a clean rebase, check `git range-diff` (all `=`) and the gate instead of a new review.
- Record a failing review pass before committing its fix.
- Spawn long sessions with claude-remote-spawn from main at `3c1c84a` or later (clean environment).
- Never clean up with `pkill -f`; kill by known PID only.
