# Contributing

Thanks for looking under the hood. This repo has a small, strict set of rules — they are what keep ten
dependency-free plugins shippable by one person. Read [docs/architecture.md](docs/architecture.md) for
how the pieces fit; this file is the workflow.

## Prerequisites

- **Python 3** (standard library only — no `pip install`, ever) and **bash** and **git**.
- A forge CLI is optional: `gh` (GitHub) or `glab` (GitLab), used when present.
- The E2E lane additionally needs `gh` authenticated against the sandbox forge.

No build step, no package manager. Clone and run the gate.

## The quality gate

```bash
bash scripts/run-tests.sh
```

Every hermetic suite is discovered automatically and must be green before any commit lands. During
development, `--impacted` runs only the suites your change touches (CI always runs the full gate):

```bash
bash scripts/run-tests.sh --impacted
```

CI additionally enforces two sync invariants — run them locally before pushing:

```bash
python3 scripts/readme.py --check        # the README plugin table matches marketplace.json
python3 scripts/kernel-sync.py --check   # every vendored _kernel.py matches lib/_kernel.py
```

## The incident rule (strongly enforced)

A defect found in real usage is fixed **evidence-first**, using the `proof-of-fix` protocol:

1. **Reproduce before touching code.** Write the smallest probe that fails because of the bug and
   record it — it is accepted only if it fails:
   ```bash
   python3 plugins/proof-of-fix/skills/proof-of-fix/scripts/repro.py record --cmd '<probe>'
   ```
2. **Fix the root cause** — never the symptom, never a weakened probe.
3. **Prove it with the same probe**, and land the repro as a **permanent test** in the owning suite
   (or `tests/harness/run.sh` when it crosses plugins):
   ```bash
   python3 plugins/proof-of-fix/skills/proof-of-fix/scripts/repro.py check
   ```

No fix merges without its incident test. The commit message tells the incident honestly: what was
seen, the real root cause, how the repro proves it.

**Symptom vs root cause — the tell:** a fix that adds *tolerance* (a timeout, a retry, a debounce, a
wider threshold) treats a symptom — it makes the bug improbable by timing. A root-cause fix adds an
*invariant* — it makes the bug impossible by construction. If the fix could still lose a race, the root
cause is still out there.

## Changing a plugin

A plugin lives entirely under `plugins/<name>/` (see the anatomy in
[docs/architecture.md §3](docs/architecture.md)). When you change one:

- Put logic in `skills/<name>/scripts/`, not in hooks — hooks stay thin and shell out.
- Update its `web.json` (the storefront copy) if behaviour or capabilities changed.
- **Bump the version in lockstep** — `plugins/<name>/.claude-plugin/plugin.json` **and**
  `.claude-plugin/marketplace.json` must agree. Then regenerate the README table:
  ```bash
  python3 scripts/readme.py        # never hand-edit the table between the <!-- plugins --> markers
  ```
- Use [semantic versioning](https://semver.org): a behaviour-breaking change is a **major** bump.

## Touching the shared kernel

The harness plugins vendor a byte-identical copy of [`lib/_kernel.py`](lib/_kernel.py). **Edit the
source, never a copy**, then re-vendor:

```bash
python3 scripts/kernel-sync.py        # copies lib/_kernel.py into every plugin's scripts/_kernel.py
```

`scripts/kernel-sync.py --check` (CI + the harness suite) fails on any drift.

## Commits & pull requests

- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`; `!` for a
  breaking change).
- **Never commit to `main`** — branch, open a PR, squash-merge with the PR title set before merging.
- **No AI attribution** in commit messages or PR descriptions.
- Prefer `git add <path>` over `git add .`.

## The self-hosted delivery

This repository ships through its own harness. The intended loop for a change is:

```
proof-of-fix record  →  fix the root cause  →  green gate  →  ship-when-done mark-done
  →  merge-review (adversarial re-read, verify, record the pass for the exact HEAD)
  →  push + draft PR  →  mr-watchdog watches CI  →  on green: ready + squash-merge
```

You don't have to drive it by hand — that's the point of the harness — but every PR is expected to
clear the same gates it would enforce on anyone else's.

## The E2E lane

Run it deliberately — before a release, or after any change to the harness plugins:

```bash
bash tests/e2e/run.sh --coverage      # what's proven / missing / stale
bash tests/e2e/run.sh --fill          # re-prove the stale or never-proven situations
```

It talks to a real forge and takes minutes, so it is **excluded** from the CI gate. See
[docs/architecture.md §7](docs/architecture.md).
