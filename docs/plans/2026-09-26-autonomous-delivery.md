# Autonomous Delivery: design and plan

> **Status: Accepted** (2026-09-26). Decisions D1 to D5 signed off by Benjamin; D6 and D7 are defaults
> taken in revision 3, open to veto. Revision 3 after two fresh-eyes merge-review passes (see "Review
> log" at the end).

**Goal:** a need stated once is driven to an end state with no human intervention: **`ready`** (a
reviewed PR/MR, green at its exact head sha, handed to a human) by default, or **`delivered`**
(merged, deployed, verified in production) in repos that enable ship-to-prod. The plugins never
overlap, invoke each other, and engage on their own. The user states the need; the harness reports
back.

**Scope:** repositories inside the AUTO scope (`HARNESS_AUTO_ENGAGE=1`, minus
`HARNESS_AUTO_ENGAGE_EXCLUDE`, minus sessions launched outside a work tree; PR #70). Trees that carry
their own delivery harness (warden, the ZV workspace) keep it; there the new plugins stay inert.

---

## The three constraints, as invariants

1. **No overlap.** Every concern has one owning plugin, and a state file is written only by its owner's
   code (another plugin calls the owner's CLI, §2). **While a branch is driven, the session receives
   instructions from one source per turn, on every channel** (§1): hooks, background-task output and
   the bodies of the skills it invokes. The invariant covers the harness plugins; foreign Stop hooks
   (e.g. ralph-loop) are out of scope but share Claude Code's block cap.
2. **Plugins invoke each other.** Through a read-only `stage` CLI per plugin, owner CLIs for writes, and
   one instruction naming the next skill when a step needs the model. Never through the user.
3. **Self-engaging.** Hooks start and advance the work. The user never types a skill name.

## Facts the design rests on

| # | Fact | How we know |
|---|---|---|
| F1 | Stop hooks of all plugins run **in parallel**; **every** `block` reason reaches the model, as separate "Stop hook feedback" messages in one continuation | measured 2026-09-26: two hooks fired 5 ms apart, the model quoted both reasons |
| F2 | UserPromptSubmit also fires for harness envelopes (`<task-notification>`, `<agent-message>`, `<cross-session-message>`); the payload has no origin field | transcripts + CC 2.1.283 hook input; proof-of-fix filters envelopes by content (PR #66, merged) |
| F3 | `CLAUDE_PROJECT_DIR` is the session's launch dir, stable across `cd` | headless probe (PR #70) |
| F4 | A hook **cannot invoke a skill or a tool**; it injects text or blocks with a reason | hooks guide: command hooks "can't trigger `/` commands or tool calls" |
| F5 | The session is allowed to stop after **8 Stop blocks in one turn** (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, default 8) | CC 2.1.283 binary: `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP??8`, `hit_cap` |
| F6 | `SessionStart` fires with `source` = `startup`, `resume`, `clear`, `compact`, `fork`, and can inject context | hooks guide + binary |
| F7 | No plugin-to-plugin dependency declaration exists | plugins docs |
| F8 | Two re-entry paths reopen a session after a wait: a background task **the model launched** (proven: mr-watchdog), and a hook declared **`asyncRewake`**, which runs in the background and wakes the model when it exits with code 2 (CC 2.1.283 hook schema; to evaluate in Phase 1). A process a hook spawns without `asyncRewake` is untracked | `watch.py` design; CC 2.1.283 hook schema |

---

## Architecture

### 1. One voice while driven, on every channel

A need in flight makes `delivery-conductor` the **driver of its branch**. The kernel gains
`driven(repo, branch, session)`:

- true for the session bound to the need (the driver);
- **also true for any other session on that branch**: it stands down entirely, so a second session
  can neither act on nor amend a need it does not drive;
- false once the need leaves the driven states (§4). **Every transition out of driven (to `blocked`,
  `ready`, `delivered`, `abandoned`) takes effect at the next UserPromptSubmit**, so `driven()` is
  stable during the Stop that decides it and no sibling can speak in that turn.

An absent or corrupt ledger reads as not driven.

| Channel | Outside the conductor's scope (unchanged) | Driven |
|---|---|---|
| Stop | each plugin's hook may speak | only the conductor speaks, at most one decision; the others call `driven()` and stand down |
| UserPromptSubmit | proof-of-fix nudges bug-shaped prompts | inside the conductor's scope the conductor's contract nudge **replaces** proof-of-fix's nudge, from the first prompt on (a bug need gets a repro criterion); proof-of-fix checks `conductor_scope(repo)` and stands down |
| PreToolUse (merge-review pre-push deny) | denies an unreviewed push, reason instructs a review | pushes are sequenced by the conductor after a passing review, so the deny cannot fire (tested); if it ever does, its reason points back to the conductor. Pushes run inside the conductor's Stop never reach PreToolUse: their safety net is ship-when-done's `review_gate_pending` check in the ladder |
| Background-task output (watcher) | prints the verdict **and** the fix instruction | prints a neutral verdict line and writes the verdict file; the conductor's next Stop turns it into the single instruction (the watcher receives `--session` so it can evaluate `driven()`) |
| Skill bodies | a skill prescribes its own sequence (merge-review: fix, commit, re-review; mr-watchdog: fix, verify, push) | a skill invoked under drive performs **its judgment step only** (review, fix); commit, push and re-entry are the conductor's. Each harness SKILL.md gains a "When driven" section saying so |

**Invariant under test (driven states only):** for every reachable driven state, the union of the hook
channels and the invoked skill's driven-mode instructions carries at most one instruction per turn.

### 2. The stage protocol and owner CLIs

Each harness plugin exposes one read-only entry point, versioned (`"v": 1`):

```
<plugin>.py stage --repo R --need N --json
{
  "v": 1,
  "stage": "ci",
  "state": "pending | ready | blocked | done",
  "evidence": { "sha": "…", "file": ".git/…", "verdict": "…" },
  "next": {
    "kind": "none | script | skill",
    "run": ["ship.py", "mark-done", "--repo", "R", "--summary", "…"],     # kind=script
    "skill": "mr-watchdog",                                                # kind=skill
    "instruction": "launch `watch.py run --repo R --session S` with run_in_background"
  }
}
```

- **`script`** steps are short and deterministic, run by the conductor inside its Stop hook: commit,
  push, open the PR/MR, `mark-done`, merge. The conductor keeps an internal deadline below its hook
  timeout; anything that could exceed it (the gate, a probe run) is not a script step.
- **Background steps** (the gate, probe runs, CI and deployment waits) are launched by the model on the
  conductor's instruction, or as `asyncRewake` hooks if Phase 1 proves that path (F8). Each writes its
  owner's evidence file: `ship.py gate` (new) runs the detected gate and writes `swd-gate.json`;
  `repro.py check --need` writes per-criterion evidence; the watchers write their verdict files.
- **`skill`** steps need judgment: implement, review, fix a red CI or a failing probe.
- **Owner CLIs for every cross-plugin write.** ship-when-done's handoff stamps become owner subcommands
  (`review.py handoff`, `watch.py handoff`) that ship.py calls, so constraint 1 holds literally; the
  conductor calls `ship.py mark-done`.
- **Discovery.** Every harness plugin stamps its script path (merge-review and mr-watchdog already do;
  ship-when-done and proof-of-fix start). **A missing owner of a safety stage (gating, proving,
  reviewing, ci, and merging/deploying/verifying when enabled) fails the contract at `open`**: the need
  never starts without its full evidence chain. Nothing is skipped silently.

### 3. What starts, advances and resumes a need

F5 bounds a turn to 8 Stop blocks. The conductor counts every block it emits and uses at most 5 per
turn. **Reaching that budget is a continuation, not a failure**: the last instruction of the turn
launches a re-entry (F8) and the need stays driven, with no escalation. Waits always go to the
background.

| Event | Owner | Effect |
|---|---|---|
| UserPromptSubmit, human prompt, conductor scope | conductor | captures the prompt **verbatim** (the hook has it) and injects the contract step; the model decides whether it is a need and calls `conductor.py open` |
| UserPromptSubmit while a need is in flight | conductor | the model classifies the prompt: **halt** (the need is blocked at once and the conductor falls silent), **amendment** (contract amended, stale stages re-entered) or **new need** (queued) |
| Stop | conductor | advances by one step |
| SessionStart `resume`, `compact` | conductor | same logical session: re-binds the need to the new session id and re-injects the contract and stage |
| SessionStart `fork` | conductor | the fork does **not** inherit the drive; it can adopt the need explicitly (`conductor.py adopt`), which moves the binding |
| A background task or `asyncRewake` hook resolves | its owner | a new turn; the next Stop reads the evidence file |
| The session dies | supervisor (Phase 4) | resumes a session in the need's worktree (`.git` state is per worktree); SessionStart re-binds it |

### 4. The life of a need

```
contracting → implementing → gating → proving → reviewing → shipping → ci ─┬→ ready                        (merging not enabled: end state)
      ▲             ▲           ▲         ▲          ▲           │        │  └→ merging → deploying → verifying → delivered
      └─────────────┴───────────┴─────────┴──────────┴───────────┴────────┘  a new HEAD re-enters the earliest stage whose evidence it made stale
blocked ⇄ (resume | abandon)      any stage → blocked on a breaker or a halt
```

| Transition | Evidence (bound to) | Owner |
|---|---|---|
| contracting → implementing | a valid contract: need verbatim, repo, branch, criteria, assumptions, budget, all safety-stage owners present | conductor |
| implementing → gating | work committed as a milestone (ship-when-done commits before review, as today) | ship-when-done |
| gating → proving | project gate green (work state), written by `ship.py gate` | ship-when-done `swd-gate.json` |
| proving → reviewing | every acceptance probe green, each red first when it asserts new behaviour (HEAD) | proof-of-fix |
| reviewing → shipping | a review record for the exact HEAD with **score ≥ threshold** (not only the `--passed` flag) | merge-review |
| shipping → ci | branch pushed, PR/MR open | ship-when-done |
| ci → ready | CI green (exact head sha), merging not enabled | mr-watchdog |
| ci → merging | CI green (exact head sha), ship-to-prod enabled | mr-watchdog |
| merging → deploying | the PR is **up to date with its base** and merged at the reviewed head sha (`gh pr merge --match-head-commit`, `glab mr merge --sha`, `--auto-merge=false`) | ship-to-prod |
| deploying → verifying | default-branch pipeline green (merge sha); skipped when `deploy: none` | ship-to-prod |
| verifying → delivered | every env-aware probe green against production; with `deploy: none`, delivered at merge | ship-to-prod, probes owned by proof-of-fix |

- **Invalidation.** Gate, probe and review evidence are bound to a work state or a sha. Any new HEAD
  sends the need back to the earliest stage whose evidence is stale. **Base drift** counts too: if the
  base advanced since the review, ship-to-prod rebases (a new HEAD) and the need re-enters. So the
  merged tree is exactly the tree that was gated, proven and reviewed.
- **Breakers** (budget per need, attempts per stage, CI runs, a failed deployment) move the need to
  `blocked` and escalate (D5). The per-turn block budget is not a breaker (§3).
- **`blocked`** is not driven: the plugins return to standalone behaviour and the user is back in
  control. `conductor.py resume` re-binds and re-enters the stale stage; `abandon` closes the need.
- `mark-done` is emitted by the conductor through ship-when-done's CLI when proving is green. In the
  AUTO scope it is the delivery declaration, not the engagement switch.

### 5. Ownership

| Concern | Owner | State (`.git/`, per worktree) |
|---|---|---|
| need ledger, contract, budgets, escalation, the driven voice, final report | **delivery-conductor** (new) | `conductor.json` (own store, below) |
| probes: bug repros and acceptance probes | **proof-of-fix** (extended) | `proof-of-fix.json` (schema v2: several probes per need) |
| gate, milestone commits, push, PR/MR, `mark-done` | ship-when-done | `swd-*.json` |
| review verdict, pre-push guard | merge-review | `merge-review-*.json` |
| PR CI verdict before merge | mr-watchdog | `mr-watchdog-*.json` |
| merge, post-merge pipeline, production check, revert | **ship-to-prod** (new) | policy `ship-to-prod.json` (trusted, never written by the plugin), state `stp-state.json` |
| CI verdict functions, envelope detection | kernel (shared) | none |

**Acceptance probes are not a separate plugin**: one probe engine, one owner.

**The ledger store** is not the kernel's GC'd session map (a need can wait longer than 7 days).
`conductor.json` has no GC (closed needs are archived to `conductor-archive.jsonl`), is written under
`fcntl.flock` (released by the kernel when a process dies: no timeout, no stale lock) with
compare-and-set on a version counter, and `open` surfaces a failed write.

---

## New and changed plugins

### delivery-conductor (new)

- **Contract.** `conductor.py open` reads the verbatim prompt captured by its UserPromptSubmit hook and
  the criteria from the model. Every criterion names a probe, or is marked non-behavioural with a
  reason. Assumptions are recorded (D2). A need's identity is a durable id plus repo and branch;
  sessions are bindings of it.
- **Budgets and breakers.** Wall clock per need, attempts per stage, CI runs per need. A breaker blocks
  the need and escalates (D5). The 5-blocks-per-turn budget only continues the need (§3).
- **Report.** At `ready` or `delivered`: need, PR/MR, head or merge sha, deployment when any,
  per-criterion evidence, time, cost. Never a field the need did not reach.

### proof-of-fix 2.0 (extended)

- Schema v2: several probes per need, keyed by criterion.
- `record --kind acceptance --criterion <id> [--env-aware] [--read-only]`; `check --need <id>` writes
  per-criterion evidence.
- **Env-aware probes** read `HARNESS_BASE_URL`. During proving it points at a local or preview target
  (the red-first run never touches production); in verifying, ship-to-prod sets it to
  `verify_base_url`. **Only env-aware, read-only probes may run against production** (D7). A need with
  `deploy` set and no such criterion fails contract validation.
- It stamps its script path; its nudge and Stop re-run stand down under the conductor (§1).

### ship-to-prod (new, opt-in per repo)

- **Policy** `.git/ship-to-prod.json` (trusted, read-only for the plugin): `enabled` (default false),
  `merge_method` (squash), `deploy` (`none`, default-branch `pipeline`, or `command`), `verify_base_url`,
  `timeout`, `revert_on_failure`. **State** in `.git/stp-state.json`.
- **Merge** only with the full evidence chain, the PR up to date with its base, bound to the reviewed
  head sha.
- **After merge:** watch the default-branch pipeline at the merge sha, then run the env-aware read-only
  probes against `verify_base_url`.
- **On red:** open a revert PR/MR, block the need, escalate. The revert is merged by a human (D6).

### Changes to existing plugins

| Plugin | Change |
|---|---|
| ship-when-done | `stage` CLI; `gate` subcommand (evidence without the ladder); Stop stands down when driven; stamps its script path; handoff stamps go through the siblings' `handoff` subcommands |
| merge-review | `stage` CLI; `handoff` subcommand; pre-push deny defers to the conductor; SKILL.md "When driven" (judgment only) |
| mr-watchdog | `stage` CLI; `handoff` subcommand; Stop stands down when driven; neutral verdict output under drive; SKILL.md "When driven"; verdict functions move to the kernel |
| proof-of-fix | `stage` CLI; schema v2; env-aware and read-only probes; stamps its script path; nudge and Stop stand down under the conductor |
| kernel | `driven()`, `conductor_scope()`, shared CI verdict functions and envelope detection; `scripts/kernel-sync.py` gains the new plugins |

---

## Guardrails

- **Scope.** The conductor follows the AUTO scope. Excluded trees and `$HOME` sessions: inert.
- **Merge and deploy are opt-in per repo**, bound to the reviewed head sha, on an up-to-date branch,
  with the full evidence chain. Never a force push, never a push to the default branch, revert through
  a PR/MR.
- **Production is touched only by read-only probes**, and only after deployment.
- **Budgets** bound every loop; a stage failing N times in a row blocks the need.
- **The user can always halt**: a prompt classified as halt blocks the need in the same turn.
- **Escalation** only on: a breaker, a blocking ambiguity, a failed deployment.
- The "never merges" guarantees of today's tests and `docs/architecture.md` are rescoped: nothing merges
  unless ship-to-prod is enabled for the repo.

## Testing

- **Hermetic.** Each `stage` CLI in its owner's suite. In `tests/harness`: the driven one-voice
  invariant over generated driven states (hooks, watcher output, driven-mode skill instructions), a
  second session on a driven branch standing down, every transition and invalidation edge (new HEAD,
  base drift), a missing safety-stage owner failing `open`, the ledger lock under concurrent writers.
- **Turn simulator** (`tests/turns`): multi-turn needs, a compaction and a fork in the middle, the
  per-turn budget continuing the need, a halt prompt.
- **E2E lane.** A `needs` space on both sandboxes: need → ready, need → blocked → resumed, and (Phase 3)
  need → delivered and a failed deploy → revert. The sandboxes gain a default-branch deploy job and a
  read-only env-aware endpoint.

## Phases

Each phase is its own PR, evidence-first, reviewed by merge-review, and adds its situations to the E2E
ledger. From Phase 1 on, the work runs in a session launched inside this repository with the AUTO scope
active, so the harness supervises its own construction.

| Phase | Deliverable | Plugins |
|---|---|---|
| 0 | PRs #66, #69, #70, #72, #73 and the GitLab lane merged; AUTO scope activated | all |
| 1 | **Driven one-voice + stage protocol + conductor skeleton.** A need goes from prompt to `ready` (a green, reviewed PR/MR) with zero intervention, surviving compaction and a halt; `asyncRewake` evaluated as the re-entry path | conductor (new), ship-when-done, merge-review, mr-watchdog, proof-of-fix, kernel |
| 2 | **Acceptance probes** (schema v2, env-aware, read-only). Proving checks the contract's criteria | proof-of-fix, conductor |
| 3 | **ship-to-prod.** Up-to-date, sha-bound merge, deployment watch, production verification, revert | ship-to-prod (new), kernel |
| 4 | **Supervisor.** A need survives the death of its session | conductor, claude-remote-spawn |

## Decisions

Signed off 2026-09-26: **D1** need detection by the model on a nudge, no regex classifier; **D2**
proceed on recorded assumptions, escalate only on a blocking unknown; **D3** acceptance probes live in
proof-of-fix; **D4** ship-to-prod off by default, per repo, squash; **D5** a push notification is the
only interruption.

Defaults taken in revision 3 (veto welcome): **D6** reverts are opened automatically and merged by a
human; **D7** only read-only, env-aware probes may run against production.

## Claude Code mechanics the plugins rely on

| Need | Mechanism | Fact |
|---|---|---|
| Start a need without the user typing a skill | UserPromptSubmit captures the prompt and injects the contract step; the model opens the need | F2, F4 |
| Advance a need | the conductor's single Stop decision, within the block budget | F1, F5 |
| Survive a compaction or a resume; keep a fork from stealing the drive | `SessionStart` re-binds on `resume`/`compact`, not on `fork` | F6 |
| Wait on CI, a deployment, the gate or probes; continue past the block budget | a model-launched background task, or an `asyncRewake` hook | F5, F8 |
| Skills calling skills | an instruction that names the skill; the skill's driven-mode section limits it to judgment | F4 |
| A sibling plugin missing | its script stamp is absent: the contract fails for a safety stage | F7 |

## Review log

- **Revision 1** (0/100, 10 findings): one voice limited to Stop; watcher launch as a script step;
  forward-only state machine; invariant contradicting undriven behaviour; cross-writes; ship-to-prod
  policy and state in one file; needs keyed on the session; Stop budget stalls; production probe
  replay; ledger concurrency and GC.
- **Revision 2** (0/100 in pass 2: 6 of those resolved, 4 narrowed, 7 new): skill bodies as a channel;
  handoff stamps still raw writes; fork stealing the drive and session-scoped `driven()`; the block
  budget both continuation and breaker; a missing sibling skipping a safety stage; no end state with
  merging disabled; no producer for gate evidence; no way to halt; the move to `blocked` racing the
  parallel Stop hooks; the merged-sha claim under squash and base drift; unconstrained production
  probes.
- **Revision 3** addresses all of them: the skill-body channel (§1), owner `handoff` subcommands (§2),
  branch-scoped `driven()` with explicit fork adoption (§1, §3), budget as continuation with an internal
  deadline (§2, §3), safety-stage owners required at `open` (§2), the `ready` end state (§4), `ship.py
  gate` (§2), the halt classification (§3), every exit from driven deferred to the next prompt (§1), the
  up-to-date merge with invalidation on base drift (§4), read-only env-aware production probes (D7).
  Also adopted: `asyncRewake` as a candidate re-entry (F8), `fcntl.flock` instead of a stale-lock
  timeout, closed needs archived, `score ≥ threshold` required in the review record, `--auto-merge=false`,
  envelope detection moved to the kernel, the supervisor resuming in the need's worktree.
