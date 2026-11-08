---
name: session-restore
description: Snapshot the Claude Code sessions running on this machine and reopen them, exactly where they were, after a shutdown or reboot. A hook keeps the snapshot current on every session start and turn end; restore reopens each session in place (same session id, same Remote Control entry, same folder and launch flags) in a new tab of your terminal, or detached when no tab can be opened. Use when the user wants to shut down or reboot without losing their sessions, says they rebooted and wants their sessions back, asks to resume / reopen / relaunch the sessions that were running, or asks which sessions a restore would bring back.
---

# session-restore

Run the driver of the `claude-remote-spawn` skill, next to this one:

    ../claude-remote-spawn/driver.sh snapshot
    ../claude-remote-spawn/driver.sh restore [--dry-run] [--from FILE] [name...]

## Snapshot

The plugin's hook takes it on every session start and every turn end, so the snapshot of a boot is the
set of sessions alive at the last turn before the shutdown. `snapshot` takes one by hand and lists what
it recorded.

- **What it records** — every live interactive CLI session of `~/.claude/sessions/`: its id, name,
  folder and the launch flags worth replaying (`--remote-control`, `--permission-mode`, `--model`,
  `--effort`, `--add-dir`, `--dangerously-skip-permissions`…). A session of the Claude desktop app is
  left out: the app reopens its own.
- **Where** — one file per boot, `~/.claude/session-snapshots/<boot>.json`, the last ten kept. A
  session closed on purpose drops out of the next snapshot.

## Restore

`restore` reads the newest snapshot taken **before the current boot**, so a session started after the
reboot never overwrites what there is to restore. For each session:

- already running → skipped; its folder gone → skipped and named;
- otherwise `claude --resume <id> -n <name> <flags>` in its folder, in place: the same transcript, and
  the same Remote Control entry, which comes back online on your phone.

Each session opens in a new tab of the terminal that runs the restore (Warp, iTerm2, Terminal.app,
tmux, WezTerm, kitty…). When the terminal does not open the tab — a locked screen, an unknown
terminal, a run over SSH — it resumes detached in a PTY, drivable from Remote Control, and `list` /
`stop <name>` of `claude-remote-spawn` manage it.

- `--dry-run` prints what would be reopened, and why each session is skipped.
- `name...` restores only the sessions named.
- `--from FILE` restores a given snapshot, the current boot's included (sessions lost to a terminal
  crash, before any other session ends a turn).

A large session may open on Claude Code's own "resume from summary" question: answer it in its tab
(a detached one is answered with the full session).

## Env

- `CRS_SNAPSHOT=0` — the hook takes no snapshot.
- `CRS_SNAPSHOT_DIR` — where snapshots live (default `~/.claude/session-snapshots`).
- `CRS_SESSIONS_DIR` — the session registry read (default `~/.claude/sessions`).
- `CRS_TAB_WAIT` — tenths of a second a Warp tab has to open before restore goes detached (default 50).
