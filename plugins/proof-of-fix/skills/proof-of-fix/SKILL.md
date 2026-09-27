---
name: proof-of-fix
description: >-
  Evidence-first bug fixing: prove the bug BEFORE touching code (a recorded probe that must FAIL),
  fix the root cause, then prove the fix with the SAME probe (`check` passes only when it runs
  green). Auto-engaging: a bug-shaped prompt ("fix", "bug", "regression", "ça casse", "échoue", …)
  injects the protocol into context, and a Stop hook re-runs an open repro itself — auto-closing it
  on green, handing back the failing output on red (bounded, never a loop). Use when fixing any bug,
  when asked to validate a fix empirically, or via /proof-of-fix. Horizontal: any repo, any stack —
  the probe is whatever command demonstrates the bug. Opt out per repo.
---

# proof-of-fix

A fix you cannot demonstrate is a guess. This skill turns "trust me, it's fixed" into two runs of the
same probe: **red before** the change, **green after** — the discipline that separates a root-cause
fix from a plausible-looking edit.

## The protocol

1. **Reproduce before touching code.** Write the smallest probe that demonstrates the bug — a failing
   test, a one-line command, a curl, a script. Record it:
   ```bash
   python3 scripts/repro.py record --cmd '<probe>'      # accepted ONLY if it fails
   ```
   `record` runs the probe and **refuses it if it exits 0** — a repro that passes proves nothing.
   If you cannot reproduce, say so and stop instead of fixing blind.
2. **Fix the root cause.** Never weaken the probe to make it pass — the probe is the contract.
3. **Prove the fix with the same probe.**
   ```bash
   python3 scripts/repro.py check                       # green → proven; red → failing output
   ```
   Share both runs (the recorded failure, the passing check) as the evidence for "fixed".

The best probe is a real test committed with the fix — `record --cmd 'pytest tests/test_x.py -k repro'`
— so the repro becomes a permanent regression guard. A throwaway command is fine when a test doesn't
fit; the discipline is the same.

## How it engages on its own

- **UserPromptSubmit** — when the prompt looks like a bug report or fix request (en/fr), the protocol
  is injected as context, **once per session per repo**. No repo in scope → silent. Harness envelopes
  that also arrive as prompts (task notifications, agent hand-backs, cross-session messages) never
  nudge: their wording is model output, not the user asking for a fix.
- **Stop** — when this session's recorded repro is still open and the work-state changed since the last attempt,
  the hook **re-runs the probe itself**: green → the repro is auto-proven and a one-line
  `systemMessage` says so; red → a `block` hands the failing output back to the session to keep
  fixing. One attempt per work-state, capped at 5 per repro — an unconverging fix ends the turn, it
  never loops the Stop hook.

State lives in `.git/proof-of-fix.json` (never committed), **owned by the session that recorded it**:
one active repro per session — the latest it recorded wins. `record` / `check` / `status` / `clear`
act on the calling session (`CLAUDE_CODE_SESSION_ID`, or `--session`), and a Stop hook only re-runs
the stopping session's repro, so concurrent sessions in one checkout never block on each other's
probe. Opt a repo out with `{ "enabled": false }` in `.proof-of-fix.json`.

## Manual / debug

```bash
python3 scripts/repro.py record --cmd 'pytest -x tests/test_bug.py'   # must fail to be accepted
python3 scripts/repro.py check                                        # must pass to prove the fix
python3 scripts/repro.py status                                       # this session's repro state JSON
python3 scripts/repro.py clear                                        # drop this session's obsolete repro
```

`record --need N` binds a repro to a delivery-conductor need (it then escapes the 7-day session GC) and
prints a neutral line. Every `check` records the work state it ran on and whether the tree held still
while the probe ran; only such a check counts as proof for a need.

## Stage protocol (delivery-conductor)

`scripts/repro.py stage --repo R --need N --sessions S1,S2` answers, read-only, where a need stands in its `proving` stage (the repros the need's sessions recorded):
a v1 report with the stage's `state` (`done`, `pending`, `blocked`), its `evidence` (bound to the exact
work state or sha it was produced on) and the `next` step (`script`, `background` or `skill`). A repo that
opted this plugin out gets `{"enabled": false}` from it. See `docs/architecture.md` in the marketplace.

Every command acts on the calling session (`CLAUDE_CODE_SESSION_ID`, set in Claude Code's shell). From a
plain terminal pass `--session <id>`; `status` and `clear` name the sessions holding an open repro.

## Composes with the delivery harness

`record` → fix → `check` is the inner loop; ship-when-done / merge-review / mr-watchdog are the outer
loop (commit → review → push → PR → CI). A probe recorded as a real test makes the outer loop's gate
and CI inherit the regression guard for free.

## Dependencies

Only **`git`** and **Python 3** (stdlib) — the probe itself can be anything your shell runs.

## Caveats

- The probe runs with your shell privileges at `record`/`check`/Stop time — it is given by the live
  session, never read from a cloneable file. Keep probes fast (120s cap, timeout = still failing).
- One active repro per session, by design (YAGNI) — fixing several bugs at once is the anti-pattern this
  skill exists to prevent.
- `check` proves the recorded probe passes — it cannot prove the probe was the *right* probe. A probe
  that never captured the bug stays your responsibility (that's why the failing `record` run is part
  of the evidence).
