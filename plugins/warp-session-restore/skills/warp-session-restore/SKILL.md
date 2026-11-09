---
name: warp-session-restore
description: Restart the Claude Code sessions that were running, after a shutdown, a reboot or a Warp restart — each one in a Warp tab, grouped by the folder it runs in (its git repository, worktrees included), resuming its own session in place. A hook snapshots the running sessions on every session start and turn end; restore reopens them in the running Warp's window, or as a launch configuration that starts Warp with one tab group per folder. Use when the user wants to reboot or quit Warp without losing their sessions, says they rebooted and wants their sessions back, asks to restore, reopen or relaunch the sessions that were running, asks what a restore would bring back, or asks whether Warp's Claude Code integration is set up.
allowed-tools: Bash
---

# warp-session-restore

    python3 scripts/warp_session_restore.py snapshot | show | restore | check

## Snapshot

The plugin's hook takes it on every session start and turn end, so a boot's snapshot holds the sessions
alive at the last turn before the shutdown, and on every session end: a session closed with `/exit` (or
`/clear`, a logout) leaves it, one a shutdown stops stays. `snapshot` takes one by hand and prints it.

- **Sessions** — each live Claude Code CLI session of `~/.claude/sessions`: its id, name, folder and the
  launch flags worth replaying, read from the process's exact arguments. A name Claude Code derived is
  not kept, so the resumed session derives its own again. A session of the Claude desktop app is left
  out: the app reopens its own.
- **Launcher** — a session started by a script of its own repository (a workspace's `bin/claude-session`)
  keeps that script, its first argument when it is not a flag, and the flags given to it.
- **Detached** — a session run under `script(1)`, as `claude-remote-spawn --detach` runs one.
- **Group** — the folder the session runs in: the git repository it belongs to (a subfolder or a
  worktree joins its repository), else the folder's name; the home folder is `home`.
- One file per boot under `~/.claude/warp-snapshots/`, the last ten kept.

## Restore

    python3 scripts/warp_session_restore.py restore [--dry-run] [--window] [--current | --from FILE] [name...]

It reads the newest snapshot taken **before the current boot**. Each session opens in its own tab, in
its folder, running `claude --resume <id> -n <name> <flags>` — the same transcript and the same Remote
Control entry — or, when a launcher started it, `<launcher> --resume <id> <its flags>`, so the launcher
sets up what it sets up again. A detached session comes back detached, through
`claude-remote-spawn resume <id> <name> --in-place`, in no tab. Groups come in name order, each with its
color, its sessions in name order.

- **Warp running** — the tabs open in Warp's active window, one Tab Config each
  (`~/.warp/tab_configs/warp-session-restore-<n>.toml`, opened with `warp://tab_config/<name>`, deleted by
  the tab's first command), colored like their group: Tab Configs hold no tab group.
- **Warp not running**, or `--window` — the launch configuration `warp-session-restore`
  (`~/.warp/launch_configurations/warp-session-restore.yaml`, opened with
  `warp://launch/warp-session-restore.yaml`) starts it: one window, one tab group per folder.

A session already running is skipped; one whose folder is gone is named and skipped. It then waits until
every resumed session runs again. When one does not (a locked screen), it says which and how to open it
by hand: the tab from Warp's + menu, or File > Launch Configurations > `warp-session-restore`.

- `name...` — only those sessions (by name or id).
- `--dry-run` — print the report and the configurations, open nothing.
- `--current` — this boot's snapshot (sessions lost to a crash, before any other turn ends);
  `--from FILE` a given one.
- `show` prints the snapshot a restore would use, by group, with the same `--current` / `--from`.

Warp's own "Restore windows, tabs, and panes on startup" reopens shells, never the agents: turn it off
(`restore_session = false` under `[general]` of `~/.warp/settings.toml`) to let this restore be the only
one. A large session may open on Claude Code's "resume from summary" question: answer it in its tab.

## Agents in Warp

`check` reports the launch configurations and Tab Configs folders, the snapshots, and whether Warp's
Claude Code plugin is enabled — it carries Warp's agent notifications (`claude plugin marketplace add
warpdotdev/claude-code-warp && claude plugin install warp@claude-code-warp`, needs `jq`). Warp shows a
Claude Code session's status on its pane and in vertical tabs; its Agent Management panel lists only
Warp's own agents, never a Claude Code session.

## Env

- `WS_SNAPSHOT=0` — the hook takes no snapshot.
- `WS_LAUNCH_DIR`, `WS_TAB_DIR`, `WS_SESSIONS_DIR`, `WS_SNAPSHOT_DIR` — override where the launch
  configurations, the Tab Configs, Claude Code's session registry and the snapshots are.
- `WS_OPEN_WAIT` — seconds restore waits for the resumed sessions (default 30).
- `WS_DETACH_DRIVER` — the `claude-remote-spawn` driver a detached session comes back through (default
  `~/.claude/skills/claude-remote-spawn/driver.sh`); absent, it opens in a tab like the others.
