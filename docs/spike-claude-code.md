# Spike — hypothèses Claude Code (phase 1)

*Réalisé le 2026-10-12 avec Claude Code 2.1.295 sous Windows 11, `pwsh` 7.6.6. Banc d'essai jetable, sessions headless (`claude -p --output-format stream-json --include-hook-events`), hooks de journalisation et de garde en PowerShell. Coût total des sessions de test : environ 0,35 $.*

## Résultats

| # | Question | Réponse vérifiée | Conséquence pour le harness |
|---|---|---|---|
| 1 | L'entrée des hooks contient-elle `agent_type` dans un subagent ? | ✅ **Oui.** `agent_type` et `agent_id` sont présents dans tous les hooks déclenchés par un subagent (`PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`), et absents dans la session principale | `git-guard` fonctionne comme prévu. **Testé :** un `echo commit` lancé depuis la session principale est refusé, le même lancé par l'agent autorisé passe |
| 2 | Que voit-on du paramètre `model` lors d'un appel à `Agent` ? | `tool_input` contient `description`, `prompt`, `subagent_type`, `run_in_background`, et **`model` seulement s'il est passé**. **Un `model` passé à l'appel écrase le modèle déclaré par l'agent** : `probe-haiku` appelé avec `model: "sonnet"` a tourné en Sonnet | `model-guard` refuse tout appel `Agent` qui contient `model`. **Testé :** le refus est bien appliqué |
| 3 | `CLAUDE_CODE_SUBAGENT_MODEL` écrase-t-il le modèle d'un agent, ou `inherit` ? | ❌ **Non.** Un agent en `model: sonnet` reste en Sonnet, un agent en `inherit` prend le modèle de la session. La variable ne s'applique **qu'aux agents sans modèle déclaré** : `general-purpose` est passé en Haiku | On la garde comme **filet de sécurité**, sans risque pour la table des modèles |
| 4 | Une session ouverte dans `services/<app>/` charge-t-elle le `CLAUDE.md` parent ? | ✅ **Oui, il est chargé.** Le réglage **`claudeMdExcludes`** l'exclut : avec `["**/spike/CLAUDE.md"]`, le mot de contrôle du parent a disparu | Le `settings.json` de chaque projet exclut les fichiers d'instructions de la racine `services` |
| 5 | Un `@import` dans `AGENTS.md` fonctionne-t-il, sur plusieurs niveaux ? | ✅ **Oui.** `CLAUDE.md` → `@AGENTS.md` → `@.harness/agents/core.md` → `@level2.md` : les 4 niveaux sont chargés. Le chemin d'un import est relatif au fichier qui le contient. **Les subagents reçoivent aussi ces instructions** | Le découpage `AGENTS.md` + `.harness/agents/*.md` fonctionne. Les conventions s'appliquent aussi aux subagents |
| 5 bis | *(découverte)* `AGENTS.md` est-il lu sans `CLAUDE.md` ? | ✅ **Oui, nativement.** Le plugin intégré `cc-plugin-agents-md` charge `AGENTS.md`, imports compris, **quand le projet n'a pas de `CLAUDE.md`**. Son option `instructionFiles` règle ce comportement | On garde `CLAUDE.md` = `@AGENTS.md`, explicite et indépendant de ce plugin. Mais même sans lui, `AGENTS.md` serait lu : la résilience recherchée est déjà là |
| 6 | Les plugins déclarés dans le `settings.json` du projet s'installent-ils d'eux-mêmes ? | ❌ **Non**, pas en mode headless : `enabledPlugins` seul ne suffit pas, le plugin n'est pas chargé. ✅ **`claude plugin install <plugin> --scope project`** l'installe, l'ajoute à `enabledPlugins`, et il se charge ensuite | Les plugins du harness sont installés **par script** : `new-project.ps1`, `harness-doctor -Fix`, et `pull-all.ps1` sur un nouveau poste |
| 7 | Quelle est la latence d'un hook `pwsh` ? | Démarrage seul : **~220 ms** (médiane sur 10). Avec lecture du JSON et écriture d'un fichier : ~280 ms. À comparer : Windows PowerShell 5.1 ~120 ms, Node.js ~35 ms, plancher `cmd` ~10 ms | Voir « Latence » ci-dessous |
| 8 | Les hooks de ponytail, de codegraph et les nôtres cohabitent-ils ? | ✅ **Oui.** Le hook global `UserPromptSubmit` de codegraph, les hooks Node.js de ponytail et les nôtres se déclenchent tous, sans aucune erreur | Rien à adapter. Leurs latences s'additionnent : ponytail aussi a un coût |

## Constats supplémentaires

- **Plusieurs hooks d'un même événement tournent en parallèle.** Deux de nos hooks écrivaient dans le même fichier de journal : une ligne a été entrelacée et corrompue. → **Un seul dispatcher par événement**, et toute écriture partagée passe par un verrou ou un fichier par processus.
- **Un hook doit forcer l'UTF-8 en entrée.** Sans `[Console]::InputEncoding = [Text.Encoding]::UTF8`, `pwsh` lit le JSON envoyé par Claude Code avec la page de code de la console, et les accents sont corrompus. Même chose en sortie avec `[Console]::OutputEncoding`.
- **Le format de refus fonctionne** : un JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}` sur la sortie standard, avec le code de sortie 0. L'agent reçoit la raison et ne réessaie pas.
- **L'outil s'appelle `Agent`** dans l'entrée des hooks, c'est le nom à utiliser dans les `matcher`.
- **Le CLI `claude` a sa propre connexion**, indépendante de l'app desktop. Elle peut expirer : `claude`, puis `/login`. → À vérifier par le doctor.

## Latence : la stratégie retenue

Un hook `pwsh` coûte ~250 ms par déclenchement. Sur `PreToolUse` et `PostToolUse` pour tous les outils, une tâche de 100 appels perdrait près d'une minute. Trois mesures, par ordre d'application :

1. **Des matchers ciblés**, pour ne déclencher les hooks que sur les outils concernés :
   - `PreToolUse` sur `Agent|Bash|PowerShell|Read|Edit|Write` ;
   - `PostToolUse` sur `Edit|Write` seulement ;
   - `Stop` une fois par tour.

   Les lectures (`Glob`, `Grep`, `codegraph`) ne déclenchent rien.
2. **Un seul dispatcher par événement**, qui enchaîne toutes les règles dans le même processus.
3. **Si la gêne est réelle à l'usage**, compiler le dispatcher en exécutable .NET natif (AOT) : on vise alors quelques dizaines de ms. On ne le fait pas d'emblée : on mesure d'abord, en phase 2.

## Banc d'essai

Le banc reste dans le scratchpad de la session et n'est pas versionné. Il contenait :
- trois niveaux d'instructions avec des mots de contrôle ;
- des agents de test `probe-haiku`, `probe-sonnet`, `probe-inherit` et `probe-gitops` ;
- un hook de journalisation et un hook de garde (`model-guard` et `git-guard` simulés) ;
- 5 sessions headless, chacune vérifiée sur le modèle réellement utilisé, lu dans les transcripts des subagents.
