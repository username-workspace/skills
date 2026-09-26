# Autonomous Delivery: design and plan

> **Status: Accepted** (2026-09-26). Decisions D1 to D5 approved by Benjamin with the go for Phase 1;
> D6 to D8 are defaults, open to veto. Revision 7 after six fresh-eyes merge-review passes (see
> "Review log" at the end).

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
| F2 | UserPromptSubmit also fires for harness envelopes (`<task-notification>`, `<agent-message>`, `<cross-session-message>`); the payload's `source` field (`user`, `system`, …) is declared in the 2.1.283 schema but not always filled | transcripts + CC 2.1.283 hook input; proof-of-fix filters envelopes by content (PR #66, merged) |
| F3 | `CLAUDE_PROJECT_DIR` is the session's launch dir, stable across `cd` | headless probe (PR #70) |
| F4 | A command hook **cannot invoke a skill or a tool**; it injects text or blocks with a reason (agent-type hooks can use tools but cannot drive the main session) | hooks guide: command hooks "can't trigger `/` commands or tool calls" |
| F5 | The session is allowed to stop after **8 consecutive Stop blocks with no tool call between them**; any tool call resets the count (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, default 8) | CC 2.1.283 binary: `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP??8`, "blocked the turn from ending N consecutive times", `stopHookBlockingCount:0` on `next_turn` |
| F6 | `SessionStart` fires with `source` = `startup`, `resume`, `clear`, `compact`, `fork`, and can inject context | hooks guide + binary |
| F7 | A plugin can declare `dependencies` in `plugin.json` ("Plugins that must be enabled for this plugin to function"; bare names resolve in the same marketplace); Claude Code enforces them at install and update | CC 2.1.283 plugin manifest schema (`dependency_missing`, "is still required by") |
| F8 | Re-entry after a wait: a background task **the model launched** (proven: mr-watchdog); a hook declared **`asyncRewake`**, which runs in the background and wakes the model on exit code 2; a scheduled wake-up (ScheduleWakeup, CronCreate). The Stop input also carries `background_tasks`, which tells *waiting on background work* from *done*. A process a hook spawns without `asyncRewake` is untracked | `watch.py` design; CC 2.1.283 hook schema and Stop input |

---

## Architecture

### 1. One voice while driven, on every channel

A need in flight makes `delivery-conductor` the **driver of its branch**. The kernel gains
`driven(repo, branch, session)`:

- true for the session bound to the need (the driver);
- **also true for any other session on that branch**: it stands down entirely, so a second session
  can neither act on nor amend a need it does not drive;
- **still true while the need is `blocked`**: a blocked branch is *held*. Every sibling stays silent
  and the conductor speaks only to report the block, once. Otherwise a breaker or a halt would hand the
  branch back to siblings that, in the AUTO scope, commit, push and watch on their own;
- **still true for an abandoned need** until its branch is deleted or explicitly released
  (`conductor.py release`, which also clears ship-when-done's marker through its CLI): in the AUTO
  scope the siblings would otherwise re-engage on their own and review, push, fix CI and ship the work
  the user abandoned;
- false once the need reaches `ready` or `delivered`, or its abandoned branch is released. **Every
  transition out of driven takes effect at the next UserPromptSubmit of any session** (the deciding
  `prompt_id` is recorded), so `driven()` is stable during the Stop that decides it and no sibling can
  speak in that turn.

An absent ledger reads as not driven (an uninstalled conductor is inert). A corrupt one fails closed: the branches it may hold stay held and the conductor surfaces the corruption.

| Channel | Outside the conductor's scope (unchanged) | Driven |
|---|---|---|
| Stop | each plugin's hook may speak | only the conductor speaks, at most one decision; the others call `driven()` and stand down |
| UserPromptSubmit | proof-of-fix nudges bug-shaped prompts | inside the conductor's scope the conductor's contract nudge **replaces** proof-of-fix's nudge, from the first prompt on (a bug need gets a repro criterion); proof-of-fix checks `conductor_scope(repo, session)`, a per-session stamp the conductor writes at SessionStart (so an uninstalled conductor never silences it), and stands down |
| PreToolUse (merge-review pre-push deny) | denies an unreviewed push, reason instructs a review | pushes are sequenced by the conductor after a passing review, so the deny cannot fire (tested); if it ever does, its reason points back to the conductor. Pushes run inside the conductor's Stop never reach PreToolUse: their safety net is ship-when-done's `review_gate_pending` check, which the new `push` subcommand keeps |
| Background-task output (watchers, `ship.py gate`, `repro.py check`, deployment wait) | prints the verdict **and** the next step (the watcher's "fix the root cause, push"; `record`'s "fix the root cause, then run check") | every background step prints a neutral verdict line and writes its evidence file; the conductor's next Stop turns it into the single instruction (each step receives `--session` so it can evaluate `driven()`) |
| Skill bodies | a skill prescribes its own sequence (merge-review: fix, commit, re-review; mr-watchdog: fix, verify, push) | a skill invoked under drive performs **its judgment step only** (review, fix); commit, push and re-entry are the conductor's. Each harness SKILL.md gains a "When driven" section saying so |

**Invariant under test (driven states only):** for every reachable driven state, the union of the hook
channels and the invoked skill's driven-mode instructions carries at most one instruction per Stop decision.

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
- **Dependencies and discovery.** delivery-conductor's `plugin.json` declares `dependencies` on
  ship-when-done, merge-review, mr-watchdog and proof-of-fix (F7), so it cannot be enabled without them.
  ship-to-prod stays optional and is checked at `open` when the repo enables it. Script-path stamps
  remain for what only they give: the sibling's path and per-repo enablement (e.g. merge-review's
  `prepush_gate`). **A safety-stage owner that is disabled for the repo fails the contract at `open`**:
  the need never starts without its full evidence chain. Nothing is skipped silently.
- **Identity comes from hooks.** The CLIs the model runs sit under a transient shell and never see
  `prompt_id`, so the conductor's SessionStart and UserPromptSubmit hooks stamp `CLAUDE_PID` and the
  current `prompt_id`; `open`, `adopt`, `abandon` and `release` read that stamp. `open` creates the
  need's own branch, named after the need id (never a name that a held or deleted branch may carry),
  before anything is committed.
- **`open` checks that every stage can run**, not only that its owner is enabled: a remote exists, the
  forge CLI is present, ship-when-done is not in `suggest` mode.
- **Evidence is bound to the tree it ran on.** A background gate or probe run records the work state
  before it starts and stores a pass only if the state is unchanged when it ends. The review record is
  bound to the reviewed sha (`review.py record --sha`), not to whatever HEAD is when it is written.

### 3. What starts, advances and resumes a need

F5 caps **consecutive** Stop blocks, and every conductor instruction leads to a tool call, which resets
the count: advancing a need never runs into the cap. What F5 does protect against is a loop that makes
no progress, so the conductor owns that guard itself: **three consecutive blocking Stop decisions with
no change in work state or evidence** are a no-progress breaker (the need is blocked and escalated),
well before Claude Code's cap. A Stop counts as **waiting**, not stalling, only while **the need's own
background step** is in flight: the task id or command the conductor instructed, recorded when it
issued the instruction and matched against the Stop input's `background_tasks` with a running status.
Any other background work (a dev server, a monitor) neither suspends the need nor exempts the Stop from
the breaker. While it waits, the conductor keeps a scheduled wake-up (`session_crons`), so the
wall-clock breaker still fires in an idle session. **The conductor never advances past a human prompt
whose classification (§ below) was not recorded** (D8): a missed halt cannot turn into one more step. The conductor never uses `stop_hook_active` as a
re-entry guard: it stays true for the rest of the prompt after the first block. Waits always go to the
background.

| Event | Owner | Effect |
|---|---|---|
| UserPromptSubmit, human prompt, conductor scope | conductor | captures the prompt **verbatim** (the hook has it) and injects the contract step; the model decides whether it is a need and calls `conductor.py open` |
| UserPromptSubmit while a need is in flight | conductor | the model classifies the prompt: **halt** (the need is blocked and held at once, §1; background steps still running finish, their verdicts are recorded but acted on only after resume), **resume** or **abandon** of a blocked need (abandon keeps the branch held, §1), **amendment** (contract amended, stale stages re-entered; a follow-up on a need at `ready`, such as review comments, re-opens it on its branch), **new need** (queued: it starts when the current need reaches an end state, on its own branch from the base; a blocked need keeps the queue waiting, an abandoned one releases it) or **neither** (a question or a status check: answered, the need untouched) |
| Stop | conductor | advances by one step |
| SessionStart `compact`, `clear` | conductor | same terminal, same logical session: re-binds the need and re-injects the contract and stage. The payload carries no parent id, so the conductor recognises the successor by the Claude Code process it records at binding (`CLAUDE_PID`, set for hooks and for the model's shell): `clear` in the driver's process re-binds, `clear` in any other process gets the notice below |
| SessionStart `resume` | conductor | re-binds only when the resumed session is the bound one; resuming an unrelated session in the worktree does not take the drive |
| SessionStart `fork`, `startup`, or any session landing on a branch it does not drive | conductor | no drive; injects one line naming the need, its driver, its last activity and `conductor.py adopt`, so a stall is never silent. Adopting moves the binding (proving evidence is keyed by need, so it follows) |
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
| ci → ready | CI green (exact head sha), merging not enabled; the draft PR/MR is marked ready for review | mr-watchdog, ship-when-done |
| ci → merging | CI green (exact head sha), ship-to-prod enabled | mr-watchdog |
| merging → deploying | the draft flag cleared, the PR **up to date with its base** under the forge's own rule (GitHub "require branches to be up to date", GitLab fast-forward or semi-linear merge), merged at the reviewed head sha (`gh pr merge --match-head-commit`, `glab mr merge --sha`, `--auto-merge=false`) | ship-to-prod |
| deploying → verifying | default-branch pipeline green (merge sha); skipped when `deploy: none` | ship-to-prod |
| verifying → delivered | every env-aware probe green against production; with `deploy: none`, delivered at merge; with `deploy: command`, the command's exit code is the deploying evidence | ship-to-prod, probes owned by proof-of-fix |

- **Invalidation.** Gate, probe and review evidence are bound to a work state or a sha. Any new HEAD
  sends the need back to the earliest stage whose evidence is stale. **Base drift** counts too: if the
  base advanced since the review, the branch is updated forge-side (`gh pr update-branch --rebase`,
  `glab mr rebase`, never a local force push), synced locally, and the need re-enters. With the forge
  enforcing up-to-date merges, the merged tree is the tree that was gated, proven and reviewed.
- **No CI.** A repo without CI is declared at `open` (`ci: none` in the contract); the `ci` stage is then
  satisfied by the gate evidence at the pushed sha, and the report says so.
- **Breakers** (budget per need, attempts per stage, CI runs, no progress over three Stop decisions, a
  failed deployment) move the need to `blocked` and escalate (D5).
- **`blocked`** holds the branch (§1): siblings silent, the conductor reports once. `conductor.py
  resume` drives again from the stale stage; `abandon` closes the need and keeps its branch held until
  it is deleted or released (§1).
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
`conductor.json` has no GC (a need is archived to `conductor-archive.jsonl` when it reaches `ready` or `delivered`, or when its abandoned branch is released or deleted, never while it holds a branch), is written under
`fcntl.flock` (released by the OS when a process dies: no timeout, no stale lock) with
compare-and-set on a version counter, and `open` surfaces a failed write.

---

## New and changed plugins

### delivery-conductor (new)

- **Contract.** `conductor.py open` reads the verbatim prompt captured by its UserPromptSubmit hook and
  the criteria from the model. Every criterion names a probe, or is marked non-behavioural with a
  reason. Assumptions are recorded (D2). A need's identity is a durable id plus repo and branch;
  sessions are bindings of it.
- **Budgets and breakers.** Wall clock per need, attempts per stage, CI runs per need. A breaker blocks
  the need and escalates (D5: the conductor's report instruction asks the model to send a push
  notification, since a hook cannot call a tool, F4). The no-progress breaker (§3) is one of them.
- **Report.** At `ready` or `delivered`: need, PR/MR, head or merge sha, deployment when any,
  per-criterion evidence, time, cost. Never a field the need did not reach.

### proof-of-fix 2.0 (extended)

- Schema v2: several probes per need, keyed by need and criterion (not by session), so adopting a need
  carries its evidence.
- `record --kind acceptance --criterion <id> [--env-aware] [--read-only]`; `check --need <id>` writes
  per-criterion evidence.
- **Env-aware probes** read `HARNESS_BASE_URL`. During proving it points at a local or preview target
  (the red-first run never touches production); in verifying, ship-to-prod sets it to
  `verify_base_url`. **Only env-aware, read-only probes may run against production** (D7). Read-only is
  a declaration by the recorder, not an enforced property; the trusted policy may add a host and method
  allowlist. A need with `deploy` set and no such criterion fails contract validation.
- It stamps its script path; its nudge and Stop re-run stand down under the conductor (§1).

### ship-to-prod (new, opt-in per repo)

- **Policy** `.git/ship-to-prod.json` (trusted, read-only for the plugin): `enabled` (default false),
  `merge_method` (squash), `deploy` (`none`, default-branch `pipeline`, or `command`), `verify_base_url`,
  `timeout`, `revert_on_failure`. **State** in `.git/stp-state.json`.
- **Merge** only with the full evidence chain, the PR up to date with its base, bound to the reviewed
  head sha.
- **After merge:** watch the default-branch pipeline at the merge sha, then run the env-aware read-only
  probes against `verify_base_url`.
- **On red:** open a revert PR/MR through the forge CLI (ship-to-prod owns reverts), block the need,
  escalate. The revert is merged by a human (D6).
- **Base drift** is ship-to-prod's, in repos that enable merging (a `ready` need hands the branch to a
  human as is): it requests the forge-side update and ship-when-done syncs and pushes the branch. At `open` it checks that the forge enforces up-to-date merges, and fails the
  contract otherwise. Its policy is read from the repository's common git dir, so linked worktrees see
  it.

### Changes to existing plugins

| Plugin | Change |
|---|---|
| ship-when-done | `stage` CLI; `gate` subcommand (evidence without the ladder); Stop stands down when driven; stamps its script path; handoff stamps go through the siblings' `handoff` subcommands |
| merge-review | `stage` CLI; `handoff` subcommand; pre-push deny defers to the conductor; SKILL.md "When driven" (judgment only) |
| mr-watchdog | `stage` CLI; `handoff` subcommand; `run` writes its verdict file (today it only prints); Stop stands down when driven; neutral verdict output under drive; SKILL.md "When driven"; verdict functions move to the kernel |
| proof-of-fix | `stage` CLI; schema v2; env-aware and read-only probes; stamps its script path; nudge and Stop stand down under the conductor |
| merge-review (bis) | `record --sha` binds the verdict to the reviewed sha |
| ship-when-done (bis) | owner subcommands for the conductor's script steps: `commit`, `push` (keeps `review_gate_pending`), `open-pr` and `mark-ready` (both consume the `mark-done` marker, as `engage` does today), `sync` (base drift), `clear-done` (release). Today commit, push and PR creation are only reachable through `engage`, which runs the gate synchronously, or `ladder` |
| kernel | `driven()`, `conductor_scope()`, shared CI verdict functions and envelope detection (preferring the UserPromptSubmit `source` field, declared in the 2.1.283 schema, whenever Claude Code fills it: `user` and `sdk` are human, `system`, `*_wakeup` and `poll_event` are machine; content matching otherwise); `scripts/kernel-sync.py` gains the new plugins |

---

## Guardrails

- **Scope.** The conductor follows the AUTO scope. Excluded trees and `$HOME` sessions: inert.
- **Merge and deploy are opt-in per repo**, bound to the reviewed head sha, on an up-to-date branch,
  with the full evidence chain. Never a force push, never a push to the default branch, revert through
  a PR/MR.
- **Production is touched only by read-only probes**, and only after deployment, apart from the deployment itself (`deploy: command`, a trusted-policy command whose exit code and the default-branch pipeline are its evidence).
- **Budgets** bound every loop; a stage failing N times in a row blocks the need.
- **The user can always halt**: a prompt classified as halt blocks the need in the same turn.
- **Escalation** only on: a breaker, a blocking ambiguity, a failed deployment.
- The "never merges" guarantees of today's tests and `docs/architecture.md` are rescoped: nothing merges
  unless ship-to-prod is enabled for the repo.

## Testing

- **Hermetic.** Each `stage` CLI in its owner's suite. In `tests/harness`: the driven one-voice
  invariant over generated driven states (hooks, watcher output, driven-mode skill instructions), a
  second session on a driven branch standing down, a blocked need keeping every sibling silent until
  resume, an abandoned need keeping them silent until release or branch deletion (and a release letting
  them re-engage at the next prompt), a corrupt ledger holding its branches, the no-progress breaker
  ignoring an unrelated background task, every transition and invalidation edge (new HEAD, base drift), a disabled
  safety-stage owner failing `open`, the ledger lock under concurrent writers.
- **Turn simulator** (`tests/turns`): multi-turn needs; a compaction, a `/clear`, a fork and a fresh
  start in the worktree in the middle; the no-progress breaker; halt, resume and abandon prompts; a
  queued need starting at the current need's end state.
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
| 1 | **Driven one-voice + stage protocol + conductor skeleton.** A need goes from prompt to `ready` (a green, reviewed PR/MR) with zero intervention, surviving compaction and a halt; until Phase 2, proving checks the recorded bug repros only (still session-keyed, so re-binding passes the recording session id, and a need-bound repro is exempt from the 7-day session GC); `asyncRewake` evaluated as the re-entry path | conductor (new), ship-when-done, merge-review, mr-watchdog, proof-of-fix, kernel |
| 2 | **Acceptance probes** (schema v2, env-aware, read-only). Proving checks the contract's criteria | proof-of-fix, conductor |
| 3 | **ship-to-prod.** Up-to-date, sha-bound merge, deployment watch, production verification, revert | ship-to-prod (new), kernel |
| 4 | **Supervisor.** A need survives the death of its session | conductor, claude-remote-spawn |

## Decisions

Signed off 2026-09-26: **D1** need detection by the model on a nudge, no regex classifier; **D2**
proceed on recorded assumptions, escalate only on a blocking unknown; **D3** acceptance probes live in
proof-of-fix; **D4** ship-to-prod off by default, per repo, squash; **D5** a push notification is the
only interruption.

Defaults taken in revisions 3 and 7 (veto welcome): **D6** reverts are opened automatically and merged
by a human; **D7** only read-only, env-aware probes may run against production; **D8** the conductor
never advances past a human prompt it has not classified, so a missed halt cannot become one more step.

## Claude Code mechanics the plugins rely on

| Need | Mechanism | Fact |
|---|---|---|
| Start a need without the user typing a skill | UserPromptSubmit captures the prompt and injects the contract step; the model opens the need | F2, F4 |
| Advance a need | the conductor's single Stop decision; a loop without progress trips its own breaker before Claude Code's cap | F1, F5 |
| Survive a compaction, a `/clear` or a resume; keep a fork or another session from stealing the drive | `SessionStart` re-binds on `compact`/`clear` and on the bound session's `resume`; others get a notice | F6 |
| Wait on CI, a deployment, the gate or probes | a model-launched background task, or an `asyncRewake` hook | F8 |
| Skills calling skills | an instruction that names the skill; the skill's driven-mode section limits it to judgment | F4 |
| A sibling plugin missing | impossible for the four core siblings (declared `dependencies`); a disabled one fails the contract at `open` | F7 |

## Review log

Each revision was scored by a fresh-eyes merge-review subagent that had not seen the discussion.

| Revision | Score | Findings raised | Addressed in |
|---|---|---|---|
| 1 | 0/100 | one voice limited to Stop; watcher launch as a script step; forward-only state machine; invariant contradicting undriven behaviour; raw cross-plugin writes; ship-to-prod policy and state in one file; needs keyed on the session; Stop budget stalls; production probe replay; ledger concurrency and GC | 2 and 3 |
| 2 | 0/100 | skill bodies as a channel; handoff stamps still raw writes; fork stealing the drive; block budget both continuation and breaker; a missing sibling skipping a safety stage; no end state with merging disabled; no producer for gate evidence; no way to halt; the move to `blocked` racing the parallel Stop hooks; the merged-sha claim under squash and base drift; unconstrained production probes | 3 |
| 3 | 25/100 | a blocked need releasing its branch to self-engaging siblings; a successor after `/clear` or a fresh start silenced by a dead binding; F7 wrong (plugin `dependencies` exist) | 4 |
| 4 | 75/100 | F5 misread (the cap counts consecutive blocks, reset by any tool call) | 5 |
| 5 | 75/100 | `abandon` handing the branch back to AUTO siblings that would still review, push and ship the abandoned work | 6 |
| 6 | 75/100 | "waiting" keyed on any background task, so an unrelated dev server could stall a need or disable the breaker | 7 |

Revision 3 also adopted `asyncRewake` as a candidate re-entry, `fcntl.flock` instead of a stale-lock
timeout, archived closed needs, `score ≥ threshold` in the review record, `--auto-merge=false` and
envelope detection in the kernel. Revision 4 bound background evidence to the tree it ran on and the
review to its sha, updated drifted branches forge-side, relied on the forge's up-to-date rule, marked
drafts ready, declared `ci: none` at `open`, gave each new need its own branch and keyed proving by need.
Revision 5 replaced the per-turn budget with a no-progress breaker, recognised the `/clear` successor by
process, deferred exits to any session's next prompt, completed the in-flight classification (halt,
resume, abandon, amendment, new need), added ship-when-done's owner subcommands and the per-session scope
stamp, and placed ship-to-prod's base-drift handling and policy.
Revision 6 keeps an abandoned need's branch held until it is deleted or released, and adopted pass 5's
factual corrections: F2's `source` field, the `stop_hook_active` caveat, identity stamps written by
hooks, `review_gate_pending` in `ship.py push`, the verdict file mr-watchdog must now write, marker
consumption by `open-pr`/`mark-ready`, `sync` and `clear-done` owner subcommands, `deploy: command`
evidence, the `neither` class for questions during a need, follow-ups on a `ready` need, and `open`
creating the need's branch.
Revision 7 keys waiting on the need's own background step with a scheduled wake-up, and adopted pass
6's suggestions: archival only when no branch is held, need branches named by need id, D8 (no step past
an unclassified human prompt), repros exempt from the session GC, a corrupt ledger failing closed,
base drift scoped to merging repos, `CLAUDE_PID` for identity, `open` checking that every stage can
run, the `source` mapping, the queue after an abandon, and the abandon-hold tests.
