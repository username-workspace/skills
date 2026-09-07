# Troubleshooting — piloting Remote Control sessions

| Symptom | Likely cause | Fix |
|---|---|---|
| The message leaves ("sent") but nothing comes back | `SendMessage` never waits for an answer | Read the target with `RemoteTrigger get_run_log`; ask for a `SendMessage` callback to the pilot in the envelope |
| The target answered in its terminal but "cannot write to me" | Pilot not connected to Remote Control → message without a reply address | `/rc` (or `claude --remote-control`) in the pilot session before sending |
| No `user:` with my message in `get_run_log` | Target `offline`; message held (`hold`) then expired (5 min); `crossSessionInbound: refuse`; name missing from the first pages | `ListAgents` for the status; approve on the target machine or set `crossSessionInbound: "accept"`; wake the target from claude.ai to move it up the list |
| A `bypassPermissions` target ignores my messages | Default rule: it holds what comes from a non-bypass sender | `"crossSessionInbound": "accept"` in its user settings, or the same permission class on both sides |
| `user:` present, then nothing, no `result:` | Permission prompt or `AskUserQuestion` pending — only the human can answer | Open the session on claude.ai / the mobile app, approve; for the future, widen the target's `allow` rules or permission mode |
| `tool_result ERROR: … denied by the Claude Code auto mode classifier` | The task exceeds what the target's auto mode allows | Rephrase as a less invasive action, or have the user add an `allow` rule; do not insist |
| `No such tool available: SendMessage … disabled for this session` | Desktop app session (or a `deny` rule) | Pilot from a terminal; from the desktop, limit yourself to `ListAgents` + `get_run_log` |
| `ListAgents` shows no session from another machine | Pilot without Remote Control; API key / Bedrock / Vertex / Foundry; `ANTHROPIC_BASE_URL` redirected | claude.ai login + `/rc`; unset the variable |
| "Remote Control is not connected" from a `claude remote-control` session | Bug fixed in 2.1.251 | `claude update` on the target |
| Message to an offline target read as "delivered" | Bug fixed in 2.1.248 | update; check the status with `ListAgents` before sending |
| `ListAgents`: "session list too long to fetch completely" | Too many recent cloud/RC sessions | Archive old sessions on claude.ai/code; keep the targets active |
| `get_run_log` → HTTP 400 "must be a cse_… or session_… tagged ID" | `[ref]`, local UUID or truncated ID passed as `session_id` | Use the full `bridgeSessionId` (`session_` + 24 characters) |
| `get_run_log` → 404 / content of another conversation | The session was recreated (fresh `claude remote-control`) | Refresh the registry (script, claude.ai URL, or a message header) |
| Two sessions with the same name | Rename without `/rename` on the other one, or different versions | Address `name [ref]`; rename one of the two |
| `Too many messages to this session just now` | Burst to one target | Merge into a single message; wait for the `result:` before the next one |
| `Message too large for cross-session delivery` | Message > ~1M characters | Write the content to a shared file and send only the path, or use an Artifact |
| The target treated my order as a suggestion, not a mandate | It knows the message comes from a session, not from the user | Say so in the envelope ("mandated by the user"); accept that it refuses what its permissions forbid |
| `SendMessage` refused: "target is the current session" | Address = the pilot's own name | Check the first line of `ListAgents` |
| `ccd_session_mgmt` tools (`list_sessions`, `list_events`, `send_message`) empty | Scope = sessions of the same desktop app | Do not use them across machines |
| Sandbox/WSL: sessions on the same machine invisible to each other | Different filesystems / socket types | They reach each other as distinct machines, through Remote Control |
| The target cannot read `~/.claude/sessions/*.json` ("denied by the Claude Code auto mode classifier") | The folder holds the socket's `.key` tokens; the classifier protects it | Take the ID from the `<cross-session-message from="bridge:session_…">` header of its message; or read the registry from a human shell / SSH; explicit `allow` rule if really needed |
| The `[ref]` noted yesterday no longer matches | The `[ref]` is computed by the listing session, different from one session to another | Use the `[ref]` only in the `SendMessage` call of the moment; store the name and the `session_…` ID |
| `ListAgents` without a first line "This session is …" | Name not attributable to the user in a Remote Control session | The name is the one given by `--name` / `--remote-control` / `/rename`, or the `name` field of `~/.claude/sessions/<pid>.json` |
| `SendMessage` not found although you are in a terminal | Deferred tool | `ToolSearch("select:SendMessage")` then call it |
| `success:true` received, but 20 s after the call | Server round trip of cross-machine delivery | Normal; do not resend |
| The target fails to extract files from a downloaded page or archive (`base64 -d`, Python script, `cp` blocked) | Auto classifier: script transformation of downloaded content | Have it recreate the files with `Write` (content read through `Artifact read` or `Read`), then check the SHA-256 digests |
| Session "Needs input" on claude.ai, nothing in `get_run_log` for minutes | Pending permission prompt (write outside the working directory, sensitive command) | Approve from claude.ai / the app / the terminal; "Always allow" for a series of files; anticipate with `/add-dir` or an `allow` rule on the target |
| Message typed by automation into the claude.ai/code composer: composer emptied, no `user:` in the log | Synthetic input not registered by the editor | Click into the field, type, **check with a screenshot** that the text is there, then Enter; confirm with `get_run_log` |
