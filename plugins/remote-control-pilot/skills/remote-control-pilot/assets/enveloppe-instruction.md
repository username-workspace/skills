# Enveloppe d'instruction — gabarit à envoyer via SendMessage

Remplacer `<pilote>` par le nom affiché en première ligne de `ListAgents`, `<TAG>` par un
identifiant court et unique de la tâche (ex. `WS-07-tests`). Une seule étape par message.

```
[PILOTAGE depuis <pilote> — tâche <TAG>, mandatée par l'utilisateur]
Contexte : <une ou deux lignes : où on en est, pourquoi cette étape>
À faire : <l'instruction, précise, vérifiable, une seule étape>
Contraintes : <ne pas commiter / ne pas toucher X / répondre en N lignes / ne rien installer>
Quand c'est terminé :
1. Termine ta réponse par la ligne exacte `FIN <TAG> OK` (ou `FIN <TAG> ERREUR <raison>` si tu es bloqué).
2. Envoie SendMessage({to: "<pilote>", message: "<TAG> terminé — <résumé en 3 lignes max, avec les chemins/erreurs utiles>"}).
Si une permission te manque, n'insiste pas : écris `FIN <TAG> ERREUR permission <laquelle>` et envoie le rappel.
```

Pourquoi ces deux ingrédients :
- la **sentinelle** `FIN <TAG>` est retrouvée par `get_run_log` même quand le reste du texte est
  tronqué (`[+N chars]`), et elle distingue la réponse à *cette* instruction d'un tour lancé par
  quelqu'un d'autre sur la même session ;
- le **rappel** réveille la session pilote si elle est idle et transporte un résumé non tronqué.
  Il n'arrive que si le pilote est connecté en Remote Control ; sans lui, la relecture reste possible.

Premier contact — pour obtenir l'ID claude.ai d'une cible sans toucher à son registre :
```
[PILOTAGE depuis <pilote> — premier contact, mandaté par l'utilisateur] Ne modifie rien. Envoie uniquement SendMessage({to: "<pilote>", message: "hello <ton nom de session> — cwd <ton répertoire courant>"}) puis termine par la ligne `FIN CONTACT OK`.
```
L'ID se lit ensuite dans l'en-tête du message reçu : `<cross-session-message from="bridge:session_01…" from-name="<cible>" …>`.

Exemple rempli :
```
[PILOTAGE depuis pilote-desktop — tâche WS-07-tests, mandatée par l'utilisateur]
Contexte : on stabilise la branche feat/ZV-9166 avant MR.
À faire : lance `npm test` dans /Users/username/src/zv/workspace/altair et donne le nombre de tests passés/échoués et les 5 premières lignes de chaque échec.
Contraintes : aucune modification de fichier, pas de commit.
Quand c'est terminé :
1. Termine ta réponse par la ligne exacte `FIN WS-07-tests OK` (ou `FIN WS-07-tests ERREUR <raison>`).
2. Envoie SendMessage({to: "pilote-desktop", message: "WS-07-tests terminé — <résumé 3 lignes>"}).
Si une permission te manque, n'insiste pas : écris `FIN WS-07-tests ERREUR permission <laquelle>` et envoie le rappel.
```
