---
name: remote-control-pilot
description: >-
  Drive one or more Claude Code sessions connected through Remote Control on other machines
  (a Mac, a Pi, a desktop, a server): find them (ListAgents + the claude.ai session ID), send them
  instructions one turn at a time (SendMessage with a completion callback), and above all READ
  what they actually did with RemoteTrigger get_run_log — the return channel SendMessage never
  provides. Use this skill whenever the user wants to control, pilot, orchestrate, query or watch
  another Claude session ("my workspace session", "the session on the build box", "what did the pi
  session do?", "send this to the other session"), mentions multi-session work, Remote Control,
  SendMessage or ListAgents, or complains that a message sent to another session came back with
  nothing — even when the word skill is never spoken.
---

# Piloting Claude Code Remote Control sessions

Three channels, three tools. None of them does the job of the other two:

| Need | Tool | What it gives you |
|---|---|---|
| Find the sessions | `ListAgents` | name, `[ref]`, kind (`Remote Control` / `cloud` / local), status `idle` / `busy` / `offline` |
| Give an order | `SendMessage({to, message})` | an acknowledgement that the message **left**, never the result |
| Read what happened | `RemoteTrigger({action:"get_run_log", session_id})` | the session's condensed transcript (turns, tools, errors, end-of-turn markers) |

The classic complaint — "the message goes out but there is no way to know what the remote session
did" — comes from forgetting the third channel. `SendMessage` is mail; `get_run_log` is reading the
other session's logbook, in near real time, from any session of the same claude.ai account. The full
loop was verified on 2026-09-07 with Claude Code 2.1.260: order received by a Remote Control session
on a Mac, executed, `SendMessage` callback delivered to a Windows session at the very moment the
sender got its `success`, turn read back with `get_run_log` (real outputs and timelines:
`references/verified-mechanics.md`).

If `RemoteTrigger` is not among the loaded tools it is deferred: `ToolSearch("select:RemoteTrigger")`
makes it callable. Same for any tool named here.

## Prerequisites

**Pilot session (the one running this skill)** — an interactive `claude` terminal connected to
Remote Control (`claude --remote-control "pilot-<machine>"` or `/rc` inside an existing session).
That is what lets it see sessions on other machines *and* what gives targets a reply address:
without Remote Control on the pilot side the message leaves "with no reply address".
Two contexts only partly qualify:
- **Claude desktop app (Code tab)**: `ListAgents` and `get_run_log` work, and it **receives**
  messages from other machines, but `SendMessage` is disabled there ("SendMessage is disabled for
  this session, in subagents as well as here"). It can *watch* and collect reports, not *command*.
- **Cloud sessions (claude.ai/code)**: they receive messages but cannot reply.

**Target sessions** — on every machine to pilot:
```bash
claude --remote-control "<unique-name>"        # interactive session + Remote Control
claude remote-control --name "<unique-name>"   # server mode: no local typing, recovers by itself after a crash
```
A unique, meaningful name (`workspace`, `build-box`, `pi-lab`) is what makes a session findable;
`/rename <name>` works after the fact too. Two sessions with the same name force you to address
them with the `[ref]`. The process must stay alive (open terminal, tmux, a service): a session whose
terminal was closed shows `offline`. Version ≥ 2.1.251 everywhere (decisive SendMessage fixes for
Remote Control landed in 2.1.248 and 2.1.251).

For a target to work with nobody at the screen, its permissions must already cover the task
(`auto` mode, `acceptEdits`, `allow` rules): a message from another session **never counts as
consent** — it cannot approve a permission, change configuration, or run a `/slash` command. A target
in `bypassPermissions` holds messages from other sessions for approval (5 minutes, then dropped)
unless `crossSessionInbound: "accept"` is in its user settings.

## Step 1 — Find the sessions and their identifiers

Call `ListAgents`. The first line gives the **pilot's own name** (the address targets reply to);
every following line is a reachable session:
```
This session is pilot-desktop [a1b2c3] — the name other sessions use to message it
Peer sessions (3):
  workspace [d4e5f6]  ·  Remote Control  ·  idle
  build-box [789abc]  ·  Remote Control  ·  idle
```
The list is read "newest first" over a bounded number of pages: when it ends with "session list
too long to fetch completely", an older target may be missing — waking it from claude.ai or the app
is enough to bring it back up, and archiving old cloud sessions cleans the list. Two observed
details: the `[ref]` of one session **changes depending on which session lists it** (never store
it), and inside a Remote Control session the first line "This session is …" may be missing — the
pilot's name is then the one passed to `--name` / `--remote-control` / `/rename`, or the `name`
field of its `~/.claude/sessions/<pid>.json`.

To *read* a session you also need its **claude.ai ID** `session_01…` (24 characters after
`session_`), which `ListAgents` does not show. Four sources, simplest first:

1. **The header of a received message**: every cross-session message arrives wrapped in
   `<cross-session-message from="bridge:session_01…" from-name="workspace" from-mode="prompting">`.
   First contact is therefore enough: ask each target for a plain acknowledgement (the "first
   contact" template in `assets/instruction-envelope.md`) and read the ID in `from`.
2. **The claude.ai/code sidebar**: each session is a link `/code/session_01…`; open the session and
   copy the URL (the ID is what follows `/code/`, before any `?`).
3. **The target machine's local registry**: `~/.claude/sessions/<pid>.json` holds `name`,
   `bridgeSessionId`, `cwd`, `kind`, `entrypoint`, `version`. `scripts/rc-sessions.sh` reads it from
   a shell (current machine or `--ssh <host>`). The folder also holds the socket's `.key` tokens,
   and the auto-mode classifier **blocks** Claude from reading it (`cat`, then `ls`+`head`, refused
   during the test): go through a human shell, SSH, or an explicit `allow` rule. No
   `bridgeSessionId` means the session is not on Remote Control.
4. **Ask the target to read its own registry** — same caveat as 3; prefer 1.

Keep the result in a small registry (`assets/session-registry.example.json` shows the shape):
name → ID → machine → cwd → date. An ID survives reconnections (`claude --continue` reattaches the
same claude.ai session) but not a fresh `claude remote-control`; when `get_run_log` answers 404 or
the content no longer matches, refresh the entry.

## Step 2 — Send an instruction

One instruction per message, and no new message until the previous turn has finished: the target
reads messages **between two tool calls** during a turn, and starts a new turn if it is idle. A
second order sent mid-work would be read in the middle of executing the first one, and bursts are
refused or queued.

Address with the name exactly as `ListAgents` prints it; add the `[ref]` only when two rows share
the name or an error asks for it. `SendMessage` may be deferred (`ToolSearch("select:SendMessage")`);
follow the loaded schema (recipient, message, and a one-line `summary` echoed in the result). The
result looks like `{"success":true,"message":"“<summary>” → workspace (a Claude session on another
machine, over Remote Control; …)","msg_id":"…"}`: it confirms the recipient and the channel, not
the execution, and it can take ~20 s to come back. `notify_when_idle` only works between sessions
on the same machine: across machines the completion notice has to be requested explicitly.

Use the envelope in `assets/instruction-envelope.md`. Its two ingredients make the outcome
unambiguous to detect:
- a **unique sentinel line** at the end of the answer (`END <TAG> OK` / `END <TAG> ERROR …`), which
  `get_run_log` finds even when the rest of the text is truncated;
- a **callback through `SendMessage` to the pilot**, which wakes the pilot (a message received by an
  idle session starts a turn) and carries the full summary.

Pick a short, unique `TAG` per task (`T07-tests`, `WS-2026-09-07-1`). Say in the message that the task
is mandated by the user, knowing the target will still treat it as coming from a session, not from
the human: missing permissions will block, not be bypassed.

The `SendMessage` result ("sent", "delivered") means the message left, nothing more. A target that
is `offline` or refuses (`crossSessionInbound: refuse`) does nothing; a target that "holds" waits for
a human approval on its machine or on claude.ai.

## Step 3 — Read the outcome

```
RemoteTrigger({action: "get_run_log", session_id: "session_01EXAMPLEWORKSPACE000001"})
```
Response: a JSON header (`events_fetched`, `events_shown`, `next_cursor`), the list of skipped
control events, then the **200 most recent events**, oldest to newest, UTC timestamps:
```
[2026-09-06T23:13:11Z] user: yes, align it with the reference implementation, do the pass
[2026-09-06T23:13:36Z] assistant: [thinking]
[2026-09-06T23:14:04Z] tool_use Bash: {"command":"cd ~/src/<project>; python3 - <<'PY'… [+6784 chars]
[2026-09-06T23:14:06Z] tool_result: config patched, source models written
[2026-09-06T23:15:39Z] tool_result ERROR: Exit code 1 …
[2026-09-06T23:24:56Z] assistant: Pass done, the form now matches the reference. …
[2026-09-06T23:24:56Z] result: success is_error=false turns=29 duration=0s
[2026-09-06T23:55:57Z] system/worker_shutting_down: host_exit
```
How to read it:
- `result:` = **end of turn**. The target's final text is the last `assistant:` line (excluding
  `[thinking]`) before that `result:`. Check that it carries the sentinel `END <TAG>`.
- No `user:` containing the message you sent → it did not arrive (target offline, message held for
  approval, refused, or list truncated). A cross-session message shows up as
  `user: <cross-session-message from="bridge:session_01…" from-name="<pilot>"
  from-mode="prompting"> … </cross-session-message>`; look for the TAG inside that block.
- `user:` present, `tool_use`/`tool_result` lines still being added → **in progress**; read again later.
- `user:` present, nothing for several minutes, no `result:` → **blocked**: a permission to approve
  or a question asked (`AskUserQuestion`); only the human answers, from claude.ai or the mobile app.
  Tell the user rather than waiting.
- `tool_result ERROR:` → copy the cause; "denied by the Claude Code auto mode classifier" or
  "Permission … denied" = the task exceeds the target's permissions.
- Repeated `init:` lines = reconnections, not turns. `system/worker_shutting_down: host_exit` = the
  session exited (`/exit`); `ListAgents` will show it `offline` or not at all.
- Long texts are cut (`[+N chars]`): for a large result, ask the target to write it to a file or to
  put it in the `SendMessage` callback.
- `next_cursor` only pages **backwards**; every call returns the latest events. One call ≈ 10-40 KB:
  space re-reads 30-60 s apart, no tight loop.

`get_run_log` works on any claude.ai session of the account (Remote Control, cloud, desktop app) as
long as you have its `session_…`; it reflects events of the very same second.

## Step 4 — The piloting loop, one turn at a time

```
registry ← ListAgents + IDs (step 1)
for each step of the task:
  1. SendMessage(to: <name>, message: envelope(TAG, instruction, callback to <pilot>))
  2. wait: the callback wakes the pilot if it is idle (it reaches the pilot at the moment the
     sender gets its `success`); otherwise re-read get_run_log every 30-60 s
  3. read: done (result + sentinel) / in progress / blocked / not delivered / error
  4. decide the next step from the final text and the real errors, not from the summary alone
  5. log: timestamp, target, TAG, verdict, one line of result
```
To wait without blocking: `Bash({command: "sleep 45", run_in_background: true})` then re-read on
the notification (a foreground `sleep` is often forbidden by the harness), or `/loop` /
`ScheduleWakeup` for a long task. Set a maximum delay per step and, past it, read one last time then
tell the user the exact state rather than resending the order.

**Several targets**: one message per session, each with its own TAG, then one read per ID; keep the
table in `assets/pilot-log-template.md` (name, ID, machine, status, last result). Never route orders
from one target to another (A→B→A loops, which Claude Code throttles but which are better not
created): the pilot stays the only sender.

**Reporting to the user**: quote what the target *did* (tools, files, errors seen in the log), not
only what it *says* it did; give the session's name and ID so they can open the same page on
claude.ai.

## Transferring files to a target

`SendMessage` carries text only. Without SSH between the machines, the channel that works is an
**Artifact** on claude.ai (private, tied to the account): publish a page that embeds each file as
plain text in a `<pre data-path="path">` block (with `&amp; &lt; &gt;` escaped) plus a SHA-256
manifest, then pass the URL in the instruction. The target reads the raw HTML with
`Artifact({action: "read", url})` — the full page is saved to a local file — then recreates each
file with `Write` and checks the digests. Do not ask it to decode the page with a script: the
auto-mode classifier blocks Bash/Python transformation of downloaded content (`base64 -d`, an
extraction script, even a `cp` of the page) while `Write` goes through. A write outside the
target's working directory triggers a **permission prompt** (the session shows "Needs input" on
claude.ai and `get_run_log` stops moving): only the human approves it, from claude.ai, the app or
the terminal — one "Always allow" covers the following files. Verified on 2026-09-07: 8 files,
78 KB, Windows → Mac, SHA-256 identical on arrival.

## Frequent pitfalls (details and fixes: `references/troubleshooting.md`)

- Message sent, nothing back → normal; read with `get_run_log`, ask for the callback.
- The target cannot reply → the pilot session is not on Remote Control (no reply address).
- Message never received → target `offline`, held for approval (`hold`), `refuse`, or truncated list.
- `SendMessage` missing → desktop app, or a `deny` rule on `SendMessage`/`ListAgents`.
- The `ccd_session_mgmt` tools (`list_sessions`, `list_events`, `send_message`) only see the local
  desktop app: useless across machines.
- `get_run_log` → 400 "must be a cse_… or session_… tagged ID": you passed the `[ref]` or the local
  UUID instead of the claude.ai ID.
- The target cannot read `~/.claude/sessions` (auto classifier) → take the ID from the header of
  its message, not from its registry.

## Files in this skill

- `references/verified-mechanics.md` — what was tested, with real (anonymized) outputs and versions.
- `references/troubleshooting.md` — symptoms → causes → fixes, including bugs fixed per version.
- `scripts/rc-sessions.sh` — name ↔ `bridgeSessionId` from `~/.claude/sessions`, local or over SSH.
- `assets/instruction-envelope.md` — template of the instruction message (sentinel + callback).
- `assets/pilot-log-template.md`, `assets/session-registry.example.json` — multi-session tracking.
