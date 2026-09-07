# Instruction envelope — template to send through SendMessage

Replace `<pilot>` with the name shown on the first line of `ListAgents`, `<TAG>` with a short,
unique task identifier (e.g. `WS-07-tests`). One step per message.

```
[PILOT from <pilot> — task <TAG>, mandated by the user]
Context: <one or two lines: where we are, why this step>
To do: <the instruction, precise, verifiable, a single step>
Constraints: <no commit / do not touch X / answer in N lines / install nothing>
When done:
1. End your answer with the exact line `END <TAG> OK` (or `END <TAG> ERROR <reason>` if you are blocked).
2. Send SendMessage({to: "<pilot>", message: "<TAG> done — <summary in 3 lines max, with useful paths/errors>"}).
If you lack a permission, do not insist: write `END <TAG> ERROR permission <which one>` and send the callback.
```

Why these two ingredients:
- the **sentinel** `END <TAG>` is found by `get_run_log` even when the rest of the text is truncated
  (`[+N chars]`), and it tells the answer to *this* instruction apart from a turn started by someone
  else on the same session;
- the **callback** wakes the pilot session if it is idle and carries an untruncated summary. It only
  arrives if the pilot is connected to Remote Control; without it, reading back still works.

First contact — to get a target's claude.ai ID without touching its registry:
```
[PILOT from <pilot> — first contact, mandated by the user] Change nothing. Only send SendMessage({to: "<pilot>", message: "hello <your session name> — cwd <your current directory>"}) then end with the line `END CONTACT OK`.
```
The ID is then read in the header of the received message:
`<cross-session-message from="bridge:session_01…" from-name="<target>" …>`.

Filled example:
```
[PILOT from pilot-desktop — task WS-07-tests, mandated by the user]
Context: stabilizing branch feat/returns before the merge request.
To do: run `npm test` in ~/src/<project>/frontend and report the passed/failed counts and the first 5 lines of each failure.
Constraints: no file changes, no commit.
When done:
1. End your answer with the exact line `END WS-07-tests OK` (or `END WS-07-tests ERROR <reason>`).
2. Send SendMessage({to: "pilot-desktop", message: "WS-07-tests done — <3-line summary>"}).
If you lack a permission, do not insist: write `END WS-07-tests ERROR permission <which one>` and send the callback.
```
