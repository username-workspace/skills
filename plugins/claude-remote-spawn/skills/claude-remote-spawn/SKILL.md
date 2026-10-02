---
name: claude-remote-spawn
description: Spawn a VISIBLE Claude Code session you can drive from your terminal, phone or desktop (Remote Control). By default `spawn` opens it in a NEW terminal tab where you launched it (tmux, iTerm2, Terminal.app, WezTerm, kitty, Konsole, GNOME Terminal, else x-terminal-emulator) running `claude --remote-control <name>`; with no scriptable terminal it falls back to detached. `spawn --detach` runs it PERSISTENT inside a PTY instead, alive until you stop it. Cross-platform (macOS + Linux), no dependency. Use when asked to spawn a remote-controllable Claude session, launch a persistent agent you can steer from your phone, keep a Claude session running detached from your terminal, open a child session in a visible local terminal tab, or resume/respawn an existing session remotely from its id (or from a description, by composing with the find-session skill). Subcommands via driver.sh — spawn / open / resume / list / stop / check.
---

# claude-remote-spawn

> `spawn` launches a **visible** Claude Code session — `claude --remote-control <name>` — in a **new
> tab of your terminal**, so you see and drive it where you launched it, and it shows up in `claude
> agents` **and** in **Remote Control** (phone/desktop). `spawn --detach` runs it in a **PTY**
> (`script(1)`) instead, persistent until you `stop` it.

Sessions use `--permission-mode auto` (auto-approve) by default; set `CRS_HEADLESS_DANGEROUS=1`
for `--dangerously-skip-permissions`, or `CRS_HEADLESS_PERM_FLAGS` for an exact override.

## Usage

    driver.sh [open|spawn|resume|list|stop|check] [args]

**`open` is the default** — a bare invocation (or a first token that isn't a known subcommand,
e.g. just a session name) runs `open`.

| Subcommand | Effect |
|---|---|
| `spawn [name] [--model M] [--prompt 'text'] [--detach]` | Launch the session in a **new terminal tab** so you see and drive it **live where you launched it**; with no scriptable terminal (SSH, headless) it falls back to detached. `--detach` = **persistent, detached** PTY session (Remote Control + phone). `--prompt` submits an initial instruction, so the session starts working unattended. Name from context (else NATO: alpha/bravo/charlie…) |
| `open [name] [--model M] [--prompt 'text']` | **DEFAULT** (bare invocation). Same tab as `spawn`, but **tab-only**: fails with the launcher path instead of detaching |
| `resume <id> [name] [--in-place] [--model M]` | Respawn an **existing** session by id; forks a fresh drivable id by default (`--in-place` = same id) |
| `list` | List spawned sessions (live/dead, with the model if one was set) |
| `stop <name>` | Stop a session (kills the PTY + claude, cleans state) |
| `check` | Health: claude, script, perms, **available models**, remoteControlAtStartup, session count |

## Choosing the model

`--model` picks the model for the spawned session. It takes **any value your `claude` accepts** — an
alias (`opus`, `sonnet`, `fable`, …) or a full id (`claude-fable-5`) — and is passed **straight to
`claude --model`, which validates it**. Nothing is hardcoded, so new models work the day `claude` ships
them. Omit it to use your default; `check` prints the alias list from your own `claude --help`.

    driver.sh spawn reviewer --model opus
    driver.sh spawn nightly --detach
    driver.sh resume <id> --model sonnet

## Naming

Sessions should be **recognizable**, not random:

- **spawn** — pass a descriptive `name` from the task/context (the feature, repo, or goal you're
  spawning the agent for). If you omit it, the next **NATO phonetic** name is assigned
  (`alpha`, `bravo`, `charlie`…).
- **resume** — the name is **auto-recovered** from the session's own title (Claude Code's generated
  title, which also tracks the latest exchanges) and shown as the Remote Control display name; pass
  a `name` to override.

## How `spawn --detach` works (and why it stays visible)

- Runs `claude --remote-control <name>` inside a **PTY** via `script(1)` — the only way an
  interactive Remote-Control session survives detached — the same pattern a persistent
  launchd/systemd KeepAlive service uses (`script -q … claude …`).
- The session **stays alive** (a real long-running process) → it appears in `claude agents`
  and, with `"remoteControlAtStartup": true` in `~/.claude/settings.json`, in **Remote
  Control** on your phone/desktop. You drive it from there.
- It's a **long-running, visible** session — not a one-shot that exits immediately and leaves nothing
  to drive.

## The terminal tab (`spawn`, `open`)

`spawn` (and `open`) **see and drive the session in your own terminal**, where you launched the
skill — not only from your phone:

    driver.sh spawn [name] [--model M] [--prompt 'text']

- It opens a **new tab** in the terminal that launched the skill and runs `claude --remote-control
  <name>` directly in it. Detection, first match wins: **tmux** (`$TMUX` → new window), **WezTerm**
  (`wezterm cli spawn`), **kitty** (`kitty @ launch --type=tab`, needs `allow_remote_control`),
  **Konsole** (`--new-tab`), **GNOME Terminal** (`--tab`), **iTerm2** / **Terminal.app**
  (`osascript`), else **`x-terminal-emulator`** (new window) when a display is present.
- While the tab is open the session is a normal Remote-Control session too (shows up in `claude
  agents`, drivable from the phone). It also appears in `list` (marked `window`) and `stop` works.
- **It is ephemeral by design.** There is no detach engine (no tmux/screen), so the session's life is
  tied to the tab: **close the tab and the session ends** — and there's no phone-driving after that.
  This is the deliberate trade for "no dependency, visible in my terminal". When you need a session
  that survives and stays phone-drivable, use `spawn --detach`.
- With no terminal it can script (SSH, headless, an unknown terminal), `spawn` says so and **falls
  back to detached**, so the session still exists; `open` fails instead and prints the path of a
  ready-to-run launcher you can execute in **any** terminal yourself.

## Resume an existing session

`resume` respawns a **past** session as a Remote-Control session, so you can pick it back up from
your phone:

    driver.sh resume <session-id> [name] [--in-place]

- It resolves the session's original working directory from its transcript and respawns there, named
  by the session's recovered title.
- **Forks by default** (`--fork-session` → a fresh session id) — this is what makes the resumed
  session show up as a new, drivable Remote Control entry. Resuming **in place** an id that Remote
  Control already knows does *not* surface a new entry, so `--in-place` (continue the same id) is the
  exception, not the default.
- To resume **from a description** instead of an id, resolve the id with the **find-session** skill
  first, then pass it here — the two compose, no hard dependency:
  *"reopen the session about the payload-hash work, remotely"* → `find-session` → id →
  `driver.sh resume <id>`.

## Keeping the machine awake (so sessions survive)

A spawned session is a **local process**: if the machine sleeps, it is frozen and Remote Control drops.
Lid-close sleep ignores `caffeinate`/IOKit assertions, so while a session is live and **on AC power**,
`spawn`/`open`/`resume` keep it awake (even lid-closed) and `stop` releases once no session remains. On
battery it is never held (no overheat / drain). Toggle off entirely with `CRS_KEEPAWAKE=0`. `check`
reports the mechanism, power source, and current hold. Unplugging mid-session doesn't auto-revert — the
next `spawn`/`stop` re-evaluates it.

- **macOS** — `pmset disablesleep`, which needs root. Grant the narrow, passwordless right *once*
  (only that one setting):

      echo "$USER ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1" \
        | sudo tee /etc/sudoers.d/claude-remote-spawn >/dev/null && sudo chmod 440 /etc/sudoers.d/claude-remote-spawn

  Without the rule, sessions still spawn — `check` and the first spawn print a one-line hint — but the
  Mac may sleep lid-closed and drop them.

- **Linux** — a detached `systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block` holder
  process (started on the first live session, killed on the last). No setup on a standard systemd
  desktop; an active login session may be required by polkit to take the lid-switch lock. Power source
  is read via `on_ac_power` (no battery → treated as AC, e.g. a server). If `systemd-inhibit` is absent,
  sessions still spawn and a one-line hint is printed.

## Requirements / gotchas

- **Workspace trust is pre-approved.** Claude Code parks an untrusted folder on its workspace-trust
  dialog *before* registering with Remote Control — the session runs but stays invisible. So
  `spawn`/`open`/`resume` first mark the cwd trusted in the claude config (`~/.claude.json`, override
  `CRS_CLAUDE_CONFIG`): the same `hasTrustDialogAccepted` flag the dialog's "Yes" writes, keyed by the
  physical path. Needs `python3`; without it a one-line hint is printed and the dialog has to be
  answered in the session. Runs in `$PWD`; override with `CRS_SPAWN_CWD`.
- `spawn --detach`/`resume` need `script(1)` (present on macOS + Linux); the tab needs the terminal's
  own CLI (`osascript` for iTerm2/Terminal.app).
- State lives in `~/.claude/headless/<name>.{spawn,log}` (plus `<name>.cmd`, the launcher, for a tab session).

## Env

- `CRS_CLAUDE_BIN` — path to `claude` (default `~/.local/bin/claude`)
- `CRS_HEADLESS_STATE` — state dir (default `~/.claude/headless`)
- `CRS_SPAWN_CWD` — working dir for `spawn`/`open` (default `$PWD`)
- `CRS_CLAUDE_CONFIG` — claude config where workspace trust is pre-approved (default `~/.claude.json`)
- `CRS_HEADLESS_DANGEROUS` — use `--dangerously-skip-permissions` instead of the `auto` default
- `CRS_HEADLESS_PERM_FLAGS` — exact permission-flags override (`""` = none)
- `CRS_KEEPAWAKE` — `0` disables the keep-awake hold (default on; macOS `pmset` / Linux `systemd-inhibit`, AC only)
