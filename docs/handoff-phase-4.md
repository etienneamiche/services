# Passage de relais — début de la phase 4

*Écrit le 2026-10-14, à la fin d'une longue session, pour reprendre dans une session neuve sans perte de contexte. À lire en entier avant toute action. Les sources de vérité restent [`cadrage.md`](cadrage.md), [`ROADMAP.md`](ROADMAP.md) et le dépôt [`harness`](https://github.com/etienneamiche/harness).*

## 1. Où on en est

**Phases 0 à 3 terminées** (voir les bilans dans `ROADMAP.md`). Doctor de l'écosystème : 0 échec, 0 avertissement (`./scripts/harness-doctor.ps1`).

| Dépôt (sous `C:\repo\services\`) | Visibilité | État |
|---|---|---|
| `services` (racine) | public | `.gitignore` en liste blanche, `STARTUP.md`, `scripts/` (setup-workstation, pull-all, harness-doctor, add-workstation-key), `docs/` |
| `homelab` | privé | doc homelab dans `docs/` (doc 07 à jour : DbUp, exposition `internal`, volume) ; rien d'autre encore |
| `harness` | public | **v0.2.0** : cœur + modules `react`, `dotnet`, `python`, `game`, 8+1 subagents, 10 règles de hooks, `merge-pr.ps1`, doctor, 131 autotests (`tools/test.ps1`) |
| `harness-sandbox` | public | harness v0.2.0 (modules react, dotnet, game) sur la branche `chore/harness-v0.2.0`, **PR [#1](https://github.com/etienneamiche/harness-sandbox/pull/1) ouverte vers `develop`, volontairement non fusionnée** |
| `harness-pro` | privé | ancien essai renommé par l'utilisateur, ne pas toucher |

Issues ouvertes sur `harness` :
- [#2](https://github.com/etienneamiche/harness/issues/2) : 4 contournements mineurs de `git-guard` (`-R` collé, `--attr-source`, `GET` cité, `|` dans `--jq`) ;
- [#3](https://github.com/etienneamiche/harness/issues/3) : `copier update` exige `--answers-file .copier-answers.harness.yml` ; `manifest.json` sort toujours en conflit → le régénérer (`.harness/tools/write-manifest.ps1`), ne pas le fusionner.

## 2. Ce qui a été décidé pour la phase 4

**Méthode** : chaque skill est construit avec le skill **`/anthropic-skills:skill-creator`** (brouillon → cas de test → exécutions avec et sans skill → visionneuse de revue → itérations). **Un skill = une PR** sur `harness` (leçon de la phase 3 : une PR de 2 000 lignes a demandé six revues `auditor`). Les skills vivent dans `template/.claude/skills/<nom>/SKILL.md` du dépôt `harness` (protégés par `config-protection` dans les projets) ; l'espace de travail du skill-creator va dans `harness/.test/` (ignoré par Git).

**Ordre retenu** (l'utilisateur a validé : « on commence par le 1 ») :

| # | Skill | Où | Remarque |
|---|---|---|---|
| 1 | **`/audit-pr`** | projets | **À faire maintenant.** Premier cas réel : harness-sandbox#1 |
| 2 | `/ship` | projets | commit + PR par `git-ops` |
| 3 | `/review`, `/lint` | projets | Haiku |
| 4 | `/feature` | projets | enchaîne les précédents |
| 5 | `/idea`, `/spec` | projets | issue + Project |
| 6 | `/release`, `/retro`, `/doctor` | projets | |
| + | **`/help-harness`** | projets et racine | **demandé par l'utilisateur** : l'expert du système (harness, hooks, modules, versions, mises à jour, doctor), avec une connaissance approfondie de son fonctionnement |
| + | **`/homelab`** | racine `services` | **demandé par l'utilisateur** : connaît parfaitement l'infra, le réseau, la roadmap et les problématiques du homelab (source : `homelab/docs/`) |
| + | **`/start-project`** | racine `services` | **précisé par l'utilisateur** : lance une phase de spécification, sait quel template utiliser, propose une architecture cohérente, crée la roadmap (cadrage §9, agent `architect`, catalogue §5) |

**Deux questions restées sans réponse explicite** (l'utilisateur a seulement répondu « on commence par le 1 ») — à reconfirmer en une ligne avant de lancer les tests :
1. **Tests sans effets de bord** : recommandation **a) mode essai** — pendant les évaluations, le skill écrit dans un fichier ce qu'il aurait publié (commentaire, PR, issue) au lieu d'agir sur GitHub ; le vrai geste se fait une seule fois à la fin (pour `/audit-pr` : sur harness-sandbox#1). Alternative b) : vraies PR jetables sur `harness-sandbox`.
2. **Rigueur** : recommandation **boucle complète** (2-3 cas, comparaison chiffrée, visionneuse, optimisation de la description) pour `/audit-pr`, `/ship`, `/feature` ; **allégée** pour les autres.

**Autres livrables de la phase 4** (ROADMAP) : GitHub Project unique + labels (`feature`, `bug`, `harness-update`, `infra`, `integration`, `from-users`) + modèles d'issue/PR ; *rulesets* GitHub imposant la PR sur `main` de `harness`, des templates et de `libs` ; dépôt **`project-ideas` (privé)** ; traiter harness#2 et #3. Critère de sortie : trois issues fictives menées de `Idée` à `Fait` dans `harness-sandbox`.

## 3. `/audit-pr` : ce qui est déjà défini (à faire valider avant d'écrire)

- **Déclencheur** : « audite la PR », « revue avant fusion », avant tout `merge-pr.ps1`, ou quand `merge-pr.ps1` refuse faute de revue.
- **Exécutant** : le subagent **`auditor`** (Opus, `template/.claude/agents/auditor.md`), la session principale l'appelle sans paramètre `model`.
- **Ce qu'il vérifie**, sur la PR entière (`gh pr diff`, `gh pr view`) : correction, sécurité, migrations compatibles avec la version précédente, conventions (`AGENTS.md`, modules) et `ARCHITECTURE.md`, tests, critères d'acceptation de l'issue liée.
- **Sortie** : un commentaire publié par `gh pr comment <n> --body-file <fichier>` (seul `auditor` a le droit d'écrire le marqueur : règle `git-guard` §2 bis), avec résumé, constats **Bloquant / Important / Mineur** (`fichier:ligne`), puis **en dernière ligne** `<!-- auditor: sha=<SHA complet du dernier commit> verdict=approve|changes -->`. `approve` seulement sans bloquant ni important.
- **Après** : si `approve`, `git-ops` fusionne par `pwsh -NoProfile -File .harness/tools/merge-pr.ps1 -Pr <n> -Subject "type(scope): … (#n)"` (squash, anglais) ou `-Strategy merge` (release/hotfix). `merge-pr.ps1` ne compte que les marqueurs posés par le compte `gh` courant et ne fusionne que le commit revu (`--match-head-commit`).
- **Inspiration concrète** : les six revues de la PR harness #1 (rapports dans `harness/.test/audit-pr-1*.md`) — format, profondeur, essais du vrai hook, `tools/test.ps1`. Une revue après corrections doit vérifier les régressions introduites par les corrections (c'est là qu'on en a trouvé le plus).

## 4. Décisions structurantes à ne pas perdre (détail : cadrage, harness)

- **Modèles** : session principale, `dev`, `architect`, `auditor`, `/retro` en **Opus** ; `explorer`, `linter`, `git-ops`, `reviewer`, `cartographer`, `db-ops` en **Haiku** ; Sonnet n'a pas de rôle. `model-guard` refuse tout paramètre `model` et tout agent hors liste blanche.
- **Git** : toute écriture Git/GitHub par `git-ops` ; commits en anglais (Conventional Commits + `(#n)`) ; PR, issues et docs en français ; branches simples, pas de worktree ; squash pour les features ; **fusion uniquement par `merge-pr.ps1`** après `/audit-pr`.
- **`homelab`** : on ne fusionne jamais sans l'utilisateur (fusionner = déployer) ; PR même pour la doc.
- **Secrets** : SOPS + age, jamais lus par un agent ; `secret-new.ps1` / `secret-set.ps1` (phase 6) ; copie de secours hors ligne de la clé age.
- **Stacks** : React (TanStack Router/Query, Orval `*.queries.ts`, Biome, PascalCase), .NET (Controller → Service → Dal/Clients, database-first + DbUp, immuabilité, FluentValidation, Refit, `ICurrentUser`, permissions, impersonation), Python (petits modules, jobs longs, pas de Postgres), jeu (serveur qui fait autorité, sauvegardes). Résumé : cadrage §21.

## 5. Pièges techniques rencontrés (gain de temps assuré)

- **PATH** : après une installation, `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')` dans chaque appel PowerShell.
- **Méthodes .NET (`[IO.File]::…`)** : chemins relatifs résolus depuis le dossier du **processus**, pas de PowerShell → toujours des chemins absolus.
- **Garde-fou de l'outil PowerShell** : un texte contenant `Remove-Item` (même dans une chaîne ou un here-string) peut être bloqué ; passer par un fichier écrit avec l'outil Write, ou `[IO.File]::Delete`.
- **PowerShell est insensible à la casse** : une variable `$pr` écrase le paramètre `$Pr`.
- **Here-string** : pas de saut de ligne final → attention aux concaténations.
- **Pester 6** : `BeforeEach` interdit à la racine d'un fichier ; un fichier de tests qui ne s'exécute pas ne compte aucun échec (le doctor le détecte désormais).
- **Sessions Claude headless** (`claude -p`) depuis cette session : retirer d'abord les variables `CLAUDE*`/`ANTHROPIC*` (`[Environment]::SetEnvironmentVariable($n, $null)`) ; le CLI a sa propre connexion (`claude` puis `/login` si expirée).
- **Copier** : `--answers-file .copier-answers.harness.yml` pour `update` ; `--trust` ; `PYTHONUTF8=1` pour des messages lisibles ; `HARNESS_SKIP_PLUGINS=1` pour les projets jetables.
- **Tests du harness** : `harness/tools/test.ps1` (scénarios `sandbox`, `python`, `root`, `invalid`, `invalid2`) ; projet conservé avec `-Keep`.

## 6. Première action de la nouvelle session

1. Lire ce fichier, puis survoler `ROADMAP.md` (phase 4) et `harness/template/.claude/agents/auditor.md`.
2. Reposer en une ligne les deux questions du §2 (mode essai, rigueur) si l'utilisateur ne les a pas tranchées.
3. Lancer `/anthropic-skills:skill-creator` pour **`/audit-pr`** : présenter la capture d'intention du §3 pour validation, **avant d'écrire le skill**.
