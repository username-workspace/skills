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
| implementing | ship-when-done | the work is committed and the branch is ahead of its base |
| gating | ship-when-done | the project gate passed at this work state |
| proving | proof-of-fix | every repro the need's sessions recorded passes at this work state |
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
  --criterion '<acceptance criterion and the probe that shows it>' --prompt '<the prompt, verbatim>'
```

`open` creates `need/<id>` from the current HEAD and refuses a working tree with changes the need did not
produce (`--adopt-changes` carries them in on purpose), a repo outside the AUTO scope, a repo without a
remote, and a repo where a stage owner is missing. For a bug, record the failing repro with proof-of-fix
before the fix: the proving stage then requires it green.

## While a need is in flight

Every human prompt is classified before the need advances, with one command:

| The prompt is | Run |
|---|---|
| a request to stop | `halt`: the need is blocked, uncommitted work is committed locally, the branch stays held |
| a request to continue a blocked need | `resume` |
| a request to drop the need | `abandon`: blocked for good, the branch stays held until `release` |
| a change to what the need must deliver | `amend --criterion '<criterion>'` |
| a question or a status check | `note`, then answer it |

`release` takes a need out of the ledger and hands its branch back to the siblings; `adopt` moves a need
to the current session on purpose. A new, unrelated need waits until the current one is ready, released
or abandoned.

## Breakers

A need is blocked, and the user told once, when the same blocking decision comes back three times with
no change in work state, when a stage uses its attempt budget (three review passes, six otherwise), or
when the need runs past eight hours. The branch stays held; `resume` clears the counters.

## Reviews under drive

When the conductor asks for a review, run the fresh-eyes reviewer in the foreground: a driven need waits
on the recorded verdict, and a background agent would read as a Stop with no progress.

## State

`.git/conductor.json` (the ledger, one entry per driven need, plus a short history of needs that reached
`ready`) and `.git/conductor.json.lock`. Compaction and `/clear` keep the need bound to the same Claude
process (`CLAUDE_PID`); a fresh session on a driven branch is told who drives it.
