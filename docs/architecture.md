# Architecture

How this marketplace is built — the conventions every plugin follows, the shared kernel they vendor,
the `.git/`-local state they couple through, and the test architecture that holds it together.

For the contributor workflow (gate, incident rule, adding a plugin) see
[CONTRIBUTING.md](../CONTRIBUTING.md). For per-plugin behaviour, read each plugin's `SKILL.md`.

---

## 1. What this repository is

A [Claude Code](https://code.claude.com) plugin marketplace. Every plugin is **stdlib-only Python 3 +
bash + git** — no third-party runtime dependencies, so a plugin runs anywhere `python3` and `git` do.
The plugins are independent and individually useful; four of them also **compose** into a delivery
pipeline (§5).

Hard constraints that shape everything below:

- **No dependencies.** The Python standard library, `bash`, and `git`. A forge CLI (`gh`/`glab`) is
  used when present and degraded around when absent.
- **Hermetic tests.** Every suite runs against throwaway repos with stubbed forge CLIs (§7).
- **`.git/`-local state.** Plugin state never enters a commit; it lives under `.git/` (§4).

---

## 2. Repository layout

```
.
├── .claude-plugin/marketplace.json   # the marketplace manifest (name, plugins, versions, categories)
├── README.md                          # front door; the plugin table is generated, not hand-edited
├── CLAUDE.md                          # engineering rules loaded into an agent's context
├── CONTRIBUTING.md                    # the contributor workflow
├── LICENSE                            # MIT
├── docs/
│   ├── README.md                      # docs index
│   ├── architecture.md                # this file
│   └── plans/                         # implementation plans (archived once shipped)
├── lib/
│   └── _kernel.py                     # SINGLE SOURCE of the shared plumbing (§3)
├── scripts/
│   ├── run-tests.sh                   # the quality gate: discovers and runs every hermetic suite
│   ├── kernel-sync.py                 # vendors lib/_kernel.py into each plugin; --check fails on drift
│   ├── readme.py                      # regenerates the README plugin table; --check fails on drift
│   ├── readme-hook.py                 # PostToolUse hook: regenerate the table when the catalogue changes
│   └── impacted.py                    # maps changed paths → the plugin suites to run (--impacted)
├── tests/
│   ├── lib.sh                         # shared bash assertion helpers, sourced by every suite
│   ├── harness/run.sh                 # cross-plugin composition suite
│   ├── turns/run.sh                   # turn-boundary regression suite (real hook wire-format)
│   └── e2e/                           # generative real-forge lane + coverage ledger (§7)
└── plugins/
    └── <name>/                        # one directory per plugin (§3)
```

---

## 3. Plugin anatomy & the vendored kernel

### A plugin's files

```
plugins/<name>/
├── .claude-plugin/plugin.json         # name, version, description, homepage, license
├── web.json                           # storefront copy: category, tagline, summary, capabilities…
├── hooks/                             # OPTIONAL — Claude Code hook wiring + thin hook scripts
│   ├── hooks.json                     #   declares which events fire which scripts
│   └── *-hook.py                      #   plumbing only: parse the event, shell out to the skill script
└── skills/<name>/
    ├── SKILL.md                       # the plugin's behaviour, in the model's context
    └── scripts/
        ├── <name>.py                  # the skill's logic (the testable core)
        └── _kernel.py                 # a vendored copy of lib/_kernel.py (§3.2)
```

Hooks stay thin: a `hooks/*.py` script parses the event payload and shells out to the skill script.
All real logic lives in `skills/<name>/scripts/`, where it is unit-testable without a live hook.

### 3.2 The vendored kernel — one source, drift-proof by construction

Four of the harness plugins share the same plumbing: a `run()` git wrapper, active-repo resolution,
session/state file I/O, fake-green detection, the engagement-mode switch, and the cross-plugin marker
protocol. That code lives **once**, in [`lib/_kernel.py`](../lib/_kernel.py).

It is **vendored byte-identical** into each consuming plugin's `scripts/_kernel.py` by
[`scripts/kernel-sync.py`](../scripts/kernel-sync.py), so an installed plugin stays self-contained — it
carries its own copy and depends on nothing outside its directory.

The copies cannot silently diverge:

- `python3 scripts/kernel-sync.py` re-vendors after any edit to `lib/_kernel.py`.
- `python3 scripts/kernel-sync.py --check` fails on any drift. It is wired into **CI** and into the
  cross-plugin test suite (`tests/harness/run.sh`), and globs *every* `plugins/*/skills/*/scripts/_kernel.py`
  — a hand-added copy outside the known list cannot escape the check.

> **Rule:** edit `lib/_kernel.py`, never a vendored copy. The header of each copy says so.

The kernel is **stateless on purpose**: it never holds plugin identity. Each plugin names its own
`.git/` state files in three-line wrappers around the kernel's generic readers, so a process that
loads two plugins can never cross their state through a shared module global.

---

## 4. State & sibling coupling

Plugin state is **never committed**. It lives under `.git/` (which no clone carries), written
atomically (temp file + `os.replace`), and read back as an empty default when absent or corrupt — a
plugin degrades to inert rather than crash.

| File (`.git/`) | Owner | Holds |
|---|---|---|
| `swd-session.json` | ship-when-done | per-session, per-branch baselines (versioned multi-session map, GC'd after 7 days) |
| `swd-provenance.json` | ship-when-done | paths this session observably edited (PostToolUse events) |
| `swd-claims.json` | ship-when-done | paths a live background writer has claimed (kept out of commits) |
| `swd-done.json` | ship-when-done | the `mark-done` delivery declaration (the explicit-mode signal) |
| `swd-gate.json` | ship-when-done | the last gate run's verdict + output tail + duration (observability) |
| `swd-handoff.json` | ship-when-done | per sibling, the last `handoff` it refused (a version too old), cleared by its next success |
| `swd-pr.json` | ship-when-done | the PR/MR a need's `open-pr` opened, per branch, and whether it was marked ready |
| `swd-review-block.json`, `swd-url.json` | ship-when-done | once-per-state nudge / surfaced-URL dedup |
| `merge-review-session.json` | merge-review | session baselines (engagement) |
| `merge-review-state.json` | merge-review | the per-pass review record (score, findings, HEAD) |
| `merge-review-gate.json` | merge-review | the pre-push gate's once-per-HEAD block dedup |
| `mr-watchdog-session.json` | mr-watchdog | session baselines (engagement) |
| `mr-watchdog-watch.json` | mr-watchdog | per-HEAD watch dedup |
| `mr-watchdog-verdict.json` | mr-watchdog | the watcher's last verdict (green, red + log, stopped + reason), bound to the sha it watched |
| `proof-of-fix.json` | proof-of-fix | each session's active repro (command + recorded red verdict), and each need's probes by criterion (red work state, pinned files, waivers, checks) |
| `conductor.json` | delivery-conductor | the need ledger: which branches a need holds (read by every sibling through `driven()`) |

This lists the coupling and observability state. Per-session nudge-dedup markers (e.g.
`proof-of-fix-nudge.json`) and the trusted config files (`.git/<plugin>.json`, §8) live under `.git/`
too but are not coupling state.

**Sibling coupling** goes *through* these files, and degrades to inert when the sibling is absent:

- ship-when-done **holds a push** while a `merge-review` gate is pending (it reads merge-review's
  session presence); once a passing review is recorded, the next Stop pushes and opens the PR.
- ship-when-done **hands the watcher off** to mr-watchdog by stamping its session file when it pushes;
  mr-watchdog engages on that stamp.
- merge-review and ship-when-done **read each other's provenance** for engagement (§6).

No sibling is a hard dependency — install any one alone and it simply skips the coupled steps.

One stamp lives outside `.git/`: delivery-conductor's **liveness**, one file per session under
`~/.claude/harness-live/` (`HARNESS_LIVE_DIR` overrides it; entries older than 7 days are collected).
It is keyed by session alone because a session launched outside the conductor's scope may have no repo
yet when its prompt starts.

---

## 5. The delivery harness

Four plugins compose into a pipeline. Each is useful alone; together they cover commit → review →
push → CI-watch, with evidence-first bug fixing as the inner loop.

```
proof-of-fix   ── evidence-first inner loop: a recorded probe that fails before a fix, passes after
                   │
ship-when-done ── commits each milestone; opens the draft PR only when the work is provably done
                   │  (declaration + green gate)         ── holds the push ──►
merge-review   ── adversarial 0–100 review; the pre-push gate blocks an unreviewed HEAD ──►
                   │  (a passing record clears the gate)
mr-watchdog    ── watches the PR's CI in the background; brings the verdict back into the session
```

The pipeline is **loosely coupled through `.git/` state** (§4), so the composition is emergent, not
wired — each plugin only knows how to read a sibling's presence file.

This repository **ships through its own harness** (dogfooding): every change is delivered by the same
probe → fix → gate → mark-done → review → push → PR → watch → merge loop it provides.

---

### One voice while driven

When delivery-conductor drives a need (see the
[autonomous-delivery plan](plans/2026-09-26-autonomous-delivery.md)), the need's branch is **held**:
the conductor is the only plugin that instructs the session there. Every sibling asks the kernel's
`driven(repo, session, prompt_id)` on each hook channel it owns and stands down while it is true:
ship-when-done, mr-watchdog and proof-of-fix stay silent at the Stop, proof-of-fix's bug nudge gives
way to the conductor's contract step, and merge-review's pre-push deny points back to the conductor.
The two other channels a driven session hears, background-task output and the bodies of the skills
it invokes, are brought under the same rule by the stage protocol and the conductor itself.

`driven()` is true only while the conductor **runs for this very prompt**: each of its hooks refreshes
the session's liveness stamp with the `prompt_id` Claude Code passes to every UserPromptSubmit and Stop
(unchanged through a blocked Stop's continuation). A conductor that stops running, through
`/reload-plugins` or an uninstall, stops refreshing it, so the ledger it leaves behind is inert and the
siblings re-engage by the next prompt. A UserPromptSubmit caller runs in parallel with the conductor's
own hook, so it also accepts the previous prompt's stamp, read from the transcript's `promptId`
entries. Under a running conductor, a corrupt ledger holds every branch (fail closed).

### The stage protocol

Each harness plugin answers `stage --repo R --need N` read-only, as a versioned report (`"v": 1`, built
by the kernel's `stage_report`):

```json
{"v": 1, "stage": "gating", "state": "pending",
 "evidence": {"sha": "…", "verdict": null, "file": ".git/swd-gate.json"},
 "next": {"kind": "background", "run": ["python3", ".../ship.py", "gate", "--need", "N", "--repo", "R"]}}
```

`state` is `done`, `pending` or `blocked`; `next.kind` is `none`, `script` (a short deterministic step the
conductor runs itself), `background` (launched by the model with `run_in_background`, the need token
first so it can be matched in the Stop input's `background_tasks`) or `skill` (a judgment step, described
by `instruction`). Every answer reads local evidence bound to the exact work state or sha it was produced
on, so a new HEAD sends the need back to the earliest stale stage by construction:

| Stage | Owner | Done when |
|---|---|---|
| implementing | ship-when-done | the work is committed and the branch is ahead of its base |
| gating | ship-when-done | `gate` passed at this work state, the tree unchanged while it ran |
| proving | proof-of-fix | every probe of the need (its criteria's, and the repros its sessions recorded) passed at this work state |
| reviewing | merge-review | a record for the exact HEAD, score at or above the threshold |
| shipping | ship-when-done | declared (`mark-done`), pushed at HEAD, PR/MR open |
| ci | mr-watchdog | the watcher's verdict for the exact HEAD is green |
| ready | ship-when-done | the draft PR/MR is marked ready for review |

Every cross-plugin write goes through the owner's CLI: ship-when-done hands engagement over with
`review.py handoff` and `watch.py handoff`. Each owner stamps its script path in its `.git/` state for
discovery, and a repo that opts an owner out hears it from that owner's `stage` (`"enabled": false`),
or finds no stamp at all (merge-review and mr-watchdog stamp nothing while disabled): both refuse the
need. The harness plugins update together; a sibling too old for `handoff` leaves the refusal in
`.git/swd-handoff.json`. merge-review's presence and its push hold are separate: its session
file exists whenever it is enabled, and only its `prepush_gate` flag arms ship-when-done's hold.

### The conductor

`delivery-conductor` owns no stage. A need opens on its own branch, cut from the base its owners
measure against (the default branch of the remote a branch with no upstream ships to, as last fetched;
`conductor.py open`: the prompt the hook captured for that turn, a summary and criteria; one need per
worktree), and lives in
`.git/conductor.json` while that branch is driven. At every Stop
the conductor asks the owners' `stage` CLIs, in the order of the table above, and acts on the first
stage that is not done: a `script` step runs inside the hook (several can chain within its time
budget), a `background` step comes back as a command to launch, and while a task carrying the need
token runs (`--need <id>` in a shell command, `need:<id>` in a subagent's description, such as the
reviewer's) the conductor waits instead of asking again; a `skill` step is the model's judgment step.
Every human prompt during a need is classified (`halt`, `resume`, `abandon`, `amend`, `note`) before
the need advances; compaction and `/clear` re-bind the need to the same Claude process (`CLAUDE_PID`).

A need is blocked, and the user told once, on the same blocking decision three times with no change in
work state, on a stage failing too many times in a row (three reviews, six otherwise; the stage being
done resets it), or past eight hours of driven time (`resume` restarts the clock). A blocked or
abandoned need keeps its branch held (driven) until `resume` or `release`; `release` and `ready` hold
the branch through the rest of the deciding prompt only (`need_holds()`, whatever the session's scope),
so no sibling speaks in that turn. The ledger then keeps the need whole in its history: a follow-up on a
`ready` need (review comments, a change to its PR/MR) reopens it on its branch (`conductor.py reopen`).

## 6. Engagement modes

"Engagement" answers one question: *should this plugin act on the current branch right now?* There are
two modes, switched by the `HARNESS_AUTO_ENGAGE` environment variable (read at call time, in
`_kernel.auto_engage(repo)`, scoped as below).

### Explicit — the default

Fully deterministic. A plugin acts **only on a declared signal**:

- **ship-when-done** acts only when a `mark-done` marker was declared for the current branch (strict
  branch match — a corrupt or branch-less marker is inert, and `mark-done` refuses a detached HEAD).
- **merge-review**'s pre-push gate arms only while a declared delivery is in flight (ship's marker).
- **mr-watchdog** engages only via ship-when-done's handoff stamp.

No declaration → no action, ever. The recording hooks (baselines, provenance) still run — they are the
presence files siblings couple on — but they decide nothing.

### Auto — `HARNESS_AUTO_ENGAGE=1`

Engagement is **inferred** from observed session work: HEAD or the tree advanced since the turn-start
baseline, or the branch carries paths this session observably edited (PostToolUse provenance), or the
branch's upstream advanced. The inference rules are the pre-2.0 behaviour; what is new is the scope below.

Auto is **scoped** — outside the scope a plugin falls back to explicit (a declaration still works):

- a session launched outside a git work tree (`CLAUDE_PROJECT_DIR`, e.g. `$HOME`) has no project to
  infer from — it may touch many repos, none of which it was started for;
- `HARNESS_AUTO_ENGAGE_EXCLUDE` (paths separated by `os.pathsep`) lists trees that carry their own
  delivery harness: a repo under one, or a session launched under one, stays explicit. Entries are
  matched by filesystem identity (case and symlinks included); an entry that is not absolute after
  `~`/`$VAR` expansion cannot be honoured and turns auto off everywhere (fail closed).

This makes auto a safe user-wide default: set both variables once in `~/.claude/settings.json`
(`env`) and every new side project engages on its own, while the excluded trees and ad-hoc sessions
do not.

> The failure direction is **fail-closed**: an unrecognised `HARNESS_AUTO_ENGAGE` value, a missing
> baseline, or a corrupt state file all resolve to *not engaged*. The harness never acts on a branch
> it is unsure about.

**Worktrees.** Hooks act on the repository of the session's cwd (or of the repo a push command
names), so a session works on a linked worktree by working from inside it, as `EnterWorktree` does;
the worktree then reads the repository's trusted `.git/` config. In a submodule workspace (the cwd's
repo has a `.gitmodules`) the last edited file's repo wins when it is nested under the cwd, so a
nested worktree edited by absolute path is found there. Elsewhere such a session is attributed to the
main checkout: extending that rule to every repo would parse the transcript at every hook of every
repo.

---

## 7. Test architecture

### The hermetic gate

`bash scripts/run-tests.sh` discovers and runs **every** suite (`tests/run.sh` / `integration.sh`
under each plugin, plus the cross-plugin suites). It is the CI gate and must be green before any
commit lands. Suites are hermetic: throwaway repos, stubbed `gh`/`glab`, and **every hook invocation
pins `CLAUDE_PLUGIN_ROOT`** (the gate itself runs inside a Stop hook, where that variable points
elsewhere). Shared bash assertions live once in [`tests/lib.sh`](../tests/lib.sh), sourced by each
suite.

`scripts/run-tests.sh --impacted [base]` runs only the suites of plugins touched since `base` (plus the
cross-plugin suite); any changed path outside a single plugin, or any doubt, falls back to the full
run. CI always runs the full gate.

Two cross-plugin suites cover what per-plugin tests can't:

- **`tests/harness/run.sh`** — the composition contract: a single-shot delivery is reviewed, watched,
  and shipped; the gate runs once per work-state; block-continuations advance the pipeline without a
  human prompt; the vendored kernel is in sync; both engagement modes behave.
- **`tests/turns/run.sh`** — the turn-boundary class, replayed at the real hook wire-format. This is
  the regression test for the incidents that motivated the structural hardening.

### The E2E lane (excluded from CI)

`bash tests/e2e/run.sh` replays generated full deliveries against a **real sandbox forge**
(`username-workspace/harness-e2e` on github.com, and its gitlab.com twin with `--forge gitlab`;
plan-steered CI): real pushes, PRs, checks, and registration
windows — the things hermetic tests idealise away (composition, environment, time, state evolution).

It is **self-healing**: stale `e2e/*` branches and PRs are garbage-collected, each failure is retried
once to classify flake vs defect, and a persistent failure files a labelled issue carrying the exact
reproduction command.

The **coverage ledger** (`tests/e2e/coverage.json`) records every proven situation with the harness
commit it was proven against. `--coverage` prints what is proven, what is missing, and what is **stale**
(proven against an older harness); `--fill` re-proves exactly the stale/missing situations. A proof is
an assertion this file either backs or exposes — so "the harness works in situation X" never silently
expires.

Run the E2E lane deliberately: before a release or after a harness change.

---

## 8. Security model

- **Fail-closed engagement.** Every uncertain input (missing baseline, corrupt state, unknown mode
  value) resolves to *not engaged*. The harness under-acts rather than acts wrongly.
- **No shell from cloneable files.** Shell-command config fields (`gate`, `judge_command`, …) and the
  gate-strictness knobs are honoured **only** from `.git/` (never cloned) or an explicit `--config` —
  never from the working-tree `.<plugin>.json` that arrives with any clone.
- **No implicit bare repository.** Every git call the kernel makes carries `-c safe.bareRepository=explicit`
  (git 2.38+), so a directory shaped like a bare repository inside a clone is never opened as a git dir:
  its HEAD, its git config and any `.git/`-style state in it are never read. `commit`, `push` and
  `checkout` are the exception: git hands `-c` on to the hooks they spawn, which are the user's, and they
  only run after guarded reads have found a real branch. With git 2.38 to 2.44 the same
  guard also refuses a path inside a normal repo's `.git/`; the harness never works from there.
- **Read-only watchers.** mr-watchdog never commits, pushes, or merges, and runs no model itself.
- **Branch-first, never the trunk.** ship-when-done never commits or pushes the default branch, and
  never merges; the human merges the PR it opens.
