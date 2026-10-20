# Roadmap — construction de l'écosystème `services`

*Créée le 2026-10-11. Référence : [`cadrage.md`](cadrage.md).*

## Règles de conduite

- **Une phase à la fois.** On ne commence une phase que lorsque le **critère de sortie** de la précédente est atteint.
- **Chaque phase se termine de la même façon :**
  1. passage du doctor (dès qu'il existe, en phase 2) ;
  2. une courte rétro : ce qui a coincé, ce qui change dans le cadrage ;
  3. mise à jour de `cadrage.md` ;
  4. ta validation.
- **On teste sur du jetable avant le réel.** Un dépôt `harness-sandbox` sert de terrain d'essai jusqu'à la phase 5.
- **La CI/CD vient à la fin** (phase 10). Avant, tout se vérifie en local, par scripts et par Pester.
- **Les dépendances à la plateforme k3s** (déploiement, `feedback`, `services-map`) sont regroupées en phase 11. Elles attendent **H1**, la plateforme du homelab (voir « Piste homelab » plus bas).

| Phase | Thème | Dépend de |
|---|---|---|
| 0 ✅ | Poste, racine, `STARTUP.md` | — |
| 1 ✅ | Spike : valider les hypothèses Claude Code | 0 |
| 2 ✅ | Harness cœur, hooks, doctor | 1 |
| 3 ✅ | Conventions de code | 2 |
| 4 | Process de travail : issues, Project, skills | 2, 3 |
| 5 | `template-react`, `libs/ui`, thèmes, *playground* | 4 |
| 6 | `template-dotnet`, `template-python`, secrets de dev | 5 |
| 7 | `template-game-multi` | 6 |
| 8 | Mises à jour et propagation | 6 |
| 9 | Harness racine, architecte, `/start-project`, `/evolve`, `/integrate` | 8 |
| 10 | CI/CD | 9 |
| 11 | Ce qui dépend de la plateforme k3s | 10 + H1 |

---

## Phase 0 — Poste, racine et `STARTUP.md` ✅

**Objectif.** Pouvoir reconstruire l'environnement de travail sur n'importe quel poste Windows, pour toi ou pour un autre dev.

**Livrables**
- **`STARTUP.md`** à la racine de `services`, de zéro jusqu'au premier `doctor` vert :
  1. prérequis manuels : Windows 11, `winget`, un compte GitHub ;
  2. installation de `git` et de `pwsh` 7 (deux commandes `winget`) ;
  3. `git clone` de `services` ;
  4. `scripts/setup-workstation.ps1` ;
  5. connexion à `gh`, à faire toi-même (`gh auth login`) ;
  6. `pull-all.ps1` ;
  7. pour l'accès aux secrets : clé age du poste, puis `add-workstation-key.ps1`, lancé **depuis un poste qui a déjà accès** ;
  8. vérification finale.
- **`scripts/setup-workstation.ps1`**, **idempotent** (on peut le relancer sans risque), avec deux profils :
  - `-Role dev` : outils de développement (`gh`, `uv`, `copier`, `gitleaks`, `codegraph`, `node`, `dotnet`, `docker`, `git-cliff`, Claude Code), **sans accès à l'infra** ;
  - `-Role admin` : `dev` + `sops`, `age`, `kubectl`, `tofu`, Ansible (dans WSL Ubuntu, installé par `uv` sans `sudo`), génération de la clé age du poste.
- `services` initialisé en dépôt Git, avec le `.gitignore` en liste blanche.
- `repos.yaml` : `services` et `homelab` actifs, les autres dépôts en `planned`.
- `scripts/pull-all.ps1`.
- Dépôt **`homelab`** (privé) créé, `homelab-doc/` déplacé dans `homelab/docs/`.

**Tests et critère de sortie**
- `setup-workstation.ps1` lancé deux fois de suite : la seconde exécution ne change rien et ne casse rien.
- `setup-workstation.ps1 -Check -Role admin` ne contient plus aucun `FAIL` sur le poste principal.
- Après un commit dans `services`, `git status` ne montre aucun fichier des sous-dépôts.
- `pull-all.ps1` clone `homelab` dans un dossier vide et signale correctement un dépôt modifié.

**Décisions :** Ansible tourne dans WSL Ubuntu. Le profil `admin` est réservé au propriétaire, qui seul accède à `homelab` et aux secrets.

---

## Phase 1 — Spike : valider les hypothèses Claude Code ✅

**Objectif.** Vérifier, avant d'écrire le harness, tout ce que le cadrage suppose sur Claude Code.

**Livrables**
- Un hook de journalisation qui écrit le JSON brut de chaque événement.
- [`docs/spike-claude-code.md`](spike-claude-code.md), avec une réponse vérifiée à chaque question :
  1. L'entrée des hooks contient-elle `agent_type` dans un subagent ? (C'est la base de `git-guard`.)
  2. Que voit-on du paramètre `model` lors d'un appel à l'outil `Agent` ?
  3. `CLAUDE_CODE_SUBAGENT_MODEL` écrase-t-il le modèle déclaré par un agent, ou `inherit` ?
  4. Une session ouverte dans `services/<app>/` charge-t-elle aussi le `CLAUDE.md` parent ? Comment l'éviter ?
  5. Un `@import` dans `AGENTS.md` fonctionne-t-il, et sur plusieurs niveaux ?
  6. Les plugins déclarés dans le `settings.json` du projet (ponytail, LSP) s'installent-ils d'eux-mêmes ?
  7. Quelle est la **latence d'un hook `pwsh`** ? Faut-il un dispatcher unique, ou garder un processus résident ?
  8. Les hooks de ponytail, le hook global de codegraph et les nôtres cohabitent-ils sans conflit ?

**Critère de sortie.** Les 8 questions ont une réponse vérifiée, et le cadrage est corrigé en conséquence.

---

## Phase 2 — Harness cœur, hooks et doctor ✅

**Objectif.** Un harness installable, sans techno, dont chaque garde est testée.

**Livrables**
- Dépôt `harness` (template Copier) : `copier.yml`, le cœur, le **système de modules** (`module.json`), `manifest.json`.
- `AGENTS.md` et `CLAUDE.md` du projet, avec les imports de `.harness/agents/core.md`.
- Les subagents : `dev`, `architect` et `auditor` (Opus) ; `explorer`, `linter`, `git-ops`, `reviewer` et `cartographer` (Haiku).
- Les dispatchers PowerShell et toutes les règles de hooks (cadrage §6), avec les profils `minimal / standard / strict`.
- La protection des secrets (cadrage §17) : permissions `deny`, `secret-guard`, hook Git `pre-commit` + gitleaks, `.gitignore`.
- **La suite Pester** des autotests de hooks.
- **`harness-doctor.ps1`**, niveaux poste, racine et dépôt, plus `-Deep`.
- Dépôt `harness-sandbox`, généré par Copier.

**Tests et critère de sortie**
- Pester entièrement vert.
- **Un scénario manuel joué dans `harness-sandbox`**, chaque ligne vérifiée :

  | Essai | Résultat attendu |
  |---|---|
  | Commit depuis la session principale | Refusé |
  | Appel d'un subagent `general-purpose` | Refusé |
  | `git worktree add` | Refusé |
  | Lecture de `.env` par `Read`, puis par `Get-Content` | Refusée dans les deux cas |
  | Modification de `.eslintrc` | Bloquée |
  | Commit d'un faux secret | Bloqué par gitleaks |
  | `--no-verify` | Refusé |
- Le doctor est vert sur le poste, la racine et le sandbox.
- Release `harness` **v0.1.0**.

**Bilan (2026-10-14)**
- **`harness` v0.1.1 publié** ([dépôt](https://github.com/etienneamiche/harness)) et installé dans `harness-sandbox` : doctor à 0 échec, 0 avertissement.
- **Autotests Pester** : 88 tests verts (83 pour `kind=root`, où les 5 tests propres au gitflow sont ignorés). `tools/test.ps1` génère chaque type de projet, lance le doctor `-Deep` et fait le premier commit.
- **Scénario manuel** joué par une vraie session Claude headless : les 7 essais du tableau sont refusés comme prévu, et le commit légitime de `git-ops` passe.
- **Doctor racine** (`scripts/harness-doctor.ps1`) : poste, racine et dépôts au vert. **`add-workstation-key.ps1`** testé avec un vrai chiffrement SOPS : ajout, déchiffrement, retrait avec rotation de la clé de données, refus de retirer la dernière clé.
- **Problèmes trouvés et corrigés en route** :
  - le premier commit était refusé par gitleaks, qui prenait les empreintes du manifeste pour des clés : d'où la v0.1.1 ;
  - un faux positif de `git-guard` sur `git commit -F -` avec heredoc ;
  - le motif `path_regex` de sops ne reconnaissait pas les chemins Windows ;
  - au retrait d'une clé, `sops rotate` seul gardait l'accès du poste retiré ;
  - la latence (~390 ms par hook) a conduit à ne plus brancher les hooks sur `Read`.

---

## Phase 3 — Conventions de code ✅

**Objectif.** Fixer les pratiques communes et celles de chaque stack, avant d'écrire les templates. C'est la question reportée lors du cadrage.

**Déroulé.** Une session de travail par thème. Chaque décision est notée comme un ADR, puis traduite en `conventions.md` du module et en config d'outillage.

| Session | Sujets |
|---|---|
| **Commun** | Nommage, structure d'un monorepo, taille d'une PR, messages de commit, doc (`ARCHITECTURE.md`, ADR), stratégie de test (pyramide, seuils), logs et observabilité, gestion des erreurs, i18n, accessibilité |
| **React** | Vite, organisation des dossiers, routage, état, récupération des données, formulaires et validation, lint et format (ESLint + Prettier, ou Biome), tests (Vitest, Testing Library, Playwright), usage de shadcn et de `@marblestudio/ui` |
| **.NET** | Style d'architecture (Minimal API, vertical slices…), EF Core et migrations, validation, gestion des erreurs (ProblemDetails), logs, analyseurs et `.editorconfig`, tests (xUnit, Testcontainers), `Directory.Build.props` |
| **Python** | Framework (FastAPI ?), uv, ruff, typage (pyright), pytest, structure |
| **Jeu multi** | Boucle de jeu, protocole de messages, autorité du serveur, tests |

**Critère de sortie.** Les modules `core`, `react`, `dotnet` et `python` du harness contiennent leurs conventions et leurs configs de lint et de format. Release **v0.2.0**.

**Bilan (2026-10-14)**
- **5 sessions tenues** (commun, React, .NET, Python, jeu multi). Les décisions sont dans le harness (`conventions.md` et `.harness/modules/<stack>/`) ; le cadrage §21 en résume la portée.
- **Système de modules** livré : `react`, `dotnet`, `python` et `game`. Les conventions des modules choisis sont importées par `core.md` ; une session Claude a confirmé qu'elle les charge.
- **Ajouts imprévus au départ** :
  - le subagent `db-ops` (Haiku) pour le database-first ;
  - deux skills adaptés de dotnet/skills ;
  - le module `game` ;
  - les plugins LSP par module.
- **Décisions qui débordent du harness** :
  - la config de prod vit dans `homelab` ;
  - les secrets de dev locaux aussi, dans `homelab/secrets/dev/` ;
  - pas de coffre-fort hébergé ;
  - le Job de migration DbUp remplace le bundle EF du doc 07 ;
  - l'exposition `internal` et le volume persistant s'ajoutent au chart.
- **[PR harness #1](https://github.com/etienneamiche/harness/pull/1)** fusionnée et **v0.2.0 taguée**, après **six passages de revue `auditor`** (16 constats importants corrigés au total, dont un contournement de la revue obligatoire). Le principal changement de conception est que **toute fusion passe par `.harness/tools/merge-pr.ps1`**, qui ne fusionne que le commit revu. Les autotests sont passés de 89 à 131. Quatre contournements mineurs restent ouverts dans [harness#2](https://github.com/etienneamiche/harness/issues/2).
- **Premier `copier update` réel** : `harness-sandbox` est passé de v0.1.1 à v0.2.0 (doctor entièrement vert), via la PR [harness-sandbox#1](https://github.com/etienneamiche/harness-sandbox/pull/1), gardée pour le premier essai de `/audit-pr` en phase 4. Deux enseignements sont notés dans [harness#3](https://github.com/etienneamiche/harness/issues/3) : `--answers-file` est obligatoire, et le manifeste se régénère au lieu de se fusionner.
- **Leçon** : une PR de plus de 2 000 lignes a demandé six revues. La règle des 400 lignes n'était pas qu'une préférence de style.
- **Ce qui reste non vérifié** : `biome.json` et `analyzers.globalconfig` n'ont pas encore tourné sur du vrai code. Ils le seront avec les templates (phases 5 à 7).

---

## Phase 4 — Process de travail : issues, Project et skills

**Objectif.** Le circuit complet d'une idée jusqu'à la PR, **sans CI**.

**Livrables**
- Le GitHub Project unique, ses colonnes, les labels (`feature`, `bug`, `harness-update`, `infra`, `integration`, `from-users`), les modèles d'issue et de PR.
- Les skills `/idea`, `/spec`, `/feature`, `/ship`, `/review`, `/audit-pr`, `/lint`, `/release` (en local), `/retro` et `/doctor`.
- Le format des commits `type(scope): … (#n)`, et git-cliff pour le changelog.
- **PR obligatoire sur `harness`, les templates et `libs`** : *ruleset* GitHub sur `main` (gratuit, dépôts publics), et `/audit-pr` avant chaque fusion.
- **Le dépôt `project-ideas`** (cadrage §9 bis) : `IDEAS.md`, `_template.md`, `scripts/idea.ps1`, et le skill racine `/project-idea` (noter une idée, créer sa page).

**Tests et critère de sortie.** Dans `harness-sandbox`, **trois issues fictives** passent de `Idée` à `Fait`. On vérifie que :
- chaque commit et chaque PR sont faits par `git-ops` (Haiku) ;
- le code est écrit par `dev` (Opus) ;
- la revue du diff est faite par `reviewer` (Haiku), et l'exploration du code par `explorer` (Haiku) ;
- **chaque PR reçoit une revue complète de `auditor` (Opus) avant sa fusion**. Une fusion tentée sans elle, ou après un nouveau commit, est refusée par `git-guard` ;
- le board suit l'avancement.

Pour `project-ideas` : une idée notée par `/project-idea`, une autre par `idea.ps1`, une troisième depuis l'interface web de GitHub. Les trois apparaissent dans `IDEAS.md`, et l'une d'elles reçoit sa page.

Release **v0.3.0**.

---

## Phase 5 — React, `libs/ui`, thèmes et *playground*

**Objectif.** Le premier vrai projet, de la création au lancement en local.

**Livrables**
- `template-react` et le module `react` du harness.
- Le monorepo `libs`, avec `@marblestudio/ui` : les thèmes `tech`, `app` et `spare`, les composants communs, le bouton de signalement (désactivé tant que `feedback` n'existe pas).
- Le *playground* de thèmes, lancé en local (il passera sur GitHub Pages en phase 10).
- `new-project.ps1`, dans sa version sans étape d'infra, avec `codegraph init`.
- `launch.ps1`, à la racine et dans le projet.
- `setup-workstation.ps1` : pnpm à jour (installé via corepack), Node 24 LTS.
- Options de `template-react` : `api` (`openapi` · `none`), `auth` (`none` · `forward-auth` · `oidc`), `google`, `realtime`.

**Tests et critère de sortie**
- Un projet « React seul » est généré, lancé et passe le doctor. **Biome tourne avec la config du module `react`** et la valide sur du vrai code.
- Une feature y est développée selon le circuit de la phase 4.
- On change de thème dans le *playground*, et la variante exportée s'applique au projet.

---

## Phase 6 — .NET, Python et secrets de dev

**Livrables**
- `template-dotnet` (Controller → Service → Dal / Clients, test d'architecture, `scripts/db.ps1` pour `db-ops`) et `template-python` (module léger, option `jobs`).
- Les options `postgres` (Docker en local, migrations DbUp) et `auth`, avec auth désactivée en local.
- **Dans `libs`** : `MarbleStudio.Hosting` et `marblestudio-hosting` (logs, OpenTelemetry, Problem Details, sondes, validation, authentification, `ICurrentUser`, permissions, impersonation, `ServiceResult<T>`), et l'**exécutable de migration DbUp** (image commune). Publiés en local seulement à ce stade.
- **Les secrets de dev** : `homelab/secrets/dev/<app>.sops.yaml`, injectés par `launch.ps1` via `sops exec-env`. Les scripts `secret-new.ps1` (valeur générée, jamais affichée, utilisable par un agent) et `secret-set.ps1` (saisie masquée par toi).
- `setup-workstation.ps1` : outil `csharp-ls` (pour le plugin `csharp-lsp`).

**Tests et critère de sortie.**
- Les combinaisons « .NET seul », « .NET + React + BDD », « … + auth » et « Python + React (jobs) » sont générées, lancées et passent le doctor.
- **`analyzers.globalconfig` tourne sur du vrai code.**
- **Aucun fichier de secret en clair** n'apparaît sur le disque pendant leur exécution.
- Un agent crée un secret par `secret-new.ps1` sans que sa valeur apparaisse dans la conversation.

---

## Phase 7 — Jeu multijoueur

**Livrables.** `template-game-multi`, selon le module `game` :
- serveur SignalR qui fait autorité, avec les règles en fonctions pures (`Apply`) ;
- salles avec une file par salle, des codes courts et la reconnexion ;
- joueurs invités, et connexion Authentik en option ;
- sauvegardes de partie versionnées (option `postgres`) ;
- client React avec rendu DOM + CSS, et contrats générés depuis le C#.

**Critère de sortie.**
- Deux navigateurs jouent ensemble en local.
- Une partie survit à un redémarrage du serveur grâce à sa sauvegarde.
- Le projet passe le doctor.

---

## Phase 8 — Mises à jour et propagation

**Livrables**
- `harness-status.ps1`, `harness-sync.ps1` et `template-sync.ps1`.
- Les `_migrations` de Copier.
- `/upstream` et le hook `structural-watch`.
- `audit.ps1`.

**Tests et critère de sortie**
- On publie une version de harness contenant une migration (renommage d'un fichier) et on la propage à **trois projets** : les PR sont correctes et la migration s'est appliquée.
- Un bloc structurel modifié dans un projet remonte jusqu'au template par `/upstream`, puis redescend dans les autres projets.

---

## Phase 9 — Harness racine, architecte et démarrage de projet

**Livrables**
- Le harness racine (`kind: root`), avec les skills `/infra`, `/doctor` et `/audit-all`.
- `build-catalog.ps1`, le catalogue, `rules.md` et les premiers ADR.
- L'agent `architect` et `/start-project`, étapes 1 à 6 (l'étape 7 attend la phase 11). `/start-project <n>` part de la page d'une idée de `project-ideas`, et la passe en `lancée`.
- `/evolve`.
- `/integrate`, essayé sur **un de tes sites existants** (cadrage §19).

**Tests et critère de sortie**
- Un vrai projet est démarré par `/start-project`. On obtient : les propositions d'architecture et d'infra, la roadmap, et les issues avec leurs liens dans `ROADMAP.md`.
- Un besoin non couvert déclenche bien `/evolve`.
- Un site existant reçoit son rapport `INTEGRATION.md`.

---

## Phase 10 — CI/CD

**Livrables**
- Les workflows réutilisables dans `harness` : build, tests, lint, gitleaks, `harness-check` et doctor au niveau dépôt.
- **La protection côté GitHub**, seule vraie garantie face à un contournement délibéré des hooks (mot cité, alias, `curl` avec un jeton : recommandation de la revue `auditor` de la PR harness #1). Un *ruleset* sur `main` et `develop` de chaque dépôt public (gratuit), qui impose :
  - la PR ;
  - la CI verte ;
  - **un contrôle de statut « auditor »**, que la revue `/audit-pr` publie sur le commit revu.

  `homelab`, privé, garde sa limite connue, faute de protection de branche gratuite.
- GitVersion et le gitflow des apps, avec les images publiées sur GHCR.
- La publication de `libs` sur npm, PyPI et nuget.org en *trusted publishing*, et le *playground* sur GitHub Pages.
- **La CI de `harness`** : génération de chaque archi, build, tests et Pester en `-Deep`.
- Renovate (preset commun, tous les deux jours, fusion automatique des correctifs et des dépendances de dev).
- `/release` complet : la PR de version dans `homelab`.

**Critère de sortie**
- Une release d'app produit son image et ouvre sa PR dans `homelab`.
- Une release de `libs` est publiée sur les trois registres.
- Une PR Renovate passe et est fusionnée automatiquement.
- La CI de `harness` refuse une release qui casse une archi.

---

## Phase 11 — Ce qui dépend de la plateforme k3s

*Attend que H1, la plateforme du homelab, soit terminée.*

**Livrables**
- `/start-project` étapes 7 et 8 : PR d'infra et v0 déployée.
- Le service `feedback` (Turnstile, limite de débit, contenu expurgé, GitHub App).
- `services-map` et `/map-infra`.

**Critère de sortie**
- Un projet démarré par `/start-project` tourne sur le cluster.
- Un signalement envoyé depuis cette app crée une issue expurgée sur son dépôt.

---

## Piste homelab

L'infra a sa propre roadmap, dans `homelab/docs/03-roadmap.md` (dépôt privé). Ses détails n'ont pas leur place ici (cadrage §2) : cette section ne porte que ses phases, notées **H0 à H5** pour ne pas les confondre avec celles de `services`, et leurs dépendances avec elles.

| Phase | Thème | Dépend de | État |
|---|---|---|---|
| H0 | Hyperviseur `pve-01` | — | ✅ Trois points reportés : les relevés de réception (avant la fin du droit de retour), la première sauvegarde réelle (avec le premier invité, en H1) et le test du runbook sur `pve-99` |
| H1 | Plateforme : clusters k3s `home` et `vps`, GitOps, première app exposée | H0, phase 4, harness et module `infra` dans `homelab` | À venir |
| H2 | Données et médias | H1 | — |
| H3 | Réseau, sécurité et supervision | H2 | — |
| H4 | IA locale | H1 | — |
| H5 | Domotique | H3 | — |

**Ordre retenu (2026-10-20) : la phase 4 d'abord, puis H1.**

**Avant H1, dans `homelab` :**
- le harness, de type `infra`, installé comme dans les autres dépôts. `homelab` est privé et sans protection de branche gratuite : `git-guard` y protège `main`, chaque PR reçoit une revue `auditor`, et **aucun agent ne fusionne** (`merge-pr.ps1` refuse les PR de `homelab`). C'est toi qui fusionnes, à la main ;
- un **module `infra`** dans le harness : conventions et lint pour Ansible, OpenTofu, les manifestes Kubernetes et SOPS, et les wrappers `infra/*.ps1`, qui demandent confirmation avant toute action destructive ou d'application (`tofu apply`, `ansible-playbook`, `kubectl apply` et `delete`).

**Ce que H1 ne livre pas**, parce que `services` le livre : les templates d'application (phases 5 à 7), la CI des apps, GitVersion, GHCR et Renovate (phase 10), le déploiement d'une app créée par `/start-project` et `services-map` (phase 11). La première app exposée en H1 est une app existante, packagée en Helm.

---

## En réserve

Des sujets écartés volontairement, à reprendre plus tard par `/evolve`.

| Sujet | Décidé le | Pourquoi plus tard |
|---|---|---|
| **Jeu d'action en temps réel, avec un client lourd** : seule la partie serveur serait dans l'écosystème (boucle à fréquence fixe, prédiction côté client) | 2026-10-14 | Complexité sans commune mesure avec les jeux au tour par tour et le temps réel léger |
| **Coffre-fort de secrets hébergé** (OpenBao) | 2026-10-14 | Inutile pour un seul humain ; à reprendre s'il y a plusieurs personnes ou un besoin de rotation automatique |
| **Relais Redis pour SignalR** (plusieurs instances d'une app) | 2026-10-14 | Une instance suffit tant que la charge le permet |
