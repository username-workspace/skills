# Pilot log — <date>

Pilot: `<ListAgents name>` (`session_…`), machine <…>

| Timestamp (UTC) | Target | claude.ai ID | TAG | Sent | Verdict | Result (1 line) |
|---|---|---|---|---|---|---|
| 2026-09-07T00:10Z | workspace | session_01EXAMPLEWORKSPACE000001 | WS-07-tests | sent | done OK | 212 tests, 0 failures |
| 2026-09-07T00:12Z | pi-lab | session_01EXAMPLEPILAB0000000001 | PI-07-disk | sent | blocked (sudo permission) | approve on claude.ai |

Possible verdicts: `done OK`, `done ERROR`, `in progress`, `blocked (permission/question)`,
`not delivered (offline/hold/refuse)`, `timed out`.
