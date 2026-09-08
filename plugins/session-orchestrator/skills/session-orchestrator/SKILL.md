---
name: session-orchestrator
description: >-
  Make the current session the orchestrator of every other Claude Code session of the account,
  on top of what the harness already runs: agent view and background sessions (`claude agents`,
  `claude --bg`, `logs`, `attach`, `stop`), cross-session messaging (ListAgents, SendMessage),
  Remote Control and RemoteTrigger get_run_log. It takes inventory, dispatches one tagged order per
  target, spawns a native background session when none fits, reads the harness's own state files
  for what each session really did or needs, and reports one aggregated verdict. Use it whenever
  the user wants to pilot, orchestrate, supervise, dispatch to or collect from several sessions at
  once ("pilot all my sessions", "session d'orchestration", "what is each session doing", "which
  session is blocked", "dispatch this to another session"), or asks to set up a piloting session —
  even when the word skill is never spoken.
---

# Session orchestrator — one session pilots the others

This session becomes the **orchestrator**: the only sender, the only place the orders live, the
only one reporting to the user. Targets execute; they never command each other.

The harness already does most of the work. Agent view supervises background sessions on this
machine and records, for each one, its state, why it is blocked, and its final result. This skill
reads that record instead of keeping its own, and adds only what the harness has no notion of:
an **order** (a tagged instruction with a verdict), and targets on **other machines**.

| Need | Harness feature | Tool / command |
|---|---|---|
| Who is alive, doing what | agent view | `claude agents --json --all`, `ListAgents` |
| Run new work in parallel | background sessions | `claude --bg "<prompt>" --name <name>` |
| Give an existing session an order | cross-session messaging | `SendMessage` (+ `notify_when_idle` on this machine) |
| Read what a session did / needs | agent view state, run logs | `~/.claude/jobs/<id>/state.json`, `claude logs <id>`, `RemoteTrigger get_run_log` |
| Reach another machine or the web | Remote Control | `ListAgents` from a session on Remote Control |
| Hold the orders across turns | this skill | `scripts/orchestrator.py` |

Deferred tools load with `ToolSearch("select:SendMessage,RemoteTrigger")`. The details of the
message envelope and of reading a run log line by line are in the **remote-control-pilot** skill;
this one owns the fleet-level loop.

## Step 1 — Inventory

```
orchestrator.py sync        # this machine, from the harness; the orchestrator itself is excluded
ListAgents                  # adds peers on other machines and on the web (needs Remote Control)
orchestrator.py list
```
`sync` reads `claude agents --json --all` and enriches each row from the harness's own files:
`~/.claude/sessions/<pid>.json` (interactive sessions, claude.ai id `session_01…`) and
`~/.claude/jobs/<id>/state.json` (background sessions, claude.ai id `cse_…`, `needs`,
`output.result`). Both id forms are accepted by `get_run_log`. The orchestrator recognises itself
through `CLAUDE_CODE_SESSION_ID` / `CLAUDE_CODE_BRIDGE_SESSION_ID`, so it can never be a target.

A session on another machine is registered by hand once its id is known — the header of any
message it sends carries it (`<cross-session-message from="bridge:session_01…">`), so a
first-contact ping is the cheapest way:
```
orchestrator.py add pi-lab --machine pi --bridge-id session_01… --role "home lab"
```
A target with no claude.ai id can receive orders but never be verified; fix that first.

## Step 2 — Dispatch

**New work on this machine → a background session, not a message.** The harness isolates it in a
worktree before it edits, shows it in `claude agents`, fires `agent_completed` /
`agent_needs_input` notifications, and records its result:
```
claude --bg "<self-contained prompt>" --name <name> [--model M] [--permission-mode auto]
orchestrator.py sync && orchestrator.py assign <name> <TAG>
```
The prompt must carry everything: a background session inherits no conversation. `--bg` cannot be
combined with `-p`. For a session the user must also drive from their phone, use
`claude-remote-spawn` instead (`driver.sh spawn`), then `add` it.

**Existing session → one tagged order per turn.** Record it, then send:
```
orchestrator.py assign workspace WS-01 --note "run the polaris gate"
SendMessage({to: "workspace", message: <envelope: TAG, instruction, sentinel END WS-01 OK|ERROR, callback to the orchestrator>, notify_when_idle: true})
```
Check the harness first: an interactive session that is `busy` reads the order between two
tool calls, **inside the user's current task**, and answers from there — verified. Prefer an idle
session or a background one; `assign` warns when the target is busy.
`notify_when_idle` brings back one notice when a session **on this machine** goes idle — no
polling. Across machines it is refused; ask for the callback in the envelope instead. `assign`
refuses a second order on a busy target and refuses reusing a live tag — a target reads messages
between two tool calls, so a second order mid-turn is read in the middle of the first one.

**Permissions never travel.** An order is not consent: a target does only what its own mode
allows, cannot approve a prompt, and never runs a `/slash` command from a message. A target in
`bypassPermissions` **holds** messages for the human unless `crossSessionInbound: "accept"` is set
for it. Never route work to a peer because it was denied here — route it back to the user.

## Step 3 — Follow

```
orchestrator.py report
```
The report is computed from the harness at the moment it runs: **NEEDS INPUT** (a permission
prompt, a question — with the `needs` text the session wrote), **WORKING**, **OPEN ORDER** (tag,
age, live state), **FINISHED** (with `output.result`), **EXITED** (a background job whose
process is gone — its last state is history, not a request: nobody can answer a question asked
in July; `claude rm` clears it, `claude respawn` revives it), then remote and offline targets
and any target without an id. A background row without `pid` has no process: only a live
process can need input or be working. A blocked session is reported the moment it is seen, never waited on:
only the human unblocks it, from `claude agents` (Space to peek and reply, Enter to attach) or
from claude.ai.

To read more than the summary:
- background session on this machine: `claude logs <id>` (recent terminal output) or
  `claude attach <id>` to take over;
- any session of the account: `RemoteTrigger({action: "get_run_log", session_id: "<cse_… | session_01…>"})`
  — `result:` ends a turn, the last `assistant:` line before it must carry `END <TAG>`, a
  `permission prompt` with nothing after it is a block.

Wait without blocking: the idle notice or the callback wakes this session; otherwise
`Bash({command: "sleep 45", run_in_background: true})` and re-read on the notification, or
`ScheduleWakeup` for long jobs. Never a tight loop; past a deadline you set, read once more and
report the real state instead of resending.

## Step 4 — Close and report

```
orchestrator.py resolve workspace ok --tag WS-01
orchestrator.py resolve builder blocked --tag B-02 --note "permission on ~/src/infra"
```
Verdicts: `ok`, `error`, `blocked`, `timeout`. A verdict on a tag the target is not running is
refused. Two truths, never one: the harness state says whether the session **finished** (`done`,
`failed`, `blocked`), the sentinel `END <TAG> OK | ERROR` says whether the **order** succeeded.
A `done` session whose sentinel reads `ERROR` is an `error` — verified: a gate-runner ended
`done` with a reassuring summary while its sentinel reported a red suite. Stop what is finished (`claude stop <id>`, `claude rm <id>`
once its worktree is merged or discarded): a fleet nobody prunes becomes a list nobody reads.

Report to the user what targets **did** — tools, files, errors seen in the log — not what they
claim, with each session's name and id so they can open the same page in `claude agents` or on
claude.ai.

## The registry

`scripts/orchestrator.py` keeps `$CLAUDE_CONFIG_DIR/orchestrator/registry.json` (or
`~/.claude/orchestrator/`), so a second Claude account gets its own; `ORCHESTRATOR_HOME` overrides.
It stores only what the harness does not: orders, claude.ai ids, remote targets, roles and notes.
Everything else — liveness, state, blocking reason, result — is read from the harness on every
`list` and `report`, so it can never go stale.

| Command | Effect |
|---|---|
| `sync [--json]` | import this machine's sessions from `claude agents --json --all` |
| `add <name> [--bridge-id --local-id --machine --cwd --role --note]` | register or update a target |
| `assign <name> <tag> [--note]` | record an order; refuses a busy target, a live tag, the orchestrator itself |
| `resolve <name> <ok\|error\|blocked\|timeout> [--tag --note]` | close an order with its verdict |
| `list [--json]` | registry joined with the live harness state |
| `report [--json]` | needs input / working / open orders / finished / attention / remote / offline |
| `forget <name>` | drop a target |

Exit codes: `0` fine, `1` unknown target or bad usage, `2` an invariant refused the operation.
Without a reachable `claude` binary (`CLAUDE_CODE_EXECPATH`, else `PATH`), the registry still
answers with a warning.

## Pitfalls

- An interactive session started with bare `claude` is not in `claude agents` until it is
  backgrounded (`/bg`, or `←` on an empty prompt); `ListAgents` still sees it.
- `claude logs` needs the background service alive; a job left from a previous boot answers
  *connect ENOENT* — its `state.json` and `get_run_log` still work.
- Replying to a message means copying its `from=` attribute as the recipient —
  `bridge:session_01…` from another machine, `uds:/tmp/cc-socks/<pid>.sock` on this one; a session
  **title** is not an address (*No agent named … is reachable*).
- The `[ref]` shown by `ListAgents` differs per listing session — address by name, never store it.
- Sessions beyond this machine are listed newest first over a bounded number of pages: an old one
  can be missing; the registry is what remembers it.
- A background session's process stops after ~1 h idle (the conversation stays); `claude respawn
  <id>` or a message brings it back.
- Running N sessions burns N× the usage; dispatch what is independent, not what is convenient.
