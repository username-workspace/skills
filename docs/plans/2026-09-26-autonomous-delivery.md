# Autonomous Delivery: design and plan

> **Status: Accepted** (2026-09-26, decisions D1 to D5 signed off). Revision 2 after a fresh-eyes
> merge-review of revision 1 (10 findings, all addressed below; see "Review log" at the end).

**Goal:** a need stated once is driven to *delivered* (reviewed, merged, deployed, verified in
production) with no human intervention, by plugins that never overlap, invoke each other, and engage
on their own. The user states the need; the harness does the rest and reports back.

**Scope:** repositories inside the AUTO scope (`HARNESS_AUTO_ENGAGE=1`, minus
`HARNESS_AUTO_ENGAGE_EXCLUDE`, minus sessions launched outside a work tree; PR #70). Trees that carry
their own delivery harness (warden, the ZV workspace) keep it; there the new plugins stay inert.

---

## The three constraints, as invariants

1. **No overlap.** Every concern has one owning plugin. A state file is written only by its owner or
   through the owner's CLI (a *sanctioned write*, §5). **While a need is driven, the session receives
   instructions from one source per turn, on every channel** (Stop, UserPromptSubmit, PreToolUse deny
   reasons, background-task output).
2. **Plugins invoke each other.** Through contracts: a read-only `stage` CLI per plugin, sanctioned
   write CLIs, and one instruction naming the next skill when a step needs the model. Never through the
   user.
3. **Self-engaging.** Hooks start and advance the work. The user never types a skill name.

## Facts the design rests on

| # | Fact | How we know |
|---|---|---|
| F1 | Stop hooks of all plugins run **in parallel**; **every** `block` reason reaches the model, as separate "Stop hook feedback" messages in one continuation | measured 2026-09-26: two hooks fired 5 ms apart, the model quoted both reasons |
| F2 | UserPromptSubmit also fires for harness envelopes (`<task-notification>`, `<agent-message>`, `<cross-session-message>`); the payload has no origin field | transcripts + CC 2.1.283 hook input; proof-of-fix filters envelopes by content (PR #66) |
| F3 | `CLAUDE_PROJECT_DIR` is the session's launch dir, stable across `cd` | headless probe (PR #70) |
| F4 | A hook **cannot invoke a skill or a tool**; it injects text or blocks with a reason | hooks guide: command hooks "can't trigger `/` commands or tool calls" |
| F5 | The session is allowed to stop after **8 Stop blocks in one turn** (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, default 8) | CC 2.1.283 binary: `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP??8`, `hit_cap` |
| F6 | `SessionStart` fires with `source` = `startup`, `resume`, `clear`, `compact`, `fork`, and can inject context | hooks guide + binary |
| F7 | No plugin-to-plugin dependency declaration exists | plugins docs |
| F8 | Only a background task **the model launched** re-opens the session when it finishes (task notification); a process a hook spawns is untracked | mr-watchdog design (`watch.py` run is launched by the session with `run_in_background`) + F4 |

**F1 is the root problem, F5 the budget, F8 the only re-entry.** Today three plugins own a Stop hook
and two more channels instruct (proof-of-fix's prompt nudge, merge-review's pre-push deny, the
watcher's verdict text). They avoid collisions through state files and luck.

---

## Architecture

### 1. One voice while driven, on every channel

A need in flight makes `delivery-conductor` the **driver** of its repo and branch. The kernel gains
`driven(repo, session)`: true while the conductor's ledger holds a need bound to that session whose
state is neither `blocked` nor closed.

| Channel | Undriven (today, unchanged) | Driven |
|---|---|---|
| Stop | each plugin's hook may speak | only the conductor speaks, at most one decision; the others call `driven()` and stand down |
| UserPromptSubmit | proof-of-fix nudges bug-shaped prompts | in the conductor's scope the conductor's contract nudge **replaces** proof-of-fix's nudge (a bug need gets a repro criterion); proof-of-fix checks `conductor_scope(repo)` and stands down. This holds on the first prompt too, before the need exists |
| PreToolUse (merge-review pre-push deny) | denies an unreviewed push, reason instructs a review | stays as a safety net; under drive the conductor sequences pushes after a passing review, so the deny cannot fire (tested). If it ever fires, its reason points back to the conductor's current stage instead of prescribing steps |
| Background-task output (watcher) | prints the verdict **and** the fix instruction | prints a neutral verdict line and writes the verdict file; the conductor's next Stop turns it into the single instruction |

**Invariant under test (driven states only):** for every reachable driven state, the union of all
channels in one turn carries at most one instruction. Undriven behaviour is explicitly out of the
invariant: it is today's behaviour, unchanged.

### 2. The stage protocol and sanctioned writes

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
    "run": ["ship.py", "mark-done", "--repo", "R", "--summary", "…"],   # kind=script
    "skill": "mr-watchdog",                                              # kind=skill
    "instruction": "launch `watch.py run --repo R` with run_in_background"
  }
}
```

- **`script`** steps are short and deterministic, and run by the conductor inside its Stop hook:
  commit, push, open the PR/MR, `mark-done`, merge. A script step that can exceed the Stop hook's
  timeout (the gate, a probe run) is not a script step: it becomes a model-launched background step.
- **`skill`** steps need the model: implement, review, fix a red CI, and **launch any watcher** (F8).
  They become the conductor's single instruction.
- **Sanctioned writes.** A plugin never writes another plugin's file directly. It calls the owner's
  CLI: the conductor calls `ship.py mark-done`; ship-when-done's handoff stamps into merge-review's and
  mr-watchdog's session files are named handoffs of those owners (documented as their write API),
  kept for undriven mode.
- **Discovery.** Each plugin stamps its script path in its session file (the convention mr-watchdog
  and merge-review already follow); the conductor finds siblings there and skips a missing one (F7).

### 3. What starts, advances and resumes a need

F5 bounds a turn to 8 Stop blocks. The conductor counts **every** block it emits (skill and script
steps alike) and stops at 5 per turn. Reaching the budget, or a Stop hook timeout, is a breaker: the
conductor's last instruction of the turn launches a background re-entry tick (F8), so the need never
stalls silently. Waits (CI, deployment) always go to background watchers.

| Event | Owner | Effect |
|---|---|---|
| UserPromptSubmit, human prompt, conductor scope | conductor | captures the prompt **verbatim** (the hook has it) and injects the contract step; the model decides whether it is a need and calls `conductor.py open` |
| UserPromptSubmit while a need is in flight | conductor | the model classifies the prompt: an amendment (contract amended, stale stages re-entered) or a new need (queued) |
| Stop | conductor | advances by one step; closing a need takes effect at the next UserPromptSubmit, so `driven()` stays stable during the Stop that closes it |
| SessionStart `resume`, `fork`, `compact` | conductor | re-binds the need to the new session id and re-injects the contract and stage |
| A background task resolves | mr-watchdog, ship-to-prod, re-entry tick | a new turn; the next Stop picks up the verdict file |
| The session dies | supervisor (Phase 4) | resumes a session on the need's branch; SessionStart re-binds it |

### 4. The life of a need

```
contracting → implementing → gating → proving → reviewing → shipping → ci → merging → deploying → verifying → delivered
      ▲             ▲           ▲         ▲          ▲           │        │
      └─────────────┴───────────┴─────────┴──────────┴───────────┴────────┘  a new HEAD re-enters the earliest stage whose evidence it made stale
blocked ⇄ (resume | abandon)      any stage → blocked on a breaker
```

| Transition | Evidence (bound to) | Owner |
|---|---|---|
| contracting → implementing | a valid contract: need verbatim, repo, branch, criteria, assumptions, budget | conductor |
| implementing → gating | work committed as a milestone (ship-when-done commits before review, as today) | ship-when-done |
| gating → proving | project gate green (work state) | ship-when-done `swd-gate.json` |
| proving → reviewing | every acceptance probe green, each red first when it asserts new behaviour (HEAD) | proof-of-fix |
| reviewing → shipping | passing review record (exact HEAD) | merge-review |
| shipping → ci | branch pushed, PR/MR open | ship-when-done |
| ci → merging | CI green (exact head sha) | mr-watchdog |
| merging → deploying | merged **at the reviewed sha** (`gh pr merge --match-head-commit`, `glab mr merge --sha`) | ship-to-prod |
| deploying → verifying | default-branch pipeline green (merge sha); skipped when `deploy: none` | ship-to-prod |
| verifying → delivered | every **env-aware** probe green against production; with `deploy: none`, delivered at merge | ship-to-prod, probes owned by proof-of-fix |

- **Invalidation.** Gate, probe and review evidence are bound to a work state or a sha. Any new HEAD
  (a review fix, a red-CI fix) sends the need back to the earliest stage whose evidence is now stale.
  A need can never merge code that was not gated, proven and reviewed at the merged sha.
- **`blocked`** is not driven: the session's plugins return to their standalone behaviour and the user
  is back in control. Exits: `conductor.py resume` (after an answer or a budget raise) re-binds and
  re-enters the stale stage; `abandon` closes the need.
- `mark-done` is emitted by the conductor through ship-when-done's CLI when proving is green. In the
  AUTO scope, engagement no longer depends on the marker, so the marker is used as the delivery
  declaration, not as the engagement switch.

### 5. Ownership

| Concern | Owner | State (`.git/`) |
|---|---|---|
| need ledger, contract, budgets, escalation, the driven voice, final report | **delivery-conductor** (new) | `conductor.json` (own store, below) |
| probes: bug repros and acceptance probes | **proof-of-fix** (extended) | `proof-of-fix.json` (schema v2: several probes per need) |
| gate, milestone commits, push, PR/MR, `mark-done` | ship-when-done | `swd-*.json` |
| review verdict, pre-push guard | merge-review | `merge-review-*.json` |
| PR CI verdict before merge | mr-watchdog | `mr-watchdog-*.json` |
| merge, post-merge pipeline, production check, revert | **ship-to-prod** (new) | policy `ship-to-prod.json` (trusted, never written by the plugin), state `stp-state.json` |
| CI verdict functions (GitHub checks, GitLab pipelines) | kernel, shared by mr-watchdog and ship-to-prod | none |

**Acceptance probes are not a separate plugin**: one probe engine, one owner.

**The ledger store** is not the kernel's GC'd session map. A need can legitimately wait longer than 7
days (blocked on an answer). `conductor.json` has no GC, is written under an exclusive lock file
(`os.open(O_CREAT | O_EXCL)`, stale-lock break after a timeout) with compare-and-set on a version
counter, and `open` surfaces a failed write instead of swallowing it.

---

## New and changed plugins

### delivery-conductor (new)

- **Contract.** `conductor.py open` reads the verbatim prompt captured by its UserPromptSubmit hook and
  the criteria from the model. Every criterion names a probe, or is marked non-behavioural with a
  reason. Assumptions are recorded (D2). A need's identity is a durable id plus repo and branch;
  sessions are bindings of it.
- **Budgets and breakers.** Wall clock per need, attempts per stage, CI runs per need, 5 Stop blocks
  per turn. A breaker blocks the need and escalates (D5).
- **Report.** On `delivered`: need, PR/MR, merge sha, deployment, per-criterion evidence, time, cost.

### proof-of-fix 2.0 (extended)

- Schema v2: several probes per need, keyed by criterion.
- `record --kind acceptance --criterion <id> [--env-aware]`; `check --need <id>` returns per-criterion
  evidence.
- **Env-aware probes** read `HARNESS_BASE_URL` and target it. Only they count as production evidence:
  replaying a local unit test against "production" proves nothing. A need with `deploy` set and no
  env-aware criterion fails its contract validation (fail closed).
- Its prompt nudge and Stop re-run stand down under the conductor (§1).

### ship-to-prod (new, opt-in per repo)

- **Policy** `.git/ship-to-prod.json` (trusted, read-only for the plugin): `enabled` (default false),
  `merge_method` (squash), `deploy` (`none`, default-branch `pipeline`, or `command`), `verify_base_url`,
  `timeout`, `revert_on_failure`. **State** in `.git/stp-state.json`.
- **Merge** only at the reviewed sha, only with the full evidence chain, through the forge's native
  merge bound to that sha.
- **After merge:** watch the default-branch pipeline at the merge sha (kernel verdict functions, a
  model-launched watcher, F8), then run the env-aware probes against `verify_base_url`.
- **On red:** open a revert PR/MR, block the need, escalate. The revert is merged by a human (D6).

### Changes to existing plugins

| Plugin | Change |
|---|---|
| ship-when-done | `stage` CLI; Stop stands down when driven; stamps its script path; handoff stamps documented as sanctioned writes |
| merge-review | `stage` CLI; pre-push deny reason defers to the conductor under drive |
| mr-watchdog | `stage` CLI; Stop stands down when driven; neutral verdict output under drive; verdict functions move to the kernel |
| proof-of-fix | `stage` CLI; schema v2; env-aware probes; nudge and Stop stand down under the conductor |
| kernel | `driven()`, `conductor_scope()`, shared CI verdict functions; `scripts/kernel-sync.py` gains the new plugins |

---

## Guardrails

- **Scope.** The conductor follows the AUTO scope. Excluded trees and `$HOME` sessions: inert.
- **Merge and deploy are opt-in per repo**, bound to the reviewed sha, and require the full evidence
  chain. Never a force push, never a push to the default branch, revert through a PR/MR.
- **Budgets** bound every loop; a stage failing N times in a row blocks the need.
- **Escalation** only on: budget exhausted, repeated failure, a blocking ambiguity, a failed deploy.
- The "never merges" guarantees of today's tests and `docs/architecture.md` are rescoped: nothing merges
  unless ship-to-prod is enabled for the repo.

## Testing

- **Hermetic.** Each `stage` CLI in its owner's suite. In `tests/harness`: the driven one-voice
  invariant across all four channels over generated driven states; every transition and every
  invalidation edge with stubbed forges; the ledger lock under concurrent writers.
- **Turn simulator** (`tests/turns`): multi-turn needs, a compaction and a fork in the middle, the Stop
  budget breaker.
- **E2E lane.** A `needs` space on both sandboxes: need → delivered, need → blocked → resumed, and a
  failed deploy → revert. The sandboxes gain a default-branch deploy job and an env-aware endpoint.

## Phases

Each phase is its own PR, evidence-first, reviewed by merge-review, and adds its situations to the E2E
ledger. From Phase 1 on, the work runs in a session launched inside this repository with the AUTO scope
active, so the harness supervises its own construction.

| Phase | Deliverable | Plugins |
|---|---|---|
| 0 | PRs #66, #69, #70, #72, #73 and the GitLab lane merged; AUTO scope activated | all |
| 1 | **Driven one-voice + stage protocol + conductor skeleton.** A need goes from prompt to a green PR/MR with zero intervention, surviving compaction | conductor (new), ship-when-done, merge-review, mr-watchdog, proof-of-fix, kernel |
| 2 | **Acceptance probes** (schema v2, env-aware). Proving checks the contract's criteria | proof-of-fix, conductor |
| 3 | **ship-to-prod.** Sha-bound merge, deployment watch, production verification, revert | ship-to-prod (new), kernel |
| 4 | **Supervisor.** A need survives the death of its session | conductor, claude-remote-spawn |

## Decisions (signed off 2026-09-26)

- **D1. Need detection.** Every human prompt in the conductor's scope gets the contract nudge; the model
  decides whether it is a need and opens it. No regex classifier.
- **D2. Ambiguity.** Proceed on assumptions recorded in the contract; escalate only when an unknown
  blocks the work.
- **D3. Acceptance probes live in proof-of-fix.** No separate plugin.
- **D4. ship-to-prod is off by default**, enabled repo by repo; merge method squash.
- **D5. Escalation.** The conductor instructs the session to send a push notification; nothing else
  interrupts the user.
- **D6. Reverts** are opened automatically and merged by a human.

## Claude Code mechanics the plugins rely on

| Need | Mechanism | Fact |
|---|---|---|
| Start a need without the user typing a skill | UserPromptSubmit captures the prompt and injects the contract step; the model opens the need | F2, F4 |
| Advance a need | the conductor's single Stop decision, within the block budget | F1, F5 |
| Survive a compaction, a resume or a fork | `SessionStart` re-binds and re-injects | F6 |
| Wait on CI or a deployment, or continue past the block budget | a background task launched by the model | F5, F8 |
| Skills calling skills | an instruction that names the skill; the model invokes it | F4 |
| A sibling plugin missing | its script stamp is absent: skip the stage | F7 |

## Review log

Revision 1 scored 0/100 in a fresh-eyes merge-review. Its ten findings and where they are addressed:
one voice limited to Stop (§1, all channels); watcher launch as a script step (§2, F8); forward-only
state machine, commit placement, `blocked` exits (§4); invariant contradicting undriven behaviour (§1,
driven states only); cross-writes versus ownership (§2, sanctioned writes); ship-to-prod policy and
state sharing a file (§5); needs keyed on the session (§3, §4, durable need id plus re-binding); Stop
budget stalls (§3, breaker plus background re-entry); production probe replay (proof-of-fix 2.0,
env-aware probes); ledger concurrency and GC (§5, own locked store). Suggestions adopted: merge bound
to the reviewed sha, verbatim prompt captured by the hook, script-path stamps for discovery,
kernel-sync update, guardrail tests rescoped, `deploy: none` semantics, follow-up prompts while a need
is in flight.
