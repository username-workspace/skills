# skills — marketplace engineering rules

Claude Code plugin marketplace (stdlib-only Python + bash + git). Each plugin under `plugins/<name>/`
ships `.claude-plugin/plugin.json`, `web.json`, optional `hooks/`, `skills/<name>/SKILL.md`, and a
hermetic test suite under `tests/` (`run.sh` / `integration.sh`).

> Full reference: [docs/architecture.md](docs/architecture.md). Contributor workflow:
> [CONTRIBUTING.md](CONTRIBUTING.md). This file is the binding rule set, kept tight on purpose.

## Quality gate

`bash scripts/run-tests.sh` — every hermetic suite, discovered automatically, must be green. Suites
must stay hermetic: throwaway repos, stubbed forge CLIs, shared assertions sourced from `tests/lib.sh`,
and **every hook invocation pins `CLAUDE_PLUGIN_ROOT`** (the gate itself runs inside a Stop hook where
it points elsewhere). CI also enforces two sync invariants: `scripts/readme.py --check` (the README
table matches `marketplace.json`) and `scripts/kernel-sync.py --check` (the vendored kernel, below).

## The shared kernel (single source, drift-proof)

The harness plugins share their plumbing through `lib/_kernel.py`, vendored **byte-identical** into each
plugin's `scripts/_kernel.py` by `scripts/kernel-sync.py` (so installed plugins stay self-contained).
**Edit `lib/_kernel.py`, never a vendored copy**, then re-run `kernel-sync.py`; `--check` fails on drift
(CI + `tests/harness/run.sh`). The kernel is stateless — each plugin names its own `.git/` state files
in thin wrappers, so two plugins loaded in one process never cross state.

## Engagement modes

`HARNESS_AUTO_ENGAGE` (read at call time) selects how a plugin decides to act. **Explicit is the
default**: act only on a declared signal (ship-when-done's `mark-done` marker, branch-scoped strict;
the merge-review pre-push gate; ship's handoff stamp for mr-watchdog) — no declaration → no action.
`HARNESS_AUTO_ENGAGE=1` restores inferred engagement (baseline deltas, edit provenance, upstream
advance). Both fail closed: any uncertainty resolves to *not engaged*.

## The incident rule (strongly enforced)

A defect found in real usage is fixed **evidence-first**, with the proof-of-fix protocol:

1. Reproduce it deterministically *before* touching code — the smallest failing probe, recorded
   (`proof-of-fix record`, accepted only if it fails).
2. Fix the root cause — never the symptom, never a weakened probe.
3. Prove it with the same probe (`proof-of-fix check`), and land the repro as a **permanent test** in
   the owning suite (or `tests/harness/run.sh` when it crosses plugins).

No fix merges without its incident test. The commit message tells the incident honestly: what was
seen, the real root cause, how the repro proves the fix.

**Symptom vs root cause — the tell:** a fix that adds *tolerance* (a timeout, a retry, a debounce, a
wider threshold) treats a symptom — it makes the bug improbable by timing. A root-cause fix adds an
*invariant* — it makes the bug impossible by construction (only a green gate verdict is ever cached; a
CI verdict belongs to the exact sha being watched). If the fix could still lose a race, the root cause
is still out there; and it usually costs nothing, where tolerance always costs latency or noise.

## Real-usage validation (the hermetic suites cannot cover this)

Hermetic tests idealize composition, environment, time, and state evolution. Two complements:

- **Observability first** — hooks persist evidence for their silent paths (e.g. every gate run writes
  verdict + output tail + duration to `.git/swd-gate.json`). A red seen only in a hook must be
  diagnosable from a file, never from speculation.
- **The E2E lane** — `bash tests/e2e/run.sh` replays seeded generated scenarios (flow × gate × CI ×
  project archetypes), human-divergence twists (`--twists`: dirty start, wip/, amend-mid-watch, MR
  closed, manual push, failing review loop), and the explicit-default set (`--explicit`) against the
  real sandbox forge `username-workspace/harness-e2e` (plan-steered CI): real pushes, PRs, checks and
  registration windows. Self-healing: stale `e2e/*` branches/PRs are garbage-collected, each failure is
  retried once to classify flake vs defect, and persistent failures file a labelled issue on this repo
  with the reproduction command. Run it deliberately (release, harness change) — excluded from CI.
- **The coverage ledger** — every passing situation is recorded in `tests/e2e/coverage.json` with the
  harness commit it was proven against; `--coverage` prints what is proven, missing, or **stale**
  (proven against an older harness), and `--fill` re-proves the stale/missing. "The harness works in
  situation X" is a claim this file backs or exposes — campaigns target the holes, never the repetitions.

## Conventions

- Conventional Commits; never commit to `main` (branch + PR); no AI attribution.
- Versions bump together: `plugins/<name>/.claude-plugin/plugin.json` **and**
  `.claude-plugin/marketplace.json`.
- Shell-command config fields (`gate`, `judge_command`, …) are honored only from `.git/` or
  `--config` — never from cloneable working-tree files.
- Plugin state lives in `.git/<plugin>-*.json` (never committed); sibling coupling goes through those
  files and degrades to inert when the sibling is absent.
