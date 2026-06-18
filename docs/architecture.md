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
| `swd-review-block.json`, `swd-url.json` | ship-when-done | once-per-state nudge / surfaced-URL dedup |
| `merge-review-session.json` | merge-review | session baselines (engagement) |
| `merge-review-state.json` | merge-review | the per-pass review record (score, findings, HEAD) |
| `merge-review-gate.json` | merge-review | the pre-push gate's once-per-HEAD block dedup |
| `mr-watchdog-session.json` | mr-watchdog | session baselines (engagement) |
| `mr-watchdog-watch.json` | mr-watchdog | per-HEAD watch dedup |
| `proof-of-fix.json` | proof-of-fix | the active repro (command + recorded red verdict) |

**Sibling coupling** goes *through* these files, and degrades to inert when the sibling is absent:

- ship-when-done **holds a push** while a `merge-review` gate is pending (it reads merge-review's
  session presence); once a passing review is recorded, the next Stop pushes and opens the PR.
- ship-when-done **hands the watcher off** to mr-watchdog by stamping its session file when it pushes;
  mr-watchdog engages on that stamp.
- merge-review and ship-when-done **read each other's provenance** for engagement (§6).

No sibling is a hard dependency — install any one alone and it simply skips the coupled steps.

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

## 6. Engagement modes

"Engagement" answers one question: *should this plugin act on the current branch right now?* There are
two modes, switched by the `HARNESS_AUTO_ENGAGE` environment variable (read at call time, in
`_kernel.auto_engage()`).

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
branch's upstream advanced. This is the previous (pre-2.0) behaviour, preserved verbatim.

> The failure direction is **fail-closed**: an unrecognised `HARNESS_AUTO_ENGAGE` value, a missing
> baseline, or a corrupt state file all resolve to *not engaged*. The harness never acts on a branch
> it is unsure about.

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
(`username-workspace/harness-e2e`, plan-steered CI): real pushes, PRs, checks, and registration
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
- **Read-only watchers.** mr-watchdog never commits, pushes, or merges, and runs no model itself.
- **Branch-first, never the trunk.** ship-when-done never commits or pushes the default branch, and
  never merges; the human merges the PR it opens.
