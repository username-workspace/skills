# Autonomous Delivery: design and plan

> **Status: Proposed** (2026-09-26). Decisions D1 to D5 below need Benjamin's sign-off before Phase 1.

**Goal:** a need stated once is driven to *delivered* (reviewed, merged, deployed, verified in
production) with no human intervention, by plugins that never overlap, invoke each other, and engage
on their own. The user states the need; the harness does the rest and reports back.

**Scope:** repositories inside the AUTO scope (`HARNESS_AUTO_ENGAGE=1`, minus
`HARNESS_AUTO_ENGAGE_EXCLUDE`, minus sessions launched outside a work tree). Trees that carry their own
delivery harness (warden, the ZV workspace) keep it; there the new plugins stay inert.

---

## The three constraints, as invariants

1. **No overlap.** Every concern and every state file has exactly one owning plugin. Others read,
   never write. Two plugins never give the session instructions in the same turn.
2. **Plugins invoke each other.** Through contracts: a deterministic `stage` CLI per plugin, and
   instructions that name the next skill when a step needs the model. Never through the user.
3. **Self-engaging.** Hooks start and advance the work. The user never types a skill name.

## Facts the design rests on

| # | Fact | How we know |
|---|---|---|
| F1 | Stop hooks of all plugins run **in parallel**, and **every** `block` reason is delivered to the model, as separate "Stop hook feedback" messages in one continuation | measured 2026-09-26: two hooks fired 5 ms apart, the model quoted both reasons |
| F2 | UserPromptSubmit also fires for harness envelopes (`<task-notification>`, `<agent-message>`, `<cross-session-message>`); the payload carries no origin field | transcripts + CC 2.1.283 hook input (proof-of-fix 1.1.0 filters envelopes by content) |
| F3 | `CLAUDE_PROJECT_DIR` is the session's launch dir, stable across `cd` | headless probe (PR #70) |
| F4 | A hook **cannot invoke a skill or a tool**: it can only inject text (`additionalContext`) or block with a reason | hooks guide: "Command hooks … can't trigger `/` commands or tool calls" |
| F5 | Claude Code lets the session stop after **8 Stop blocks in one turn** (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, default 8) | CC 2.1.283 binary: `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP??8`, `hit_cap` |
| F6 | `SessionStart` fires with `source` = `startup`, `resume`, `clear`, `compact`, `fork`, and can inject context; `PostCompact` exists | hooks guide + binary |
| F7 | No plugin-to-plugin dependency declaration exists in `plugin.json` / `marketplace.json` | plugins docs (not documented) |

**F1 is the root problem, F5 the budget.** Today three plugins own a Stop hook (ship-when-done, mr-watchdog,
proof-of-fix). They avoid collisions through state files and luck. Adding three more voices would make
contradictory instructions in one turn a matter of time. The design makes it impossible by
construction.

---

## Architecture

### 1. One voice at the Stop

A **need in flight** for (repo, session) makes `delivery-conductor` the *driver* of that repo for that
session. The kernel gains `driven(repo, session)`, true while the conductor's ledger holds an open need
for them.

- Every other plugin's Stop hook calls `driven()` first and **stands down silently** when it is true.
- The conductor's Stop hook is the only one that speaks. It calls the other plugins' `stage` CLIs **in a
  fixed order** and emits **at most one** decision.
- No need in flight: today's behaviour, unchanged. Each plugin still works alone.
- PreToolUse guards (the merge-review pre-push gate) are not voices. They deny a tool call; they never
  instruct the next step. They stay as they are.

**Invariant under test:** for every reachable state, running all installed Stop hooks in parallel on
the same payload yields at most one `block` and at most one `systemMessage`.

### 2. The stage protocol (how plugins invoke each other)

Each harness plugin exposes one read-only entry point:

```
<plugin>.py stage --repo R --session S --need N --json
{
  "stage": "ci",
  "state": "pending | ready | blocked | done",
  "evidence": { ... },                      # what the verdict rests on (sha, file, verdict)
  "next": {
    "kind": "none | script | skill",
    "run": ["watch.py", "run", "--repo", "R"],   # kind=script: executed by the conductor itself
    "skill": "merge-review",                  # kind=skill: named in the conductor's instruction
    "instruction": "…"                        # what the model must do, with its packet
  }
}
```

- `script` steps are **deterministic** (commit, push, open PR, start a watcher, merge). The conductor
  runs them; no model turn is spent.
- `skill` steps need **judgment** (implement, review, fix a red CI). They become the conductor's single
  instruction: *invoke skill X with this packet*. The model invokes it; the user never does.
- A skill may itself name the next skill in its instructions (merge-review → "fix the attested
  findings, then continue"), but only the conductor decides **which stage is current**.

The stage CLI is a **versioned contract** (`"v": 1` in the output), covered by hermetic tests in the
owning plugin and in `tests/harness`.

### 3. What starts and advances a need

F5 bounds how far one turn can go: at most 8 consecutive Stop blocks. The conductor therefore spends
Stop blocks only on **short, deterministic steps** (at most 5 per turn, leaving headroom for the other
voices it replaces), and hands every **wait** (CI, deployment) to a background watcher. A watcher that
resolves re-invokes the session with a task notification, which opens a new turn and a fresh budget.
F4 means "invoking a skill" always goes through the model: the conductor's single instruction names the
skill and carries its packet.

| Event | Owner | Effect |
|---|---|---|
| UserPromptSubmit, human prompt, AUTO scope | conductor | injects the contract step: *if this is a development need, open it* (`conductor.py open`) with acceptance criteria |
| Stop | conductor (sole voice) | advances the state machine by one step |
| SessionStart after resume or compaction | conductor | re-injects the need's contract and current stage |
| A background watcher resolves | mr-watchdog, ship-to-prod | re-invokes the session (task notification); the next Stop picks it up |
| The session dies | supervisor (Phase 4) | resumes a session on the need |

### 4. The life of a need

```
contracting → implementing → proving → reviewing → shipping → ci → merging → deploying → verifying → delivered
                                                                                          ↘ blocked (budget, repeated failure, blocking ambiguity)
```

| Transition | Evidence required | Written by |
|---|---|---|
| contracting → implementing | a valid contract: need verbatim, repo, acceptance criteria, assumptions, budget | conductor |
| implementing → proving | the project gate green on the work state | ship-when-done (`swd-gate.json`) |
| proving → reviewing | every acceptance probe green, each recorded red first when it asserts new behaviour | proof-of-fix |
| reviewing → shipping | a passing review record for the exact HEAD | merge-review |
| shipping → ci | branch pushed, PR/MR open | ship-when-done |
| ci → merging | CI green at the exact head sha | mr-watchdog |
| merging → deploying | merged, merge sha known | ship-to-prod |
| deploying → verifying | the default-branch pipeline green at the merge sha | ship-to-prod |
| verifying → delivered | the acceptance probes green against production | ship-to-prod (probes owned by proof-of-fix) |

No transition happens on the model's say-so. `mark-done` becomes an **output of the conductor**, emitted
when the proving stage is green: the explicit mode's determinism is kept, without a human declaration.

### 5. Ownership

| Concern | Owner | State (`.git/`) |
|---|---|---|
| need ledger, contract, budgets, escalation, the Stop voice, final report | **delivery-conductor** (new) | `conductor.json` |
| probes: bug repros **and** acceptance probes | **proof-of-fix** (extended) | `proof-of-fix.json` |
| gate, commits, push, PR/MR | ship-when-done | `swd-*.json` |
| review verdict, pre-push guard | merge-review | `merge-review-*.json` |
| PR CI verdict (before merge) | mr-watchdog | `mr-watchdog-*.json` |
| merge, post-merge pipeline, production check, revert | **ship-to-prod** (new) | `ship-to-prod.json` |
| CI verdict functions (GitHub checks, GitLab pipelines) | kernel, shared by mr-watchdog and ship-to-prod | none |

**Acceptance probes are not a separate plugin.** Two probe engines would own the same concept (a
command that must go red then green). proof-of-fix already is that engine; it gains a probe kind.

---

## New and changed plugins

### delivery-conductor (new)

- **Contract.** `conductor.py open --need <verbatim> --criteria <json>` validates the contract. Every
  criterion is a testable statement with a probe, or is marked non-behavioural with a reason.
  Assumptions are recorded, not asked (D2).
- **Ledger.** One entry per need: id, session, repo, stage, attempts per stage, timestamps, evidence
  pointers. Kernel v1 multi-session map, atomic writes.
- **Budgets and breakers.** Wall-clock per need, attempts per stage, CI runs per need. A breaker moves
  the need to `blocked` and escalates (D5). Nothing else escalates.
- **Report.** On `delivered`: need, PR/MR, merge sha, deployment, the probe evidence, time and cost.
- **Stop.** The sole voice while a need is in flight (§1).

### proof-of-fix 2.0 (extended)

- `record --kind acceptance --criterion <id>`: several probes per need, each red-before when it asserts
  new behaviour (same rule as a bug repro).
- `check --need <id>` runs them all and returns per-criterion evidence. `--base-url` lets ship-to-prod
  replay the same probes against production.
- Its own Stop re-run stands down when driven; the conductor runs `check` at the proving stage.

### ship-to-prod (new, opt-in per repo)

- **Policy** in `.git/ship-to-prod.json` (trusted source only): `enabled` (default false),
  `merge_method` (squash), `deploy` (`none`, default-branch `pipeline`, or `command`), `health_url`,
  `verify_base_url`, `timeout`, `revert_on_failure`.
- **Merge** through the forge's native auto-merge (`gh pr merge --auto --squash`,
  `glab mr merge --auto-merge --squash`), and only when CI is green at the exact sha, the review
  passed and every acceptance probe is green.
- **After merge:** watch the default-branch pipeline at the merge sha (kernel verdict functions), then
  replay the acceptance probes against production.
- **On red:** open a revert PR/MR, move the need to `blocked`, escalate.

### Changes to existing plugins

| Plugin | Change |
|---|---|
| ship-when-done | `stage` CLI; Stop stands down when driven; `mark-done` emitted by the conductor |
| merge-review | `stage` CLI (review state for HEAD); pre-push guard unchanged |
| mr-watchdog | `stage` CLI; Stop stands down when driven; CI verdict functions move to the kernel |
| proof-of-fix | `stage` CLI; acceptance probes; Stop stands down when driven |

---

## Guardrails

- **Scope.** The conductor follows the AUTO scope. Excluded trees and `$HOME` sessions: inert.
- **Merge and deploy are opt-in per repo** and require the full evidence chain. Never a force push,
  never a push to the default branch, revert through a PR/MR.
- **Budgets** bound every loop. A stage failing N times in a row blocks the need instead of retrying.
- **Escalation** only on: budget exhausted, repeated failure, a blocking ambiguity in the contract.

## Testing

- **Hermetic.** Each plugin's `stage` CLI in its own suite. In `tests/harness`: the one-voice invariant
  (all Stop hooks in parallel over generated states, at most one `block`), and every state-machine
  transition with stubbed forges.
- **Turn simulator** (`tests/turns`): multi-turn needs, including a compaction in the middle.
- **E2E lane.** A new `needs` space: need → delivered on both sandboxes. The sandboxes gain a
  default-branch "deploy" job and a verifiable artefact, so ship-to-prod is proven on real forges.

## Phases

Each phase is its own PR, evidence-first, and adds its situations to the E2E ledger.

| Phase | Deliverable | Plugins |
|---|---|---|
| 0 | Current PRs merged (#66, #69, #70, #72, #73, the GitLab lane); AUTO scope activated | all |
| 1 | **One voice + stage protocol + conductor skeleton.** A need goes from prompt to a green PR/MR with zero intervention | conductor (new), ship-when-done, merge-review, mr-watchdog, proof-of-fix, kernel |
| 2 | **Acceptance probes.** The proving stage checks the contract's criteria, not only the test suite | proof-of-fix, conductor |
| 3 | **ship-to-prod.** Merge, deployment watch, production verification, revert | ship-to-prod (new), kernel |
| 4 | **Supervisor.** A need survives the death of its session (resume through claude-remote-spawn plus a launchd/systemd timer) | conductor, claude-remote-spawn |

## Decisions for Benjamin

- **D1. Need detection.** Every human prompt in the AUTO scope gets the contract nudge; the model
  decides whether it is a need and opens it. No regex classifier.
- **D2. Ambiguity.** Proceed on assumptions recorded in the contract; escalate only when an unknown
  blocks the work.
- **D3. Acceptance probes live in proof-of-fix.** No separate plugin (no overlap).
- **D4. ship-to-prod is off by default**, enabled repo by repo; merge method squash.
- **D5. Escalation channel.** The conductor instructs the session to send a push notification; nothing
  else interrupts the user.

## Claude Code mechanics the plugins rely on

| Need | Mechanism | Fact |
|---|---|---|
| Start a need without the user typing a skill | UserPromptSubmit injects the contract step; the model opens the need | F2, F4 |
| Advance a need | the conductor's single Stop decision | F1, F5 |
| Survive a compaction or a resume | `SessionStart` (`compact`, `resume`) re-injects the contract and the stage | F6 |
| Wait on CI or a deployment | a background watcher; its completion is a new turn | F5 |
| Skills calling skills | an instruction that names the skill; the model invokes it | F4 |
| A sibling plugin missing | read its state file or skip the stage; never a hard dependency | F7 |
