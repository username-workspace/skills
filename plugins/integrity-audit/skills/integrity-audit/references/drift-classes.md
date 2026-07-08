# The six drift classes — detection, root fix, derived guard

Contents: [1. Enforcement](#1-enforcement-drift) · [2. Deployment-value](#2-deployment-value-drift) · [3. Contract](#3-contract-drift) · [4. Robustness](#4-robustness-drift) · [5. Duplication](#5-duplication-drift) · [6. Hygiene](#6-hygiene-drift)

Grep recipes are starting points, not verdicts — every hit goes through counter-validation. Adapt patterns to the repo's language(s).

---

## 1. Enforcement drift

The project declares a control point ("sole gateway", "single PEP", "all writes go through X") or an authorization rule; the code enforces less.

**Shapes**
- A second path around the declared control point (a direct client, a debug endpoint, a sidecar that talks upstream itself).
- Permissions computed **broader than declared**: the policy takes the resource's allowed set alone where the rule demands the *intersection* with the caller's. Latent until a resource widens — then every narrow caller silently inherits the width.
- Service-to-service endpoints reading the body and acting with **no authentication** ("internal, netpol covers it"). If the constitution demands app-layer identity, network reachability is not authentication.
- **Annotation-only enforcement**: `readOnly`/`internal`/`deprecated` hints on tools/routes while the mutating capability stays registered and callable.
- **Capability without policy**: SQL `GRANT UPDATE, DELETE` with no matching row-security policy; IAM roles wider than any code path uses. Dormant capability waits for a permissive policy to weaponize it.

**Detect**
- Map every listener/route/tool registration → its auth check. `grep -rn "app.post\|app.get\|registerTool\|addRoute"` then demand the authorizer in each handler.
- Find where permissions/policies are *computed* (compilers, builders) and compare the formula to the declared rule. Look for `??`/`||` fallbacks and single-source sets where two sources must meet.
- `grep -rn "readOnlyHint\|readOnly\|annotations"` → prove the flag changes the surface, not just the metadata.
- Diff `GRANT` statements against the policy definitions in the same migrations.

**Root fix** — compute the narrowest grant (hard error on empty intersection — a broken build beats a broad policy); authenticate with the platform's *existing* service-identity pattern (projected tokens, mTLS, signed headers — whatever it already uses); filter the surface instead of annotating it; revoke dormant capability.

**Derived guard** — a compile/build test: narrow-caller × wide-resource must produce the narrow policy, empty intersection must throw; a 401 test per unauthenticated endpoint found; a test that the readOnly surface contains zero mutating entries.

---

## 2. Deployment-value drift

Platform code carries values that belong to one deployment: tenant slug, agent/service names, cloud region or account, store codes, business constants, user-facing language. The killer shape is the **silent fallback** — `env.TENANT ?? 'acme'` — which makes a fresh deployment impersonate deployment #1 instead of failing.

**Shapes**
- `?? 'literal'`, `|| "literal"`, `??= 'literal'`, default parameters — on identity-shaped values.
- Config that exists but **is not wired** in the deploy artifacts (chart/compose/terraform): the fallback is the *nominal* path, not a safety net. Grep the env var name in the deployment templates to prove wiring.
- Deployment values in schema *examples*, tool descriptions, seed data.
- Deployment-specific catalogs (schedules, report definitions, code lists) frozen in source.

**Detect**
```
grep -rnE "\?\?\s*['\"]|\|\|\s*['\"]|\?\?=\s*['\"]" src/ packages/ --include=*.ts --include=*.py
```
then triage each literal: identity-shaped (region/account/GUID/email/domain/slug) → finding.

**Root fix** — `required(ENV)` fail-fast at boot for services; lazy `required()` at first use for shared multi-mount processes (so an unrelated mount doesn't crash at import); move the value to deployment config and wire it; neutral placeholders (`acme`) in examples. For catalogs: move to the system that owns them at runtime (if a scheduler/orchestrator already stores them server-side, delete the in-repo catalog and the boot-time reconcile that overwrites it — the runtime store is the source of truth).

**Derived guard** — the strongest pattern in this skill: a CI test whose forbidden set is **derived**, never hand-listed:
- names derived from the project's own registry/config files (agents, services, tenants);
- shape patterns for infrastructure identity (cloud regions `['"][a-z]{2}-(east|west|…)-\d['"]`, GUIDs, emails, account IDs);
- every identity-shaped leaf of the deployment config auto-forbidden in source (once a value lives in config, duplicating it in code fails CI);
- short substring-prone tokens matched **quoted only**; an allowlist of pre-existing offenders that may only shrink.

---

## 3. Contract drift

A contract exists; nothing holds the code to it.

**Shapes**
- A schema file no code loads: the loader is a hand-rolled normalizer that accepts unknown keys — a misspelled discriminator key degrades a rule into a silent catch-all.
- A vendored copy of a schema/constant with **no drift test** against the source of truth.
- A list mirroring another source (deps, registry, config) maintained by hand.

**Detect** — for each file under `schemas/`/`contracts/`: `grep -rn "<schema-basename>"` in source; no loader → finding. For each normalizer: feed it an unknown key mentally — rejected or absorbed? For vendored constants: `grep` the same structure in two places.

**Root fix** — validate at load with the real schema (the ecosystem's standard validator), fail loud with instance paths; vendor + equality drift test when the runtime can't read the file directly; derive lists in code, or add an alignment test when derivation isn't clean.

**Derived guard** — `expect(vendoredCopy).toEqual(sourceOfTruth)`; an unknown-key fixture that must be rejected at load; alignment tests that recompute the derived list and diff it.

---

## 4. Robustness drift

The unhappy path was never drawn.

**Shapes**
- **I/O without timeout** where the repo's own convention demands one (`fetch` without `AbortSignal.timeout`, HTTP clients without deadline): one TCP hang freezes the whole lane (a channel, a poller, a worker).
- **Outside the fail-closed envelope**: the code arms a user-visible state (typing indicator, ack, lease) then awaits something unguarded *before* persisting; a transient error strands the interaction — never persisted, never retried, never apologized.
- **Unbounded reads**: a query tool with no row cap and no byte cap; one big SELECT OOMs the pod or floods the context.

**Detect** — `grep -rn "fetch(" | grep -v "signal:"` (adapt per client); read every handler that signals progress and check what sits between the signal and the durable write; every query/list tool → where is the cap?

**Root fix** — apply the repo's existing timeout idiom (constant per module, value fitted to the call); widen the try/catch to cover everything after the state is armed, reusing the *same* user-facing failure notice as the neighboring fail-closed branch; cap at the source (server-side limit — e.g. a session `sql_select_limit` for SQL without explicit LIMIT) **and** cap the response bytes, with an explicit `truncated` flag.

**Derived guard** — a hang test (mock never resolves → abort fires); a throwing-dependency test (user notified, nothing enqueued, state cleared); a big-result test (bounded, flagged).

---

## 5. Duplication drift

The same logic reimplemented instead of shared — each copy drifts alone.

**Shapes** — response shaping (`ok`/`fail`, truncation) hand-rolled per package while a shared kit exists; the same auth/retry/error-mapping helper in N places; constant sets copy-pasted.

**Detect** — `grep -rn "const ok = \|function ok(\|function fail(" packages/*/src` and cluster the bodies; when a shared kit package exists, list which siblings import it and which reimplement it.

**Root fix** — extend the kit with the missing helper (keep per-caller knobs as parameters: caps, error describers), rally every package; thin local aliases are fine — the point is that *shape logic lives in exactly one place*. When moving a helper to a shared home, move its tests with it and re-point the import — don't fork.

**Derived guard** — mostly review discipline; where derivable, an alignment test (e.g. every package importing the kit's result type must not define its own).

---

## 6. Hygiene drift

Dead weight that misleads.

**Shapes**
- A **dead kind**: schema + types + validator for an entity with zero instances and zero consumers.
- **Phantom dependencies**: declared in the manifest, imported nowhere. Counter-validate against *runtime* launchers before removing — a Dockerfile `CMD [".../node_modules/.bin/tsx", …]` makes that dep real for that package even with zero imports.
- The **test runner scanning stale directories** (git worktrees, dist, vendored checkouts): the suite runs N×, and a stale copy can fake green on code that no longer exists.
- A **frozen dependency line with known CVEs parsing user input** — move to the maintained/official distribution channel even when it left the default registry.

**Detect** — for each declared dep: `grep -rn "from '<dep>'" src/` (then check Dockerfiles/scripts); for each schema kind: count instances in the data dirs and consumers in code; run the test suite and read the *file count* — does it match the source tree?

**Root fix** — delete (git history is the archive — no `_legacy` copies, no commented-out blocks); add the runner exclude; upgrade via the official channel and run the parsing tests.

**Derived guard** — runner config exclude committed; where cheap, a manifest-alignment test (declared deps ⊆ imported ∪ runtime-launched).
