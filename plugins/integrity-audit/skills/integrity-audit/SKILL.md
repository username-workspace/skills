---
name: integrity-audit
description: Audit a repository against its OWN declared constitution — invariants (CLAUDE.md/AGENTS.md), decision records (ADRs), contracts (schemas), executable guards (CI tests, hooks) — to detect drift and, on demand, remediate it at the root cause with a derived guard so the class cannot recur. Three modes — AUDIT (report), REMEDIATE (fix lot by lot), REALIGN (diff-scoped: check current work against the core design). Use when asked to audit integrity or code quality against the project's principles, find drift or violations of declared invariants, "recadrer" ongoing developments, verify a change respects the architecture, or run a hardening pass after an audit ticket. Horizontal: any language, any repo.
---

# Integrity Audit

> **Purpose**: hold a codebase to the standard it set for itself. The constitution is the repo's, not yours — every finding must cite it. No finding without a citation, no fix without a guard.

**The core loop:** discover the constitution → sweep for drift → counter-validate every candidate in source → report with citations → (on demand) fix at the root and ship the guard that makes the class impossible.

## Mode selection

| Mode | When | Output |
|---|---|---|
| **AUDIT** (default) | The user asks to audit, check, review integrity — or describes a doubt | Findings report, nothing touched |
| **REMEDIATE** | The user asks to fix (or approves the report's lots) | Root-cause fixes, one commit per lot, gate green between lots |
| **REALIGN** | The user points at current work (a branch, a diff, "recadre ce dev") | The diff judged against the constitution: drift it introduces, guards it weakens |

State the detected mode in the first reply. Never remediate in AUDIT mode.

## Phase 0 — Constitution discovery

Locate what the project declares about itself, in priority order:

1. **Instructions**: `CLAUDE.md` (root + nested), `AGENTS.md`, `.cursorrules` — look for numbered invariants, "non-negotiable", "never/always" clauses, declared conventions (error handling, timeout policy, "derive don't duplicate"…).
2. **Decisions**: `docs/adr/`, `ADR*.md`, `docs/architecture*`, RFCs — settled decisions are constitution; do not relitigate them, enforce them.
3. **Contracts**: `schemas/` (JSON Schema, OpenAPI, GraphQL SDL, protobuf), DB migrations — a contract that exists is a promise that it is enforced.
4. **Executable guards**: CI config, guard tests (tests that assert an invariant rather than a behavior), git hooks, lint rules — these show which invariants the project already enforces mechanically, and where the enforcement has holes.
5. **Quality gate**: the exact command(s) the project calls its gate (typecheck, tests, compile steps, chart lint). Record it — REMEDIATE runs it between lots.

Extract a numbered list: *invariant → source file citation*. This list is the audit's reference; carry it through every phase.

**No constitution found?** Say so plainly. Offer two paths: audit against the six universal drift classes only (below), and/or write the missing constitution first (a minimal invariants section in CLAUDE.md) — that is itself the first root-cause fix.

## Phase 1 — Drift sweep

Sweep the codebase against six universal drift classes. Detection heuristics, grep recipes, root-fix patterns and guard patterns for each class live in [references/drift-classes.md](references/drift-classes.md) — read it before sweeping.

1. **Enforcement drift** — a declared sole control point with a second path around it; permissions computed broader than declared (union where the narrowest grant is required); service endpoints without authentication; annotation-only enforcement (a `readOnly` hint that removes nothing); capability grants with no matching policy.
2. **Deployment-value drift** — silent fallbacks (`?? 'value'`) carrying deployment identity (tenant, region, account, business constants) in platform code: a fresh deployment silently impersonates deployment #1. Config that exists but is not wired makes the fallback the nominal path.
3. **Contract drift** — a schema nothing loads; a hand-rolled normalizer that accepts unknown keys (a misspelled key degrades into a silent catch-all); vendored copies without a drift test; derived lists maintained by hand.
4. **Robustness drift** — I/O without timeout; an operation outside the fail-closed envelope (state armed, then an unguarded await before persistence → silent loss); unbounded queries or responses.
5. **Duplication drift** — the same helper reimplemented across packages instead of the shared kit; constant sets copied rather than derived.
6. **Hygiene drift** — dead kinds/types/schemas with zero entries and zero consumers; phantom dependencies; the test runner scanning stale directories (fake green on stale code); frozen dependencies with known CVEs parsing user input.

Severity is set by the constitution, not by the class: **critical** = breaks a declared invariant with an authorization/security consequence · **major** = breaks an invariant or convention with a reliability/multi-deployment consequence · **minor** = hygiene.

## Phase 2 — Counter-validation

Adversarially re-verify every candidate **in source, line by line**, before it is reported:

- Open the file; confirm the behavior is what the sweep claims (not already narrowed elsewhere, not dead code).
- Check compensating controls — then check what the constitution demands. A network policy does not discharge a declared app-layer authentication requirement; defense-in-depth findings stand when the declared layer is missing.
- Check the tests: is the drift actually pinned by a passing test (i.e. intentional)? If so it is a constitution conflict to surface, not a silent drift.
- Discard anything unconfirmed or not backed by a citation. Report the discard count — it is evidence of rigor, not waste.

A confirmed finding carries exactly: `{severity, class, file:line, invariant cited, drift, consequence, root fix, derived guard}`.

## Phase 3 — Verdict

```
## Constitution — <n> invariants (sources: …)
## Findings — <k> confirmed (<d> candidates discarded in counter-validation)

[CRITICAL] enforcement — packages/x/compile.ts:216
  Violates: invariant #2 "deny-by-default; grants are derived" (CLAUDE.md)
  Drift: policy tiers come from the resource alone, never intersected with the caller's
  Consequence: a narrow caller compiles a policy admitting broader tokens
  Root fix: derive the narrowest grant (intersection; hard error if empty)
  Guard: compile test — narrow×wide compiles narrow; empty intersection throws

## Lots — remediation proposal (severity order)
Lot 1 (critical) … · Lot 2 (major) … · Lot 3 (minor) …
Each lot: scope, gate to run, QA criteria — flag what can only be validated live.
```

AUDIT and REALIGN stop here.

## Phase 4 — Remediation doctrine (REMEDIATE only)

- **Root cause only.** If one symptom requires touching many files, the root cause is elsewhere — find it. A fix that adds tolerance (retry, wider threshold) treats a symptom; a root fix adds an invariant.
- **Every fixed class ships its guard**, derived from the source of truth (registry, config, schema) — never a hand-maintained list. The guard's allowlist may only shrink. Integrity must be *enforced*, not documented.
- **Reuse the platform's own patterns.** An existing authorizer, env helper, response kit: move it to a shared home and rally callers — do not reinvent a parallel one.
- **Respect immutables.** Applied migrations are frozen: fix forward with a new version. Watch self-applying protections (e.g. row-security forced on the owner) that would silently no-op the data fix — lift them inside the migration's transaction, restore them after.
- **One lot = one commit**, ordered by severity; run the project's own gate between lots; a single PR/MR per subject. Verify the full gate on the final tree (including a frozen-lockfile install if the ecosystem has one).
- **Truthful QA.** Map every acceptance criterion to a test or mark it *live-only*; never fake a green.

## REALIGN specifics

Constitution discovery is identical; the sweep runs **only on the diff** (`git diff <base>...HEAD` + new files). Two extra questions per hunk: does this change *introduce* one of the six drifts, and does it *weaken* an existing guard (deleted/loosened test, widened allowlist, new bypass)? Weakening a guard is always at least major.
