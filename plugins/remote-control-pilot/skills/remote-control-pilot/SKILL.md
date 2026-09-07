---
name: remote-control-pilot
description: >-
  Piloter à distance une ou plusieurs sessions Claude Code connectées en Remote Control sur
  d'autres machines (Mac, Pi, desktop, serveur…) : les retrouver (ListAgents + ID de session
  claude.ai), leur envoyer des instructions tour par tour (SendMessage avec accusé de fin), et
  surtout LIRE ce qu'elles ont réellement fait grâce à RemoteTrigger get_run_log — le retour que
  SendMessage ne fournit jamais. Utiliser ce skill dès que l'utilisateur veut contrôler, piloter,
  orchestrer, interroger ou surveiller une autre session Claude (« ma session workspace »,
  « la session sur le mac-studio », « qu'a fait homecloud ? », « envoie ça à l'autre session »),
  parle de multi-session, de Remote Control, de SendMessage ou ListAgents, ou se plaint de ne pas
  voir le résultat d'un message envoyé à une autre session — même sans prononcer le mot skill.
---

# Piloter des sessions Claude Code Remote Control

Trois canaux, trois outils. Aucun ne fait le travail des deux autres :

| Besoin | Outil | Ce qu'il donne |
|---|---|---|
| Retrouver les sessions | `ListAgents` | nom, `[ref]`, kind (`Remote Control` / `cloud` / local), statut `idle` / `busy` / `offline` |
| Donner un ordre | `SendMessage({to, message})` | un accusé d'**envoi**, jamais le résultat |
| Lire ce qui s'est passé | `RemoteTrigger({action:"get_run_log", session_id})` | le transcript condensé de la session (tours, outils, erreurs, fin de tour) |

Le problème classique — « le message part mais impossible de savoir ce que la session a fait » —
vient de l'oubli du troisième canal. `SendMessage` est un envoi de courrier ; `get_run_log` est la
lecture du journal de bord de l'autre session, en quasi temps réel, depuis n'importe quelle session
du même compte claude.ai. Boucle complète vérifiée le 2026-09-07 sur Claude Code 2.1.260 : ordre
reçu par une session Remote Control sur Mac, exécution, rappel `SendMessage` arrivé sur Windows au
moment même où l'émetteur recevait son `success`, relecture du tour par `get_run_log` (sorties
réelles et chronologie : `references/mecanismes-verifies.md`).

Si `RemoteTrigger` n'apparaît pas dans les outils chargés, il est différé : `ToolSearch("select:RemoteTrigger")`
le rend appelable. Idem pour tout outil cité ici.

## Prérequis

**Session pilote (celle qui exécute ce skill)** — un terminal `claude` interactif connecté en
Remote Control (`claude --remote-control "pilote-<machine>"` ou `/rc` dans une session existante).
C'est la condition pour voir les sessions des autres machines *et* pour que les cibles puissent
répondre : sans Remote Control côté pilote, le message part « sans adresse de réponse ».
Deux contextes ne conviennent que partiellement :
- **App desktop Claude (onglet Code)** : `ListAgents` et `get_run_log` marchent, et elle **reçoit**
  les messages venus d'autres machines, mais `SendMessage` y est désactivé (« SendMessage is
  disabled for this session, in subagents as well as here »). On peut y *surveiller* et recevoir
  des comptes rendus, pas *commander*.
- **Sessions cloud (claude.ai/code)** : elles reçoivent des messages mais ne peuvent pas répondre.

**Sessions cibles** — sur chaque machine à piloter :
```bash
claude --remote-control "<nom-unique>"        # session interactive + Remote Control
claude remote-control --name "<nom-unique>"   # mode serveur : sans saisie locale, reprend seul après un crash
```
Un nom unique et parlant (`workspace`, `mac-studio`, `homecloud`) est ce qui rend la session
retrouvable ; `/rename <nom>` fonctionne aussi après coup. Deux sessions au même nom obligent à
adresser avec le `[ref]`. Le processus doit rester vivant (terminal ouvert, tmux, service) : une
session dont le terminal est fermé passe `offline`. Version ≥ 2.1.251 sur toutes les machines
(corrections décisives de SendMessage en Remote Control dans 2.1.248 et 2.1.251).

Pour qu'une cible travaille sans humain devant l'écran, ses permissions doivent déjà couvrir la
tâche (mode `auto`, `acceptEdits`, règles `allow`) : un message venu d'une autre session **ne vaut
jamais consentement** — il ne peut ni approuver une permission, ni modifier la configuration, ni
lancer une commande `/slash`. Une cible en `bypassPermissions` met de son côté les messages des
autres sessions en attente d'approbation (5 min, puis abandon) sauf si `crossSessionInbound: "accept"`
est dans ses settings utilisateur.

## Étape 1 — Retrouver les sessions et leurs identifiants

Appeler `ListAgents`. La première ligne donne le **nom de la session pilote** (l'adresse à laquelle
les cibles répondent) ; chaque ligne suivante, une session joignable :
```
This session is pilote-desktop [427c62] — the name other sessions use to message it
Peer sessions (4):
  workspace [d60591]  ·  Remote Control  ·  idle
  mac-studio [81e589]  ·  Remote Control  ·  idle
```
La liste est lue « plus récentes d'abord » sur un nombre borné de pages : si elle se termine par
« session list too long to fetch completely », une cible ancienne peut manquer — la réveiller
depuis claude.ai/l'app suffit à la faire remonter, et archiver les vieilles sessions cloud assainit
la liste. Deux détails observés : le `[ref]` d'une même session **change selon la session qui
liste** (ne jamais le stocker), et dans une session Remote Control la première ligne « This
session is … » peut manquer — le nom du pilote est alors celui passé à `--name` /
`--remote-control` / `/rename`, ou le champ `name` de son `~/.claude/sessions/<pid>.json`.

Pour *lire* une session il faut en plus son **ID claude.ai** `session_01…` (24 caractères après
`session_`), que `ListAgents` n'affiche pas. Quatre sources, de la plus simple à la plus manuelle :

1. **L'en-tête d'un message reçu** : tout message inter-sessions arrive enveloppé dans
   `<cross-session-message from="bridge:session_01…" from-name="workspace" from-mode="prompting">`.
   Le premier contact suffit donc : demander à chaque cible un simple accusé (gabarit « premier
   contact » dans `assets/enveloppe-instruction.md`) et lire l'ID dans le `from`.
2. **La sidebar de claude.ai/code** : chaque session est un lien `/code/session_01…` ; ouvrir la
   session et copier l'URL (l'ID est ce qui suit `/code/`, avant tout `?`).
3. **Le registre local de la machine cible** : `~/.claude/sessions/<pid>.json` contient `name`,
   `bridgeSessionId`, `cwd`, `kind`, `entrypoint`, `version`. `scripts/rc-sessions.sh` le lit
   depuis un shell (machine courante ou `--ssh <hôte>`). Le dossier contient aussi les jetons
   `.key` du socket, et le classificateur du mode auto **bloque** sa lecture par Claude (`cat`,
   puis `ls`+`head`, refusés lors du test) : passer par un shell humain, SSH, ou une règle `allow`
   explicite. Sans `bridgeSessionId`, la session n'est pas en Remote Control.
4. **Demander à la cible de lire son registre** — même réserve qu'en 3 ; préférer 1.

Consigner le résultat dans un petit registre (`assets/registre-sessions.example.json` donne le
format) : nom → ID → machine → cwd → date. Un ID survit aux reconnexions (`claude --continue` rattache
la même session claude.ai) mais pas à un `claude remote-control` neuf ; quand `get_run_log` répond
404 ou que le contenu ne correspond plus, rafraîchir l'entrée.

## Étape 2 — Envoyer une instruction

Une instruction par message, et pas de nouveau message tant que le tour précédent n'est pas fini :
la cible lit les messages **entre deux appels d'outils** pendant un tour, et démarre un nouveau tour
si elle est idle. Un second ordre envoyé en plein travail serait lu au milieu de l'exécution du
premier, et les rafales sont refusées ou mises en file.

Adresser avec le nom exactement tel que `ListAgents` l'imprime ; ajouter le `[ref]` seulement si
deux lignes partagent le nom ou si l'erreur le demande. `SendMessage` peut être différé
(`ToolSearch("select:SendMessage")`) ; suivre le schéma chargé (destinataire, message, et un
`summary` d'une ligne repris dans le résultat). Le résultat ressemble à
`{"success":true,"message":"“<summary>” → workspace (a Claude session on another machine, over
Remote Control; …)","msg_id":"…"}` : il confirme le destinataire et le canal, pas l'exécution, et il
peut mettre ~20 s à revenir. `notify_when_idle` ne fonctionne qu'entre sessions d'une même
machine : à distance, l'accusé de fin doit être demandé explicitement.

Utiliser l'enveloppe d'`assets/enveloppe-instruction.md`. Ses deux ingrédients rendent le retour
détectable sans ambiguïté :
- une **ligne sentinelle unique** en fin de réponse (`FIN <TAG> OK` / `FIN <TAG> ERREUR …`), que
  `get_run_log` retrouve même si le reste du texte est tronqué ;
- un **rappel par `SendMessage` vers la session pilote**, qui réveille celle-ci (un message reçu
  par une session idle démarre un tour) et transporte le résumé complet.

Choisir un `TAG` court et unique par tâche (`T07-tests`, `WS-2026-09-07-1`). Rappeler dans le
message que la tâche est mandatée par l'utilisateur, tout en sachant que la cible la traitera comme
venant d'une session, pas de l'humain : les permissions manquantes bloqueront, pas contourneront.

Le résultat de `SendMessage` (« sent », « delivered ») signifie que le message est parti, rien de
plus. Une cible `offline` ou qui refuse (`crossSessionInbound: refuse`) ne fera rien ; une cible qui
« hold » attend une approbation humaine sur sa machine ou sur claude.ai.

## Étape 3 — Lire le retour

```
RemoteTrigger({action: "get_run_log", session_id: "session_01CtH1M8FKe8jgHp6sVKey6r"})
```
Réponse : un en-tête JSON (`events_fetched`, `events_shown`, `next_cursor`), la liste des
événements de contrôle ignorés, puis les **200 événements les plus récents**, du plus ancien au plus
récent, horodatés en UTC :
```
[2026-09-06T23:13:11Z] user: yes faisons comme polaris stp, fais la repasse
[2026-09-06T23:13:36Z] assistant: [thinking]
[2026-09-06T23:14:04Z] tool_use Bash: {"command":"cd /Users/username/src/… [+6784 chars]
[2026-09-06T23:14:06Z] tool_result: Dnd/Rma config patched …
[2026-09-06T23:15:39Z] tool_result ERROR: Exit code 1 …
[2026-09-06T23:24:56Z] assistant: Repasse terminée, Altair fait maintenant comme polaris. …
[2026-09-06T23:24:56Z] result: success is_error=false turns=29 duration=0s
[2026-09-06T23:55:57Z] system/worker_shutting_down: host_exit
```
Lecture :
- `result:` = **fin de tour**. Le texte final de la cible est le dernier `assistant:` (hors
  `[thinking]`) avant ce `result:`. Vérifier qu'il porte la sentinelle `FIN <TAG>`.
- Aucun `user:` contenant le message envoyé → il n'est pas arrivé (cible offline, message en
  attente d'approbation, refusé, ou liste tronquée). Un message inter-sessions apparaît comme
  `user: <cross-session-message from="bridge:session_01…" from-name="<pilote>"
  from-mode="prompting"> … </cross-session-message>` ; chercher le TAG dans ce bloc.
- `user:` présent, `tool_use`/`tool_result` qui s'ajoutent → **en cours** ; relire plus tard.
- `user:` présent, plus rien depuis plusieurs minutes, pas de `result:` → **bloquée** : permission
  à approuver ou question posée (`AskUserQuestion`) ; seul l'humain répond, depuis claude.ai ou
  l'app mobile. Le dire à l'utilisateur plutôt que d'attendre.
- `tool_result ERROR:` → recopier la cause ; « denied by the Claude Code auto mode classifier »
  ou « Permission … denied » = la tâche dépasse les permissions de la cible.
- `init:` répétés = reconnexions, pas des tours. `system/worker_shutting_down: host_exit` = la
  session s'est arrêtée (`/exit`) ; `ListAgents` la montrera `offline` ou absente.
- Les textes longs sont coupés (`[+N chars]`) : pour un résultat volumineux, demander à la cible de
  l'écrire dans un fichier ou de l'envoyer dans le rappel `SendMessage`.
- `next_cursor` ne pagine que vers le **passé** ; chaque appel renvoie les derniers événements.
  Un appel ≈ 10-40 Ko : espacer les relectures de 30-60 s, pas de boucle serrée.

`get_run_log` fonctionne sur toute session claude.ai du compte (Remote Control, cloud, app
desktop) tant qu'on a son `session_…` ; il reflète les événements de la seconde même.

## Étape 4 — La boucle de pilotage, tour par tour

```
registre ← ListAgents + IDs (étape 1)
pour chaque étape de la tâche :
  1. SendMessage(to: <nom>, message: enveloppe(TAG, instruction, rappel vers <pilote>))
  2. attendre : le rappel réveille la session pilote si elle est idle (il est chez elle au moment
     du `success` de l'émetteur) ; sinon relire get_run_log toutes les 30-60 s
  3. lire : terminé (result + sentinelle) / en cours / bloquée / non délivrée / erreur
  4. décider l'étape suivante à partir du texte final et des erreurs réelles, pas du résumé seul
  5. journal : horodatage, cible, TAG, verdict, une ligne de résultat
```
Pour attendre sans bloquer : `Bash({command: "sleep 45", run_in_background: true})` puis relire à
la notification (un `sleep` en avant-plan est souvent interdit par le harness), ou `/loop` /
`ScheduleWakeup` pour une tâche longue. Fixer un délai maximal par étape et, au-delà, relire une
dernière fois puis informer l'utilisateur de l'état exact plutôt que de renvoyer l'ordre.

**Plusieurs cibles** : un message par session, chacune avec son TAG, puis une relecture par ID ; tenir
le tableau `assets/journal-template.md` (nom, ID, machine, statut, dernier résultat). Ne jamais faire
transiter des ordres d'une cible à une autre (boucles A→B→A, que Claude Code étrangle mais qu'il vaut
mieux ne pas créer) : le pilote reste le seul émetteur.

**Rapport à l'utilisateur** : citer ce que la cible a *fait* (outils, fichiers, erreurs vus dans le
log), pas seulement ce qu'elle *dit* avoir fait ; donner le nom et l'ID de la session pour qu'il
puisse ouvrir la même page sur claude.ai.

## Pièges fréquents (détails et correctifs : `references/depannage.md`)

- Message envoyé, aucun retour → normal ; relire avec `get_run_log`, demander le rappel.
- La cible ne peut pas répondre → la session pilote n'est pas en Remote Control (pas d'adresse de réponse).
- Message jamais reçu → cible `offline`, en attente d'approbation (`hold`), `refuse`, ou liste tronquée.
- `SendMessage` absent → app desktop, ou règle `deny` sur `SendMessage`/`ListAgents`.
- Les outils `ccd_session_mgmt` (`list_sessions`, `list_events`, `send_message`) ne voient que
  l'app desktop locale : inutiles entre machines.
- `get_run_log` → 400 « must be a cse_… or session_… tagged ID » : on a passé le `[ref]` ou l'UUID
  local au lieu de l'ID claude.ai.
- La cible ne peut pas lire `~/.claude/sessions` (classificateur auto) → prendre l'ID dans
  l'en-tête de son message, pas dans son registre.

## Fichiers du skill

- `references/mecanismes-verifies.md` — ce qui a été testé, avec les sorties réelles et les versions.
- `references/depannage.md` — symptômes → causes → correctifs, y compris les bugs corrigés par version.
- `scripts/rc-sessions.sh` — nom ↔ `bridgeSessionId` depuis `~/.claude/sessions`, local ou via SSH.
- `assets/enveloppe-instruction.md` — gabarit du message d'instruction (sentinelle + rappel).
- `assets/journal-template.md`, `assets/registre-sessions.example.json` — suivi multi-sessions.
