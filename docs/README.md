# Documentation

- **[architecture.md](architecture.md)** — how the marketplace is built: plugin anatomy, the vendored
  kernel, `.git/`-local state and sibling coupling, the delivery harness, engagement modes, the test
  architecture, and the security model. Start here to understand the system.
- **[../CONTRIBUTING.md](../CONTRIBUTING.md)** — the contributor workflow: the gate, the incident rule,
  adding or changing a plugin, versioning, and the self-hosted delivery loop.
- **[plans/](plans/)** — implementation plans. A plan is a point-in-time design document; once its work
  ships it is marked **Shipped** and kept as a historical record, not a live to-do. The current state
  of the system lives in `architecture.md`, never in a plan.

Per-plugin behaviour is documented in each plugin's `SKILL.md` (the copy loaded into an agent's
context) and `web.json` (the storefront copy rendered at [username.digital/skills](https://username.digital/skills)).
