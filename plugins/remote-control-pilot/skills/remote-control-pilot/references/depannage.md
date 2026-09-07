# Dépannage — pilotage de sessions Remote Control

| Symptôme | Cause probable | Correctif |
|---|---|---|
| Le message part (« sent ») mais rien ne revient | `SendMessage` n'attend jamais de réponse | Relire la cible avec `RemoteTrigger get_run_log` ; demander un rappel `SendMessage` vers le pilote dans l'enveloppe |
| La cible a répondu dans son terminal mais « ne peut pas m'écrire » | Pilote non connecté en Remote Control → message sans adresse de réponse | `/rc` (ou `claude --remote-control`) dans la session pilote avant d'envoyer |
| Aucun `user:` avec mon message dans `get_run_log` | Cible `offline` ; message en attente (`hold`) puis expiré (5 min) ; `crossSessionInbound: refuse` ; nom absent des premières pages | `ListAgents` pour le statut ; approuver sur la machine cible ou mettre `crossSessionInbound: "accept"` ; réveiller la cible depuis claude.ai pour la remonter dans la liste |
| Cible en `bypassPermissions` qui ignore mes messages | Règle par défaut : elle met en attente ce qui vient d'un émetteur non-bypass | `"crossSessionInbound": "accept"` dans ses settings utilisateur, ou même classe de permissions des deux côtés |
| `user:` présent, puis plus rien, pas de `result:` | Invite de permission ou `AskUserQuestion` en attente — seul l'humain peut répondre | Ouvrir la session sur claude.ai / l'app mobile, approuver ; pour l'avenir, élargir les règles `allow` ou le mode de permission de la cible |
| `tool_result ERROR: … denied by the Claude Code auto mode classifier` | La tâche dépasse ce que le mode auto de la cible autorise | Reformuler en action moins invasive, ou faire ajouter une règle `allow` par l'utilisateur ; ne pas insister |
| `No such tool available: SendMessage … disabled for this session` | Session de l'app desktop (ou règle `deny`) | Piloter depuis un terminal ; depuis le desktop, se limiter à `ListAgents` + `get_run_log` |
| `ListAgents` ne montre aucune session d'autre machine | Pilote sans Remote Control ; clé API / Bedrock / Vertex / Foundry ; `ANTHROPIC_BASE_URL` détourné | Connexion claude.ai + `/rc` ; retirer la variable |
| « Remote Control is not connected » depuis une session `claude remote-control` | Bug corrigé en 2.1.251 | `claude update` sur la cible |
| Message vers une cible hors ligne lu comme « delivered » | Bug corrigé en 2.1.248 | mettre à jour ; vérifier le statut avec `ListAgents` avant d'envoyer |
| `ListAgents` : « session list too long to fetch completely » | Trop de sessions cloud/RC récentes | Archiver les vieilles sessions sur claude.ai/code ; garder les cibles actives |
| `get_run_log` → HTTP 400 « must be a cse_… or session_… tagged ID » | `[ref]`, UUID local ou ID tronqué passé en `session_id` | Utiliser le `bridgeSessionId` complet (`session_` + 24 caractères) |
| `get_run_log` → 404 / contenu d'une autre conversation | La session a été recréée (`claude remote-control` neuf) | Rafraîchir le registre (script, URL claude.ai ou demander à la cible) |
| Deux sessions au même nom | Renommage sans `/rename` sur l'autre, ou versions différentes | Adresser `nom [ref]` ; renommer l'une des deux |
| `Too many messages to this session just now` | Rafale vers une même cible | Regrouper en un seul message ; attendre le `result:` avant le suivant |
| `Message too large for cross-session delivery` | Message > ~1 M caractères | Écrire le contenu dans un fichier partagé et n'envoyer que le chemin |
| La cible a traité mon ordre comme une suggestion, pas comme un mandat | Elle sait que le message vient d'une session, pas de l'utilisateur | Le dire dans l'enveloppe (« mandaté par l'utilisateur ») ; accepter qu'elle refuse ce que ses permissions interdisent |
| `SendMessage` refusé : « target is the current session » | Adresse = nom du pilote lui-même | Vérifier la première ligne de `ListAgents` |
| Outils `ccd_session_mgmt` (`list_sessions`, `list_events`, `send_message`) vides | Portée = sessions de la même app desktop | Ne pas s'en servir entre machines |
| Sandbox/WSL : sessions de la même machine invisibles entre elles | Systèmes de fichiers / sockets différents | Elles se joignent alors comme des machines distinctes, via Remote Control |
| La cible ne peut pas lire `~/.claude/sessions/*.json` (« denied by the Claude Code auto mode classifier ») | Le dossier contient les jetons `.key` du socket ; le classificateur le protège | Prendre l'ID dans l'en-tête `<cross-session-message from="bridge:session_…">` de son message ; ou lire le registre depuis un shell humain / SSH ; règle `allow` explicite si vraiment nécessaire |
| Le `[ref]` noté hier ne correspond plus | Le `[ref]` est calculé par la session qui liste, différent d'une session à l'autre | N'utiliser le `[ref]` que dans l'appel `SendMessage` du moment ; stocker le nom et l'ID `session_…` |
| `ListAgents` sans première ligne « This session is … » | Nom non attribuable à l'utilisateur dans une session Remote Control | Le nom est celui donné par `--name` / `--remote-control` / `/rename`, ou le champ `name` de `~/.claude/sessions/<pid>.json` |
| `SendMessage` introuvable alors qu'on est dans un terminal | Outil différé | `ToolSearch("select:SendMessage")` puis appeler |
| `success:true` reçu, mais 20 s après l'appel | Aller-retour serveur de la livraison inter-machines | Normal ; ne pas renvoyer |
