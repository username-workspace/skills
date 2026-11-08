---
name: warp-session-restore
description: Restart the Claude Code sessions running in Warp exactly as they were, after a shutdown, a reboot or a Warp restart — the same windows, tab groups (name, color, collapsed, pinned), tab colors and pane splits, each Claude pane resuming its own session in place. A hook snapshots Warp's layout with the session of each pane on every session start and turn end; restore reopens it in the running Warp's window, or as a launch configuration that starts Warp. Use when the user wants to reboot or quit Warp without losing their sessions, says they rebooted and wants their Warp sessions back, asks to restore, reopen or relaunch the sessions or tabs that were running in Warp, asks what a restore would bring back, or asks whether Warp's Claude Code integration is set up.
allowed-tools: Bash
---

# warp-session-restore

    python3 scripts/warp_session_restore.py snapshot | show | restore | check

## Snapshot

The plugin's hook takes it on every session start and turn end, so a boot's snapshot is the layout and
the sessions alive at the last turn before the shutdown. `snapshot` takes one by hand and prints it.

- **Layout** — read from Warp's own state database (`warp.sqlite`, read-only): windows, tab groups and
  their name, color, collapsed and pinned state, tab titles and colors, nested pane splits, the focused
  pane, each pane's folder.
- **Sessions** — each live Claude Code CLI session of `~/.claude/sessions` is matched to its pane by
  the pane's `WARP_TERMINAL_SESSION_UUID`, with its name, folder and the launch flags worth replaying.
  A session that ran outside Warp is listed, not restored.
- One file per boot under `~/.claude/warp-snapshots/`, the last ten kept. Warp writes its database
  a few seconds after a change: a tab opened a moment ago may be missing from a snapshot taken at once.

## Restore

    python3 scripts/warp_session_restore.py restore [--dry-run] [--current | --from FILE] [name...]

It reads the newest snapshot taken **before the current boot** and reopens it in the Warp that is there:

- **Warp running** — each tab holding a session to resume opens in Warp's active window, from a Tab
  Config (`~/.warp/tab_configs/warp-session-restore-<n>.toml`, opened with
  `warp://tab_config/warp-session-restore-<n>`, deleted by the tab's first command): its title, color and
  pane splits as they were. Tab Configs hold no tab group, and a tab with nothing to resume stays closed.
- **Warp not running**, or `--window` — the launch configuration `warp-session-restore`
  (`~/.warp/launch_configurations/warp-session-restore.yaml`, opened with
  `warp://launch/warp-session-restore.yaml`) starts it: a new window per snapshot window, tab groups and
  splits as they were.

Each Claude pane runs `claude --resume <id> -n <name> <flags>` in place — the same transcript and the same
Remote Control entry. A pane whose session is already running, or whose folder is gone, opens a shell
instead, and the report says so.

It then waits until every resumed session runs again. When one does not (a locked screen), it says which
and how to open it by hand: the tab from Warp's + menu, or File > Launch Configurations >
`warp-session-restore`.

- `name...` — only the tabs holding those sessions (by name or id).
- `--dry-run` — print the report and the configurations, open nothing.
- `--window` — a new window even when Warp is running, tab groups included.
- `--current` — this boot's snapshot (sessions lost to a Warp crash, before any other turn ends);
  `--from FILE` a given one.
- `show` prints the snapshot a restore would use, with the same `--current` / `--from`.

Warp restores its own windows on startup, with shells and no agents, so after a reboot both appear:
close Warp's own, or turn off Settings > Features > "Restore windows, tabs, and panes on startup" to
let this restore be the only one. A large session may open on Claude Code's "resume from summary"
question: answer it in its pane.

## Agents in Warp

`check` reports Warp's database, the launch configurations folder, and whether Warp's Claude Code
plugin is enabled — it carries Warp's agent notifications (`claude plugin marketplace add
warpdotdev/claude-code-warp && claude plugin install warp@claude-code-warp`, needs `jq`). Warp shows a
Claude Code session's status on its pane and in vertical tabs; its Agent Management panel lists only
Warp's own agents, never a Claude Code session.

## Env

- `WS_SNAPSHOT=0` — the hook takes no snapshot.
- `WS_WARP_DB`, `WS_LAUNCH_DIR`, `WS_TAB_DIR`, `WS_SESSIONS_DIR`, `WS_SNAPSHOT_DIR` — override where Warp's database,
  the launch configurations, the Tab Configs, Claude Code's session registry and the snapshots are.
- `WS_OPEN_WAIT` — seconds restore waits for the resumed sessions (default 30).
