# Mécanismes vérifiés — sessions Remote Control et messagerie inter-sessions

Vérifications faites le 2026-09-07 depuis une session de l'app desktop Claude (Windows 11,
Claude Code 2.1.260, compte claude.ai unique) vers quatre sessions Remote Control : Mac
(`workspace`), Mac Studio (`claude-mac-studio`, `mac-studio`), Raspberry Pi 5 (`homecloud`).
Ce qui vient de la documentation officielle et non d'un test est marqué *(doc)*.

## 1. Les quatre identifiants d'une session

| Identifiant | Exemple | Où il vit | À quoi il sert |
|---|---|---|---|
| Nom de pair | `workspace` | `--name`, `--remote-control "<nom>"`, `/rename` ; champ `name` du registre | adresse de `SendMessage`, ligne de `ListAgents` |
| `[ref]` | `[d60591]` | calculé par `ListAgents` (opaque, ni hash sha256/md5/sha1 de l'ID) | désambiguïser deux sessions au même nom |
| UUID local | `d06074e3-…` | `~/.claude/projects/<cwd>/<uuid>.jsonl`, `--resume` | reprise locale, sans intérêt à distance |
| **ID claude.ai** | `session_01CtH1M8FKe8jgHp6sVKey6r` | `bridgeSessionId` du registre, URL `claude.ai/code/<id>` | **`get_run_log`**, `claude remote-control --session-id`, `claude --cloud` |

Registre local, un fichier par processus : `~/.claude/sessions/<pid>.json` (vu sur Windows ;
format identique attendu sur macOS/Linux — à confirmer par `scripts/rc-sessions.sh --ssh`) :
```json
{"pid":44704,"sessionId":"d06074e3-abdd-4d6b-8f60-fc82cb94f462","cwd":"C:\\Users\\admin\\…",
 "startedAt":1788693570879,"version":"2.1.260","peerProtocol":1,
 "peerFeatures":["notify_idle","artifact_yield"],"kind":"interactive","entrypoint":"claude-desktop",
 "messagingSocketPath":"\\\\.\\pipe\\LOCAL\\cc-msg-…","name":"username-desktop","nameSource":"user",
 "bridgeSessionId":"session_01JPBs5jx9UYZDXm8DWitVwK"}
```
Un fichier `<pid>.<hash>.key` voisin contient le jeton d'authentification du socket : ne jamais le
copier ni l'afficher.

Sidebar de claude.ai/code : chaque session est un lien `href="/code/session_01…"` — le mappage
nom → ID s'y lit directement (vérifié pour les quatre sessions).

## 2. `ListAgents`

Sortie réelle depuis l'app desktop :
```
This session is username-desktop [427c62] — the name other sessions use to message it (it is not
listed below; a message to it would be a message to yourself).

Peer sessions (4):
  workspace [d60591]  ·  Remote Control  ·  idle
  mac-studio [81e589]  ·  Remote Control  ·  idle
  claude-mac-studio [6fb027]  ·  Remote Control  ·  idle
  homecloud [e3b6c2]  ·  Remote Control  ·  idle
  (session list too long to fetch completely — sessions beyond the first pages are missing from this listing)
```
- Les sessions d'autres machines n'apparaissent que si la session courante est elle-même
  connectée en Remote Control *(doc)*. Statuts : `idle`, `busy`, `offline` (connexion RC tombée).
- Une session qui a fait `/exit` (événement `system/worker_shutting_down: host_exit` dans son
  log) n'apparaît plus.
- Lecture « plus récentes d'abord », nombre de pages borné : au-delà, les sessions anciennes sont
  absentes et ne sont pas adressables par nom *(doc + observé)*.
- Vue depuis `workspace` (Mac) au même moment : `claude-mac-studio [614b3c] · interactive · idle ·
  started 2d ago` (session **locale** à cette machine, kind `interactive`), `username-desktop
  [ee1a28] · Remote Control · idle`, `mac-studio [81e589] · Remote Control · running`, `homecloud
  [e3b6c2] · Remote Control · running`. Le `[ref]` d'une même session diffère donc selon qui liste
  (`username-desktop` = `[427c62]` vu d'ici, `[ee1a28]` vu du Mac) : identifiant d'affichage, pas
  de stockage. La première ligne « This session is … » était absente dans cette session.

## 3. `SendMessage`

- Désactivé dans les sessions de l'app desktop : `No such tool available: SendMessage.
  SendMessage is disabled for this session, in subagents as well as here.` (observé). Les sessions
  desktop ont à la place `mcp__ccd_session_mgmt__send_message`, qui ne voit que les sessions de
  la même app (`list_sessions` → « No other sessions found » alors que `ListAgents` en voit 4).
- Disponible dans les sessions terminal interactives, `claude remote-control`, `claude -p`
  (sauf `--bare`) *(doc)*.
- Paramètres : `to` (nom, ou `nom [ref]`), `message` (texte brut), `notify_when_idle`
  (même machine seulement ; à distance l'appel entier est refusé) *(doc)*. Dans le log de la
  session émettrice, l'appel apparaît avec `recipient`, `message` (doublé en `content`) et
  `summary` ; l'outil était différé et chargé par `ToolSearch("select:SendMessage")` (observé).
- Résultat observé, 23 s après l'appel : `{"success":true,"message":"“<summary>” → username-desktop
  (a Claude session on another machine, over Remote Control; your session list was too long to
  check completely, so a same-named session beyond what was searched would not have been
  seen)","msg_id":"832fb505-…"}`.
- Réception observée à la même seconde (destinataire idle → nouveau tour démarré aussitôt) :
  `user: <cross-session-message from="bridge:session_01CtH1M8FKe8jgHp6sVKey6r" from-name="workspace"
  from-mode="prompting"> pong … </cross-session-message>` — l'ID claude.ai de l'émetteur est dans
  le `from`, `from-mode` donne sa classe de permissions.
- Livraison *(doc)* : lue entre deux appels d'outils si la cible travaille ; démarre un nouveau
  tour si elle est idle. Apparaît chez la cible comme `› Message from @<émetteur>: <1re ligne>`
  (aperçu replié depuis 2.1.247), texte complet lu par Claude.
- Adresse de réponse : présente seulement si l'émetteur est connecté en Remote Control ; sinon
  message à sens unique et l'émetteur en est averti *(doc)*.
- Contrôles entrants *(doc)* : `crossSessionInbound` = `accept` / `hold` / `refuse`. Sans réglage :
  une cible qui *demande* les permissions (default, auto, acceptEdits, dontAsk) livre tout sauf ce
  qui vient d'un émetteur en bypassPermissions ; une cible en bypassPermissions met tout en attente
  sauf ce qui vient d'un émetteur bypass. Attente = boîte de dialogue, `dialogExpiry` 5 min par
  défaut, puis abandon.
- Ce que la cible ne fera pas sur ordre d'une autre session *(doc)* : approuver une permission,
  modifier settings/CLAUDE.md, exécuter une commande `/slash` (reçue comme texte). Ses invites de
  permission continuent de s'afficher — pour l'humain.
- Limites *(doc)* : ~1 M de caractères par message (même machine), rafales refusées côté
  émetteur, doublons rapides ignorés côté cible, file de 50 messages, boucles A↔B étranglées.
- Historique des correctifs (CHANGELOG) : 2.1.240 messagerie inter-machines sur Windows ;
  2.1.248 « `SendMessage` vers une session Remote Control hors ligne se lisait comme délivré »
  corrigé ; 2.1.251 « `ListAgents`/`SendMessage` signalaient “Remote Control is not connected”
  dans les sessions lancées par `claude remote-control` » corrigé.

## 4. `RemoteTrigger get_run_log` — la relecture

Appel : `RemoteTrigger({action: "get_run_log", session_id: "session_01…"})`, `cursor` optionnel
(valeur de `next_cursor`, page vers le passé). Le jeton OAuth est ajouté par l'outil ; aucun
`curl` possible à la main.

Réponse réelle (session `homecloud`, extrait) :
```
HTTP 200
{"session_id":"session_01LyQaWHnWFmX99x4RS6hFPa","events_fetched":200,"events_shown":123,"next_cursor":"1386"}
(77 non-transcript event(s) on this page skipped: control_response ×24, control_request/get_context_usage ×14, …)
[2026-09-06T19:01:08.226641Z] user: je l'ai fait mais j'ai pas de retour, tu peux vérifier … ?
[2026-09-06T19:01:15.643160Z] tool_use Bash: {"command":"S=\"timeout 90 ssh -o BatchMode=yes … [+481 chars]
[2026-09-06T19:01:17.955349Z] tool_result: === HiberbootEnabled 0 === …
[2026-09-06T19:01:26.986584Z] assistant: [thinking]
[2026-09-06T19:01:44.368213Z] assistant: Oui, c'est bien pris en compte, et je l'ai confirmé …
[2026-09-06T19:01:44.517613Z] result: success is_error=false turns=0 duration=0s
[2026-09-06T19:02:24.444288Z] init: model=claude-opus-5[1m] cwd=
```
Grammaire des lignes : `[ISO-UTC] <kind>: <texte>` avec kind ∈ `init`, `user`, `assistant`,
`tool_use <Outil>`, `tool_result`, `tool_result ERROR`, `result`, `system/<événement>`,
`code change published`. Les entrées JSON et textes longs sont tronqués avec `[+N chars]`.

Constaté :
- Fonctionne sur des sessions Remote Control (Mac, Pi), sur une session desktop, sur des
  sessions terminées ; 404/400 sinon. `session_d60591` ou `d60591` → HTTP 400 « must be a cse_…
  or session_… tagged ID ».
- Quasi temps réel : le log de la session courante contenait les appels d'outils du tour en cours.
- `turns=N` et `duration=0s` dans `result:` ne sont pas fiables (`turns=0` sur toute une session
  Pi malgré des appels d'outils, `turns=29` sur le Mac) : seule la présence de la ligne compte.
- Un blocage par le classificateur du mode auto apparaît en `tool_result ERROR: Permission for
  this action was denied by the Claude Code auto mode classifier …`.
- `init:` toutes les ~4 min sur une session `claude remote-control` idle = battements de
  reconnexion, pas de l'activité.
- `cwd=` est vide dans les lignes `init:` de l'échantillon — ne pas s'y fier pour identifier la
  machine ; lire plutôt les chemins dans les `tool_use`.

## 5. Ce qui ne marche pas (et pourquoi)

| Tentative | Résultat | Raison |
|---|---|---|
| `mcp__ccd_session_mgmt__list_sessions` / `list_events` | « No other sessions found » | portée = l'app desktop locale |
| `SendMessage` depuis l'app desktop | outil désactivé | choix du harness desktop |
| `claude.exe` embarqué (`%APPDATA%\Claude\claude-code\<ver>\claude.exe`) hors de l'app | `loggedIn: false` | l'app gère l'auth ; le binaire n'a pas de session claude.ai |
| Retrouver l'ID depuis le `[ref]` | impossible | `[ref]` opaque ; passer par le registre ou l'URL |
| `RemoteTrigger list_runs` sans routine | `trigger_id must be a valid trig_ tagged ID` | pas de listing global des sessions par cet outil |

## 6. Inventaire au 2026-09-07 (exemple, à rafraîchir)

| Nom | ID claude.ai | Machine / cwd | Note |
|---|---|---|---|
| workspace | `session_01CtH1M8FKe8jgHp6sVKey6r` | Mac, `/Users/username/src/zv/workspace` | modèle claude-fable-5-1 ; a répondu au test |
| claude-mac-studio | `session_01MBRxWW4FbMbHMv2BTzdKzd` | même Mac que `workspace` (vue `interactive` depuis elle), `~/src/zv/workspace/infra` | Opus 5 |
| mac-studio | `session_01JnAeAx7m84g1XPW48J9Udn` | autre processus, machine non déterminée d'ici (vue `Remote Control` depuis `workspace`) | `/rename mac-studio` le 2026-09-04 ; `init:` toutes les 4 min = serveur `claude remote-control` idle |
| homecloud | `session_01LyQaWHnWFmX99x4RS6hFPa` | Raspberry Pi 5, `/home/username` | pilote le desktop Windows en SSH |
| username-desktop | `session_01JPBs5jx9UYZDXm8DWitVwK` | Windows, app desktop | reçoit les messages ; pas de SendMessage |

## 7. Test de bout en bout (2026-09-07, 00:53-00:55 UTC)

Ordre collé par l'utilisateur dans `workspace` (claude.ai/code) : `ListAgents`, lecture de
`~/.claude/sessions/*.json`, `SendMessage` vers `username-desktop`, sentinelle `FIN TEST`.

| UTC | Côté | Événement (extrait de `get_run_log`) |
|---|---|---|
| 00:53:55 | workspace | `user: [TEST PILOTAGE MULTI-SESSION …]` |
| 00:53:59 | workspace | `tool_use ListAgents` → 4 pairs dont `username-desktop [ee1a28] · Remote Control · idle` |
| 00:54:00 | workspace | `tool_use Bash: cat ~/.claude/sessions/*.json` → `tool_result ERROR: … denied by the Claude Code auto mode classifier` (idem `ls`+`head` à 00:54:45) |
| 00:54:01 | workspace | `tool_use ToolSearch: select:SendMessage` (outil différé) |
| 00:54:58 | workspace | `tool_use SendMessage: {recipient:"username-desktop", message:"pong …", summary:"…"}` |
| 00:55:21 | workspace | `tool_result: {"success":true, …, "msg_id":"832fb505-…"}` |
| 00:55:21 | username-desktop | `user: <cross-session-message from="bridge:session_01CtH1M8FKe8jgHp6sVKey6r" from-name="workspace" from-mode="prompting"> pong …` — session idle réveillée, nouveau tour |
| 00:55:29 | workspace | `assistant: Résultat du test … FIN TEST` puis `result: success is_error=false turns=6` |

Enseignements : la sentinelle et le `result:` marquent bien la fin ; le rappel est chez le
destinataire au moment du `success` de l'émetteur et réveille un pilote idle ; l'ID de l'émetteur
est dans l'en-tête du message reçu ; la lecture du registre `~/.claude/sessions` par Claude est
bloquée en mode auto (le dossier contient des jetons `.key`).
