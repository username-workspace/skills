---
name: delivery-conductor
description: >-
  Drives a stated need from the prompt to a ready PR/MR with no intervention. Open a need when a prompt
  asks for a change to deliver; then implement it and end your turn. At every Stop the conductor asks
  each sibling's read-only stage CLI where the need stands (ship-when-done, proof-of-fix, merge-review,
  mr-watchdog), runs the short steps itself, and names the next judgment step for you (implement,
  review, fix). While it drives a branch, every sibling stands down. Use it through its hooks; the CLI
  is for opening a need and for classifying the user's prompts while one is in flight.
---

# delivery-conductor

The conductor owns no stage. It sequences the ones its siblings own, in this order, and acts on the first
that is not done:

| Stage | Owner | Done when |
|---|---|---|
| contracting | proof-of-fix | every criterion of the need has a probe recorded failing, or a waiver |
| implementing | ship-when-done | the work is committed and the branch is ahead of its base |
| gating | ship-when-done | the project gate passed at this work state |
| proving | proof-of-fix | every probe of the need (its criteria's, and any repro its sessions recorded) passes at this work state |
| reviewing | merge-review | a review recorded for the exact HEAD scores at or above the threshold |
| shipping | ship-when-done | declared, pushed at HEAD, PR/MR open |
| ci | mr-watchdog | the watcher's verdict for the exact HEAD is green |
| ready | ship-when-done | the draft is marked ready for review |

Each answer names its next step. A **script** step (commit, mark-done, push, open the PR/MR, mark it
ready) runs inside the Stop hook. A **background** step (the gate, a probe re-run, the CI watcher) comes
back to you as a command to launch with `run_in_background=true`; it carries `--need <id>`, and while it
runs the conductor waits instead of asking again. A **skill** step is a judgment step for you: implement,
review, fix. Do that step only, then end your turn: committing, pushing and re-entering are the
conductor's.

## Opening a need

The UserPromptSubmit hook tells you when a prompt could open a need. Before any edit:

```bash
python3 "${SKILL}" open --repo . --summary '<imperative summary>' --type feat \
  --criterion '<what must be true once delivered>' [--criterion '<another>']
```

A need has at least one criterion; each gets an id (`c1`, `c2`, …). Before any edit, record each
criterion's probe with proof-of-fix, failing now (`open`'s reply names the commands in `contract`); a
criterion that is not behavioural is waived with its reason. The contracting stage holds the work until
every criterion has one, and the proving stage requires every probe green at the shipped head.

The prompt itself is the one the UserPromptSubmit hook captured for this turn, verbatim. `open` creates
`need/<id>` from the base (the default branch of the remote the need ships to, as last fetched), so no
earlier work counts as the need's, and refuses a working tree
with changes the need did not produce (`--adopt-changes` carries them in on purpose), a worktree another
need still holds (one need per worktree: open the next one in another worktree), a repo outside the AUTO
scope, a repo without a remote, and a repo where a stage owner is missing. For a bug, the failing repro is
one of the need's criteria, recorded the same way.

## While a need is in flight

Every human prompt is classified before the need advances, with one command:

| The prompt is | Run |
|---|---|
| a request to stop | `halt`: the need is blocked, uncommitted work is committed locally, the branch stays held |
| a request to continue a blocked need | `resume` |
| a request to drop the need | `abandon`: blocked for good, the branch stays held until `release` |
| a change to what the need must deliver | `amend --criterion '<criterion>'`: the need goes back to contracting for its probe |
| a question or a status check | `note`, then answer it |

`release` hands a need's branch back to the siblings, and a need that reaches `ready` does the same: both
take effect at the next prompt, so no sibling speaks in the deciding turn. `adopt --need <id>` moves a
need to the current session on purpose. A new, unrelated need waits until the current one is ready or
released.

A follow-up on a need that reached `ready` (review comments, a change to its PR/MR) reopens it on its
branch instead of opening a new one: the prompt hook offers `reopen --need <id>` while the worktree is on
that branch. Then implement the follow-up and end your turn; the conductor drives it to ready again.

## The report

At `ready` the conductor hands you the report to relay: the need and its branch, the driven time
(blocked time excluded), each criterion's probe with its red run and its green run (or the waiver), the
tokens each model spent on the need's sessions and their subagents, and each stage's evidence.

## Breakers

A need is blocked, and the user told once, when the same blocking decision comes back three times with
no change in work state, when a stage fails too many times in a row (three failing reviews, six red
gates, CI runs or refused steps; the stage being done resets it), or when the need runs past eight hours
of driven time. The branch stays held; `resume` clears the counters and restarts the clock.

## Reviews under drive

When the conductor asks for a review, give the fresh-eyes reviewer subagent a description containing
`need:<id>`. Subagents run in the background; while that task runs the conductor waits instead of asking
again, exactly as for a shell step carrying `--need <id>`.

## State

`.git/conductor.json` (the ledger, one entry per driven need, plus a short history of the needs that left
it, kept whole so a `ready` one can be reopened) and `.git/conductor.json.lock`. Compaction and `/clear` keep the need bound to the same Claude
process (`CLAUDE_PID`); a fresh session on a driven branch is told who drives it.
