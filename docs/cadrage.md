# Cadrage — écosystème `services`

*Version de travail du 2026-10-11. Rien n'est encore construit. Les points marqués ❓ attendent une réponse (§19).*

## 1. Objectif

Un seul point d'entrée, `services/`, pour **démarrer, intégrer, développer, tester, livrer, auditer et mettre à jour** tous les projets. Chaque projet suit les mêmes pratiques, et ses spécificités sont isolées.

**Contraintes retenues :**
- GitHub Free, compte personnel ;
- dépôts **publics**, sauf **`homelab` et ce qui décrit l'infra**, qui sont privés ;
- Windows natif, **PowerShell 7** pour tous les scripts ;
- Claude Code uniquement, en local ;
- **les scripts plutôt que les MCP** (`gh`, `git`, `copier`…), avec **codegraph** comme exception assumée ;
- uniquement des branches simples : ni worktree, ni rebase interactif, ni manipulation Git complexe.

---

## 2. Les dépôts

| Dépôt | Visibilité | Rôle | Versionné par |
|---|---|---|---|
| `services` | Public | Dépôt racine : harness racine, scripts transverses, `repos.yaml`, ce document. **Aucun détail d'infra** : le harness racine pointe vers `homelab/docs/` | — |
| `homelab` | **Privé** | Infra as code (Ansible, OpenTofu, clusters, chart générique, secrets SOPS) et **doc homelab** (`docs/`, reprise de `homelab-doc/`) | — |
| `services-map` | **Privé** | Le portail sur le cluster : page d'infra et liste des services (§12). Remplace `homelab-schema` et Homepage (catalogue n° 4) | GitVersion |
| `harness` | Public | Template Copier du harness : un cœur commun et des modules par techno. Porte aussi les workflows réutilisables et le preset Renovate | Tags semver sur `main` |
| `template-react` · `template-dotnet` · `template-python` | Public | Templates Copier des briques de code | Tags semver sur `main` |
| `template-game-multi` | Public | Template Copier d'un jeu multijoueur : serveur .NET SignalR (lobby, salles, état côté serveur) + client React (boucle de jeu, canvas) + contrats de messages partagés | Tags semver sur `main` |
| `libs` | Public | **Monorepo** des bibliothèques communes, publiées sur **nuget.org, npmjs et PyPI**. Contient aussi les thèmes et le *playground* de thèmes (§11) | Un tag par paquet sur `main` |
| `feedback` | Public | Service central de signalement de bugs et de demandes de features (§10) | GitVersion |
| `project-ideas` | **Privé** | Les idées de projets : une liste centrale avec un statut, et une page par idée quand elle mûrit (§9 bis) | — (`main` seul) |
| `<app>` | Public | **Une app = un dépôt monorepo** : front, back (s'il y en a un), `deploy/` et docs dans le même dépôt (§3) | GitVersion (gitflow) |

**Règle : une app = un monorepo.** Le front, le back, la config de déploiement et la doc d'une app vivent ensemble, avec **une seule version** pour l'ensemble (doc 07 §5). On ne crée jamais un dépôt par couche (`factures-front`, `factures-api`…).

**Branche par défaut : `main` partout.** Les apps ajoutent `develop`, `release/*` et `hotfix/*` (gitflow du doc 07). Le harness, les templates et `libs` vivent sur `main` seul.

⚠️ **`homelab` est privé**, donc sans protection de branche sur GitHub Free. Or fusionner dans `homelab` = déployer. Le garde-fou repose donc sur `git-guard` (§6) et sur la discipline. GitHub Pro reste une option plus tard.

### `services` ne versionne que lui-même

Les autres dépôts sont clonés **à l'intérieur** de `services/`, et un `.gitignore` en liste blanche les rend invisibles : on ignore tout, puis on ré-autorise uniquement le harness racine. Un commit dans `services` ne voit jamais les sous-dépôts.

```gitignore
/*
!/.gitignore
!/STARTUP.md
!/AGENTS.md
!/CLAUDE.md
!/.claude/
!/.harness/
!/scripts/
!/docs/
!/repos.yaml
```

`repos.yaml` est la source de vérité de l'écosystème, lue par tous les scripts :

```yaml
owner: <compte>
repos:
  - { name: homelab, kind: infra, private: true }
  - { name: harness, kind: harness }
  - { name: libs, kind: libs }
  - name: factures
    kind: app
    archi: { frontend: react, backend: dotnet, postgres: true, auth: oidc }
    theme: app
  - name: quiz-party
    kind: game
    archi: { template: game-multi }
```

---

## 3. Composer un projet : templates et harness

Toutes les archis se fabriquent **par composition, dans un seul dépôt**. Copier applique plusieurs templates au même monorepo, chacun avec son propre fichier de réponses, donc sa propre version :

```
<app>/                             ← UN dépôt GitHub, UNE version (tag vX.Y.Z)
├── .copier-answers.harness.yml    ← version du harness
├── frontend/                      ← template-react        (absent si l'app n'a pas de front)
├── backend/                       ← template-dotnet ou template-python (absent si pas de back)
├── deploy/                        ← Chart.yaml + values.yaml (dépend du chart générique)
├── docs/
└── …
```

| Archi | Briques |
|---|---|
| React seul | harness + react |
| .NET + React + BDD | harness + react + dotnet, `postgres: true` |
| … + auth | idem, `auth: oidc` (ou `forward-auth`) |
| Python + React | harness + react + python |
| .NET seul | harness + dotnet |
| Jeu solo | harness + react, `kind: game`, avec son propre thème |
| Jeu multijoueur | harness + **template-game-multi** |

L'auth et la base sont des **options**, pas des archis à part. Le jeu multijoueur est l'exception : client et serveur partagent leurs contrats de messages, donc ils vivent dans un même template.

**Pourquoi Copier.** Une nouvelle version d'un template s'applique par `copier update`, en *merge* à trois voies, sur un projet qui a divergé. La version installée est lue dans le fichier de réponses.

- **Fichiers du template** (régénérés à chaque mise à jour) : `.harness/**`, `.claude/agents/**`, `.claude/skills/**`, les hooks, les workflows CI.
- **Fichiers du projet** (créés une fois, jamais écrasés) : `AGENTS.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `docs/**`, le code métier.

---

## 4. Contenu du harness, dans un projet

```
<app>/
├── CLAUDE.md                 → une seule ligne : @AGENTS.md (AGENTS.md serait aussi lu sans lui)
├── AGENTS.md                 → spécificités du projet + imports :
│                               @.harness/agents/core.md
│                               @.harness/agents/<techno>.md   (selon l'archi)
├── ARCHITECTURE.md           → au projet
├── ROADMAP.md                → au projet. Versions et liens vers les issues
├── docs/                     → doc du projet (SPEC.md, décisions…)
├── .codegraph/               → index codegraph (ignoré par Git)
├── .harness/
│   ├── agents/*.md           → conventions : core, react, dotnet, python
│   ├── hooks/*.ps1           → un dispatcher par événement (§6)
│   ├── structural.txt        → liste des « blocs structurels » (§8.3)
│   └── manifest.json         → empreinte SHA-256 des fichiers du harness
├── .claude/
│   ├── settings.json         → hooks, permissions, modèle, env, plugins (ponytail…),
│   │                           claudeMdExcludes (instructions de la racine services)
│   ├── agents/*.md           → subagents à modèle imposé (§5)
│   └── skills/*/SKILL.md     → les workflows (§7)
├── scripts/                  → launch.ps1, test.ps1, lint.ps1, build.ps1
└── .github/
    ├── workflows/            → appels aux workflows réutilisables de harness@vX
    ├── ISSUE_TEMPLATE/       → feature, bug, harness-update, infra
    ├── pull_request_template.md
    └── renovate.json         → { "extends": ["github>…/harness"] }
```

Une mise à jour du harness ne touche jamais `AGENTS.md`, donc jamais de conflit sur les spécificités du projet. Les workflows réutilisables et le preset Renovate vivent dans `harness` : monter de version le harness fait aussi monter la CI.

Le **harness racine** de `services/` est généré par le même dépôt `harness`, avec `kind: root`.

**Les instructions de la racine ne fuient pas dans les projets.** Claude Code charge les `CLAUDE.md` des dossiers parents. Une session ouverte dans `services/<app>/` lirait donc les instructions d'infra de la racine. Le `settings.json` de chaque projet les exclut avec `claudeMdExcludes: ["**/services/CLAUDE.md", "**/services/AGENTS.md"]`. Le dossier racine doit donc s'appeler `services`.

**Les plugins** sont présents dans chaque projet : **ponytail**, les LSP selon la techno (`csharp-lsp`, `typescript-lsp`, `pyright-lsp`), [dotnet/skills](https://github.com/dotnet/skills) pour .NET, et le skill shadcn pour React. Les déclarer dans `settings.json` ne suffit pas à les installer : ils sont installés **par script**, avec `claude plugin install <plugin> --scope project`. C'est le rôle de `new-project.ps1`, de `pull-all.ps1` sur un nouveau poste, et de `harness-doctor -Fix`.

---

## 5. Modèles et subagents

| Subagent | Modèle | Usage |
|---|---|---|
| (session principale) | **opus** | Conversation, orchestration |
| `dev` | **opus** | Implémentation |
| `architect` | **opus** | Spécification, conception d'architecture, roadmap |
| `auditor` | **opus** | Audit, analyse d'intégration |
| `explorer` | **haiku** | Explorer le code (codegraph d'abord) et rapporter ce qui a été trouvé à la session principale |
| `linter` | **haiku** | Nettoyer le lint : lancer les formateurs et linters du projet, corriger les avertissements restants |
| `git-ops` | **haiku** | Messages de commit, commits, push, PR, changelog, labels, issues |
| `reviewer` | **haiku** | Revue d'un diff |
| `cartographer` | **haiku** | Résumer l'architecture existante d'un projet ou de l'écosystème (`ARCHITECTURE.md`, catalogue) |
| impeccable (4 agents, `inherit`) | → opus | Autorisés, puisque la session est en Opus |

**La règle :** Opus conçoit et écrit le code. Haiku fait tout ce qui est mécanique ou de la lecture : explorer, nettoyer, écrire un message, relire un diff, résumer. Sonnet n'a pas de rôle attitré.

L'agent intégré `Explore` n'est pas sur la liste blanche de `model-guard` : c'est `explorer` qui le remplace, avec son modèle imposé.

### L'architecte connaît tout l'écosystème

L'agent `architect` du harness racine ne lit pas tous les dépôts à chaque fois. Il s'appuie sur un **catalogue** tenu à jour automatiquement :

```
services/docs/catalog/
├── catalog.json        ← GÉNÉRÉ par build-catalog.ps1 :
│                          · templates : options, versions (lues dans leurs copier.yml)
│                          · libs : paquets et versions publiées
│                          · plateforme : clusters, niveaux d'exposition, modes d'auth,
│                            CNPG, stockage, sauvegardes (lus dans homelab)
│                          · budget : RAM et CPU réservés et libres par cluster
│                          · apps existantes : archi, cluster, exposition (repos.yaml)
├── CAPABILITIES.md     ← GÉNÉRÉ : la même chose, lisible
├── rules.md            ← écrit à la main : règles d'affectation (ex. « une app ne va
│                          sur le VPS que si elle doit survivre à une coupure de la maison »)
└── adr/                ← décisions d'architecture de l'écosystème (une par fichier)
```

`build-catalog.ps1` est relancé par `pull-all.ps1` et à chaque release du harness, d'un template ou de `libs`. L'architecte raisonne donc toujours sur l'état réel, pas sur un souvenir.

**Filet de sécurité : `CLAUDE_CODE_SUBAGENT_MODEL=haiku`.** Cette variable, posée dans `settings.json` → `env`, ne s'applique qu'aux agents **sans modèle déclaré**, comme `general-purpose`. Elle n'écrase ni un modèle déclaré ni `inherit`.

**Attention :** un paramètre `model` passé lors de l'appel d'un agent écrase son modèle déclaré. C'est ce que bloque `model-guard`. *(Vérifié pendant le spike : [`spike-claude-code.md`](spike-claude-code.md).)*

---

## 6. Les hooks (PowerShell)

**Architecture**, validée par le spike ([`spike-claude-code.md`](spike-claude-code.md)) :
- **Un dispatcher par événement**, qui enchaîne les vérifications dans un seul processus, pour deux raisons :
  - un hook `pwsh` coûte **~250 ms** à chaque déclenchement ;
  - les hooks d'un même événement tournent **en parallèle**, et leurs écritures partagées se corrompent.
- **Des matchers ciblés**, pour ne payer que là où une règle s'applique :
  - `PreToolUse` sur `Agent|Bash|PowerShell|Read|Edit|Write` ;
  - `PostToolUse` sur `Edit|Write` seulement ;
  - aucun hook sur `Glob`, `Grep` ou codegraph.
- **Si la latence gêne à l'usage**, le dispatcher sera compilé en exécutable .NET natif (AOT).
- **Entrée et sortie en UTF-8 forcé** dans chaque hook, sinon les accents du JSON sont corrompus.
- **Un refus** se fait par un JSON `permissionDecision: "deny"` avec sa raison, et le code de sortie 0.
- **L'appelant se reconnaît** à `agent_type` et `agent_id`, absents dans la session principale.
- **Profils** `minimal | standard | strict`, choisis par `HARNESS_HOOK_PROFILE`. On peut couper une règle précise avec `HARNESS_DISABLED_HOOKS`.
- **Les gardes de sécurité échouent fermé** (erreur = refus). **Les hooks d'information échouent ouvert.**

| Règle | Événement | Effet | Origine |
|---|---|---|---|
| `model-guard` | `PreToolUse` sur `Agent` | **Refuse** tout `subagent_type` hors liste blanche (y compris `general-purpose`), et **tout appel qui contient un paramètre `model`**, puisqu'il écraserait le modèle de l'agent | maison |
| `git-guard` | `PreToolUse` sur `Bash`/`PowerShell` | Refuse `git commit`, `git push`, `gh pr *`, `gh issue create` et `gh release` **hors du subagent `git-ops`**. Refuse aussi `git worktree`, `rebase -i`, `push --force`, `--no-verify`, le push direct sur `main`/`develop`, la fusion d'une PR `homelab`, et un message de commit sans `(#n)` | maison + ECC |
| `destructive-guard` | `PreToolUse` sur `Bash`/`PowerShell` | Au premier essai de `rm -rf`, `git reset --hard`, `tofu destroy`, `kubectl delete` ou `DROP TABLE` : refus. L'agent doit lister ce qui sera touché, donner un plan de retour arrière et citer ta demande. Le second essai passe | ECC |
| `config-protection` | `PreToolUse` sur `Edit`/`Write` | Bloque la modification des configs de lint et de format, de `.harness/**`, `.claude/settings.json`, `.github/workflows/**` et `.sops.yaml`. On les change par `/upstream` | ECC, étendu |
| `secret-guard` | `PreToolUse` + `UserPromptSubmit` | Refuse `sops -d` vers la sortie standard et la lecture de `.env`, `*.key`, `*.pem` et des clés age. Détecte les jetons collés dans un prompt. Détail des 7 couches : §17 | maison + ECC |
| `doc-sprawl` | `PreToolUse` sur `Write` | Avertit quand un agent crée un `.md` hors de `docs/` et des fichiers connus | ECC |
| `structural-watch` | `PostToolUse` sur `Edit`/`Write` | Fichier listé dans `structural.txt` → « bloc structurel modifié, proposer `/upstream` » | maison |
| `stop-checks` | `Stop` | Une seule passe de format et de typecheck sur les fichiers modifiés pendant le tour, plus une recherche de traces de debug oubliées | ECC |
| `session-info` | `SessionStart` | Affiche la version du harness, prévient si elle est en retard, et signale un index codegraph absent | maison |
| (permissions) | `settings.json` | `deny` sur `EnterWorktree` | maison |

Nos hooks cohabitent sans erreur avec le hook global de codegraph et ceux de ponytail. Leurs latences s'additionnent.

---

## 7. Flux de travail

**Un seul GitHub Project** pour tout l'écosystème.

- Labels de type : `feature`, `bug`, `harness-update`, `infra`.
- Colonnes : `Idée` → `Prêt` → `En cours` → `En revue` → `Fait`.
- Les issues sont ajoutées au board par script (`gh project item-add`).
- Les **milestones GitHub** correspondent aux versions de `ROADMAP.md`.

### Skills de projet (écrits maison, courts, sans Superpowers)

| Skill | Ce qu'il fait | Modèle |
|---|---|---|
| `/idea` | Idéation guidée. Produit une issue `feature` dans `Idée` | opus |
| `/spec <n>` | Critères d'acceptation, impacts, plan. Passe l'issue en `Prêt` | opus (`architect`) |
| `/feature <n>` | Crée `feature/<n>-<slug>` depuis `develop`, implémente et teste | `dev` + `git-ops` |
| `/ship` | Commit `feat(scope): … (#n)`, push, PR `Closes #n` | `git-ops` |
| `/review` | Revue de la PR en cours | `reviewer` |
| `/release` | `release/x.y.z`, changelog (git-cliff), fusion, tag, PR de version dans `homelab` | `git-ops` |
| `/upstream` | Remonte un bloc structurel vers son template (§8.3) | `dev` + `git-ops` |
| `/audit` | Audit du projet | `auditor` |
| `/lint` | Nettoie le lint du projet | `linter` |
| `/retro` | Ce qui a gêné l'agent devient une règle de `AGENTS.md` ou une issue `harness-update` | opus |

### Skills racine (`services/`)

| Skill | Ce qu'il fait |
|---|---|
| `/project-idea` | Noter une idée de projet en une phrase, ou lui créer sa page (§9 bis) |
| `/start-project` | Démarrer un projet de bout en bout (§9), éventuellement à partir d'une idée de `project-ideas` |
| `/evolve <besoin>` | Faire évoluer l'écosystème pour un besoin nouveau (§16) |
| `/doctor` | Lancer `harness-doctor.ps1` et expliquer les écarts (§18) |
| `/integrate <dépôt>` | Mettre un site existant aux normes (§13) |
| `/infra <question>` | Répondre sur l'infra à partir de `homelab/docs` et de l'état réel (`kubectl`, `argocd`) |
| `/map-infra` | Régénérer la page d'infra de `services-map` |
| `/audit-all` | Lancer `audit.ps1` et en faire la synthèse |

---

## 8. Mises à jour

### 8.1 Dépendances
**Renovate**, avec un preset commun dans `harness` et une planification **tous les deux jours**.
- **Fusion automatique** quand la CI est verte, pour les correctifs (patch) et les dépendances de dev.
- **Validation manuelle** pour le reste.
- Les paquets de `libs` échappent à la planification : leurs mises à jour partent tout de suite.

### 8.2 Un correctif à répercuter sur tous les projets
- **Le bug est dans `libs`** : correctif, puis publication. Renovate ouvre la PR dans chaque projet qui l'utilise.
- **Le bug est dans un fichier venu d'un template** : circuit du §8.3.
- **Le bug est dans une lib tierce** : `audit.ps1 -Package <nom>` liste les dépôts concernés et crée une issue `bug` dans chacun.

### 8.3 Un bloc structurel modifié pendant le dev d'une app
1. `structural-watch` signale la modification.
2. `/upstream` calcule le diff et ouvre une PR sur le template ou le harness.
3. Fusion et tag, puis `template-sync.ps1` propage la nouvelle version.

### 8.4 Le harness
Les deux mécanismes à la fois :
- **en push** : `harness-sync.ps1` lance `copier update` et ouvre une PR `chore/harness-vX.Y.Z` par dépôt ;
- **en pull** : un job CI `harness-check` signale le retard, sans faire échouer le build.

---

## 9. Démarrer un projet : `/start-project`

Le projet est **défini avant d'être créé**. Les brouillons vivent dans `services/drafts/<app>/`, que la liste blanche ignore, et sont déplacés dans le dépôt à l'étape 5.

| Étape | Qui | Résultat |
|---|---|---|
| 1. Description approfondie | `architect` (opus), en dialogue avec toi | Objectif, utilisateurs, périmètre, ce qui est hors périmètre, données, volumétrie, contraintes → `SPEC.md` |
| 2. Choix de l'architecture | `architect`, à partir du catalogue | **2 ou 3 propositions** (templates, options, libs), avec leurs compromis et une recommandation → `ARCHITECTURE.md`. Si aucun template ne couvre le besoin : **`/evolve`** (§16) avant d'aller plus loin |
| 3. Roadmap | `architect`, puis ta validation | `ROADMAP.md` découpé en versions (v0, v1…), chacune en features de la taille d'une PR |
| 4. Définition de l'infra | `architect`, à partir du catalogue, puis ta validation | **Propositions** : cluster (selon `rules.md`), exposition, mode d'auth, base, stockage, sauvegardes, *requests*/*limits*, secrets nécessaires, **impact sur le budget RAM** du cluster → `docs/INFRA.md` |
| 5. Socle | `new-project.ps1` | Dépôt GitHub, branches `main`/`develop`, templates selon l'archi retenue, `codegraph init`, labels, ajout au Project, entrée dans `repos.yaml`, brouillons déplacés dans `docs/` |
| 6. Issues | `git-ops` (haiku) | Une issue par feature, un milestone par version, ajout au Project, **liens `#n` réécrits dans `ROADMAP.md`** |
| 7. PR infra | `git-ops` | Dans `homelab`, tout ce que décrit `INFRA.md` : `config.yaml` de l'app, *blueprint* Authentik, base CNPG, secrets SOPS à remplir |
| 8. v0 | CI + toi | Squelette tagué `v0.1.0`, image sur GHCR, PR de version dans `homelab`. **Tu fusionnes, ArgoCD déploie** |

⚠️ Tant que la plateforme k3s/ArgoCD de la phase 1 n'existe pas, l'étape 8 s'arrête à la PR ouverte dans `homelab`.

---

## 9 bis. Idées de projets : `project-ideas`

Un dépôt volontairement simple, pour **noter une idée en une phrase** et la développer plus tard.

```
project-ideas/
├── README.md         ← mode d'emploi
├── IDEAS.md          ← LA liste centrale : une ligne par idée
├── _template.md      ← modèle de page
└── ideas/
    └── 0007-quiz-party.md    ← page d'une idée, créée quand elle mûrit
```

**`IDEAS.md`**

| # | Idée | Statut | Ajoutée | Page | Projet |
|---|---|---|---|---|---|
| 7 | Quiz multijoueur pour les soirées | `décrite` | 2026-10-12 | [page](ideas/0007-quiz-party.md) | |
| 8 | Suivi des factures du foyer | `brute` | 2026-10-12 | | |

**Les statuts :**
- `brute` : juste une phrase ;
- `décrite` : elle a sa page ;
- `retenue` : prête pour `/start-project` ;
- `lancée` : le dépôt existe, avec un lien vers lui ;
- `en pause` ;
- `abandonnée` : on garde la ligne pour se souvenir pourquoi.

**La page d'une idée** suit `_template.md` : le problème, l'idée, pour qui, ce qu'elle ferait (3 à 5 points), l'archi pressentie, les questions ouvertes, des notes libres.

**Trois façons de noter une idée :**
- depuis `services/` : `/project-idea "une phrase"`, qui ajoute une ligne `brute`, la commite et la pousse ;
- **sans Claude** : `scripts/idea.ps1 "une phrase"`, même résultat ;
- **depuis le téléphone** : modifier `IDEAS.md` dans l'interface web de GitHub.

**Ensuite :**
- `/project-idea page 7` crée la page de l'idée n° 7 après quelques questions, et la passe en `décrite` ;
- `/start-project 7` part de cette page pour l'étape 1 (§9). L'idée passe en `lancée`, avec le lien vers le nouveau dépôt.

Les commits vont **directement sur `main`**, sans PR ni gitflow : `git-guard` l'autorise pour ce dépôt (`kind: ideas`).

---

## 10. Signaler un bug, demander une feature : `feedback`

```
App (n'importe laquelle)                 feedback (API .NET, cluster)              GitHub
<FeedbackButton/> de @marblestudio/ui  ──POST──▶    · retrouve le dépôt via l'app source  ──▶  issue bug | feature
erreurs JS non gérées       ──POST──▶    · déduplique (empreinte de l'erreur)       + label `from-users`
middleware .NET / Python    ──POST──▶    · limite le débit                          + ajout au Project
                                         · retire les données personnelles          (ou commentaire sur
                                                                                     l'issue existante)
```

- **Le widget** est livré dans `@marblestudio/ui` et activé par défaut par `template-react`. Il comprend un formulaire « Signaler un bug / Proposer une idée » avec capture de l'URL, du navigateur, de la version de l'app et, en option, d'une capture d'écran.
- **La remontée automatique des erreurs** est livrée par `libs` : *error boundary* React, middleware .NET et Python. L'empreinte de l'erreur évite de créer une issue par occurrence.
- **Côté GitHub**, l'issue est créée par une **GitHub App** dédiée, limitée au droit `issues:write`. Aucun jeton personnel.
- **Ouvert à tous**, pour le moment, avec un **anti-spam** à trois niveaux :
  - **Cloudflare Turnstile** : gratuit, sans casse-tête visuel, et la zone DNS est déjà chez Cloudflare ;
  - **une limite de débit** par IP et par app ;
  - **un champ piège** invisible, que seuls les robots remplissent.
- ⚠️ **Les dépôts sont publics, donc les issues aussi.** Le contenu brut d'un signalement reste dans la base de `feedback`, et l'issue publique n'en reçoit qu'une version expurgée : sans email, sans IP, sans données saisies.

---

## 11. Thèmes et *playground*

| Thème | Pour |
|---|---|
| `tech` | Outils techniques, admin, dashboards, `services-map` |
| `app` | Applications classiques |
| `spare` | Réserve, pour un 3ᵉ usage à venir |
| (par jeu) | Chaque jeu a son thème, dans son dépôt |

Les thèmes reposent sur Tailwind v4 et les variables CSS shadcn, avec des couleurs en oklch. Ils sont livrés dans le paquet npm `@marblestudio/ui`, avec les composants communs. Chaque app en importe un seul, et Renovate les tient à jour.

**Le *playground*** (`libs/node/playground`, une app Vite) :
- affiche **tous les composants** (shadcn et ceux de `@marblestudio/ui`) dans tous leurs états ;
- permet de **basculer d'un thème à l'autre** en direct, et d'éditer les variables d'un thème pour en essayer une variante ;
- **exporte** la variante modifiée. Le skill `/theme` en fait une PR sur `libs`, et une nouvelle version de `@marblestudio/ui` est publiée.

C'est une **page maison**, pas Storybook. Elle est hébergée sur **GitHub Pages**, puisque `libs` est public. Elle fonctionne donc avant que le cluster existe.

---

## 12. `services-map`

C'est le portail de l'écosystème, déployé sur le cluster au niveau d'exposition `vpn`. C'est une app comme les autres (React seul, thème `tech`), dans un dépôt privé. Elle remplace `homelab-schema` et Homepage.

- **Page d'infra** : réseau précis de la maison et du VPS, **générée par Claude** (`/map-infra`) depuis `homelab`.
- **Page des services** : point d'entrée vers toutes les apps, **générée par script** depuis `repos.yaml` et `homelab/clusters/*/apps/*/config.yaml`. Elle affiche l'URL, le cluster, la version déployée et la version du harness de chaque app.

---

## 13. Intégrer un site existant : `/integrate`

Objectif : mettre aux normes un site développé à côté, **sans tout refaire**.

| Étape | Qui | Résultat |
|---|---|---|
| 1. Import | script | Dépôt rapatrié ou référencé, ajouté à `repos.yaml`, `codegraph init` |
| 2. Analyse complète | `auditor` (opus), **en lecture seule** | Stack et versions, archi équivalente, écarts avec les templates et le harness : structure, CI, Dockerfile, `/healthz` et `/ready`, config au démarrage, auth, base et migrations, thème, lint, tests |
| 3. Rapport | `auditor` | `docs/INTEGRATION.md` en trois parties : **ce qui s'intègre mal** (avec la gravité et l'effort), **ce qui peut se garder tel quel**, **ce qui peut enrichir l'écosystème** (composants vers `libs`, motifs vers les templates, règles vers le harness) |
| 4. Plan | toi + `architect` | Issues étiquetées `integration`, ordonnées en petites PR |
| 5. Application progressive | `dev` + `git-ops` | **Le harness d'abord** (non invasif), puis la CI et le déploiement, puis les briques structurelles une par une. **Jamais de réécriture du code métier** |

---

## 14. Scripts racine (`services/scripts/`, PowerShell 7)

| Script | Rôle |
|---|---|
| `setup-workstation.ps1` | Idempotent, et suit `STARTUP.md`. Profil `dev` : outils de développement, sans accès à l'infra. Profil `admin` : en plus `sops`, `age`, `kubectl`, `tofu`, et une clé age **propre au poste** |
| `add-workstation-key.ps1` | Ajoute la clé publique d'un poste dans `homelab/.sops.yaml`, puis lance `sops updatekeys`. Il y a ainsi plusieurs clés, une par poste |
| `pull-all.ps1` | Clone les dépôts manquants et fait un `pull --ff-only` partout. Signale les dépôts modifiés ou en avance |
| `new-project.ps1` | Étape 1 de `/start-project`. Lance aussi **`codegraph init`** |
| `launch.ps1 <app>` | Délègue au `scripts/launch.ps1` de l'app : Postgres (Docker), `dotnet watch`, `uv run`, `vite`. Auth désactivée en local tant qu'Authentik n'existe pas |
| `harness-doctor.ps1` | Diagnostic complet du poste, de la racine et de chaque dépôt, avec autotests des hooks (§18) |
| `build-catalog.ps1` | Régénère le catalogue de l'architecte (§5) |
| `harness-status.ps1` | Tableau des versions (harness et templates) de chaque dépôt, comparées aux derniers tags |
| `harness-sync.ps1` / `template-sync.ps1` | Propagation (§8) |
| `release-lib.ps1` | Tague un paquet de `libs` (`node-v1.2.0`…). La CI le publie sur son registre |
| `audit.ps1` | Versions en retard, état de la CI, version déployée comparée au dernier tag, conventions. Les CVE ne sont pas vérifiées |
| `infra/*.ps1` | Wrappers `kubectl`, `argocd`, `tofu` et `ansible`, avec confirmation pour toute action destructive ou d'application |

**Publication de `libs`** : par *trusted publishing* (OIDC depuis GitHub Actions) sur npm et PyPI. Aucun jeton longue durée n'est stocké. Pour nuget.org, la disponibilité de ce mode est à confirmer, sinon on utilise une clé d'API limitée au préfixe des paquets.

---

## 15. Outils existants

| Outil | Place |
|---|---|
| **codegraph** | Conservé, initialisé sur **chaque** projet. `.codegraph/` est ignoré par Git. Les subagents qui lisent du code ont accès à `mcp__codegraph__*`. Le hook global n'est pas dupliqué |
| **ponytail** | Intégré **partout** : déclaré dans le `settings.json` du harness |
| **impeccable** | Reste global. Ses agents en `inherit` passent sur Opus |
| **unity-mcp** | Hors harness : les jeux sont des projets web React |

---

## 16. Un écosystème qui évolue : `/evolve`

Objectif : un besoin nouveau (une techno, une dépendance, un service de plateforme) s'ajoute **une fois, au centre**, et profite ensuite à tous les projets. On ne bricole pas dans un seul projet.

### Le circuit

1. **Détection.** Pendant `/start-project` ou `/spec`, l'architecte compare le besoin au catalogue. Si le besoin n'est pas couvert (Redis, stockage S3, tâches planifiées, envoi d'emails, nouveau langage…), il le signale au lieu de le contourner. `/retro` et `/integrate` remontent aussi ce genre de manque.
2. **Décision.** `/evolve <besoin>` rédige un **ADR** dans `services/docs/catalog/adr/` : le besoin, les options, la recommandation, les dépôts touchés. Tu valides.
3. **Réalisation.** Une issue `harness-update` ou `infra` par dépôt concerné, puis une PR dans chacun : un module dans `harness`, une option dans un template, une option dans le chart générique de `homelab`, un paquet dans `libs`.
4. **Diffusion.** Les releases suivent, le catalogue est régénéré, et les projets récupèrent l'évolution par `harness-sync` ou `template-sync`.

### Ce qui rend le système durable

| Principe | Mise en œuvre |
|---|---|
| **Le cœur ne bouge pas, on ajoute des modules** | Chaque techno ou capacité est un module : `.harness/modules/<nom>/`, avec ses conventions agent, ses vérifications de hook, ses scripts, ses étapes de CI et un `module.json` qui déclare ses commandes de format, typecheck, test et lancement. Les dispatchers de hooks et les scripts **découvrent** les modules. Ajouter une techno ne demande aucune modification du cœur |
| **Des migrations automatiques entre versions** | Les `_migrations` de Copier lancent un script PowerShell lors d'un `copier update` qui franchit une version donnée (renommage de fichier, nouvelle clé de config…). Une version majeure est toujours accompagnée de sa migration et d'une note dans le CHANGELOG |
| **Chaque release du harness est testée sur toutes les archis** | La CI de `harness` génère **chaque combinaison** (React seul, .NET + React + BDD, Python + React, jeu multi…) dans un dossier temporaire, la compile, la teste et passe les autotests de hooks. Une release qui casse une archi ne sort pas |
| **Semver strict** | Patch : correctif. Minor : nouveau module ou nouvelle option, sans rupture. Major : rupture, avec migration. `harness-status` affiche l'écart de chaque projet |
| **Les agents sont découplés de l'outil** | La logique vit dans `AGENTS.md` et les scripts. La couche propre à Claude Code (`.claude/`) reste mince. Changer d'outil ou suivre une évolution de Claude Code ne touche qu'elle |
| **Version minimale de Claude Code déclarée** | Le harness déclare la version de Claude Code sous laquelle ses hooks ont été testés. Le doctor vérifie la version installée |
| **Rien n'est figé dans la tête de l'architecte** | Le catalogue est régénéré depuis les dépôts : les nouveaux modules sont connus dès leur release |

---

## 17. Secrets : jamais lus, jamais poussés

Défense en profondeur. Aucune couche ne suffit seule, mais ensemble elles couvrent les erreurs de l'agent **et les tiennes**.

| Couche | Ce qu'elle empêche | Remarque |
|---|---|---|
| **1. Pas de secret en clair sur le disque** | Il n'y a rien à lire. Les secrets de dev sont dans un `secrets.dev.sops.yaml` chiffré, dans le dépôt. `launch.ps1` les injecte en variables d'environnement **du seul processus lancé** (`sops exec-env`). Pas de `.env`, pas de `dotnet user-secrets` | La protection la plus forte : un fichier qui n'existe pas ne fuit pas |
| **2. Permissions Claude (`deny`)** | `Read` et `Edit` sur `.env*`, `*.pem`, `*.key`, `*.pfx`, `secrets.json`, `appsettings.*.Local.json`, `%APPDATA%\Microsoft\UserSecrets\`, et les clés age | Bloquant et natif, mais ne couvre pas une lecture passée par le shell |
| **3. Hook `secret-guard`** | La lecture de ces chemins par une commande shell (`cat`, `type`, `Get-Content`, `gc`…), `sops -d` vers la sortie standard, l'affichage des variables d'environnement, et les jetons collés dans un prompt | Au mieux de ses moyens : une commande détournée peut passer. D'où les couches 1 et 4 |
| **4. Hook Git `pre-commit` + gitleaks** | Tout commit contenant un secret, **qu'il vienne de l'agent ou de toi**. Installé par `core.hooksPath=.harness/githooks` | `git-guard` interdit `--no-verify` à l'agent |
| **5. `git-guard` à l'indexation** | `git add -A` et `git add .` sont refusés à l'agent. `git-ops` ajoute les fichiers un par un, et le hook vérifie leur nom avant le commit | |
| **6. `.gitignore` du harness** | `.env*`, `*.pem`, `*.key`, `*.pfx`, `secrets.json`, `*.local.json`… | Protégé par `config-protection` : l'agent ne peut pas le modifier |
| **7. CI gitleaks + *push protection* GitHub** | Le dernier filet, côté serveur. La *push protection* est gratuite et active par défaut sur les dépôts publics | ⚠️ Non disponible gratuitement sur `homelab`, privé : ce dépôt ne compte que sur la couche 4 et la CI gitleaks |

**Le doctor teste ces couches** (§18) : il présente un faux secret de test aux hooks et à gitleaks, et vérifie qu'il est bien bloqué.

---

## 18. Le doctor : `harness-doctor.ps1`

Une seule commande répond à « est-ce que tout est en place et fonctionne ? ». Elle produit un tableau `OK / WARN / FAIL`, avec un code de sortie utilisable en CI. `-Fix` applique les réparations sans risque, `-Deep` lance les autotests.

| Niveau | Vérifications |
|---|---|
| **Poste** | Outils présents et à la version minimale : `pwsh` 7, `git`, `gh`, `uv`, `copier`, `sops`, `age`, `gitleaks`, `codegraph`, `docker`, `dotnet`, `node`, `kubectl`, `tofu` et Claude Code. Authentification `gh` avec les bons droits (`repo`, `project`), en SSH. **CLI `claude` connecté** (sa connexion est distincte de l'app desktop et peut expirer). Clé age présente et déclarée dans `homelab/.sops.yaml` |
| **Racine `services`** | La liste blanche du `.gitignore` est intacte et aucun sous-dépôt n'est suivi. `repos.yaml` est cohérent avec GitHub : dépôts existants, visibilité attendue. Tous les dépôts sont clonés, propres et à jour. Le catalogue est récent. Les scripts racine sont à la dernière version du harness (`kind: root`) |
| **Chaque dépôt** | Version du harness et des templates comparée aux derniers tags. Fichiers du harness intacts (`manifest.json`). Hooks branchés dans `settings.json`, `core.hooksPath` en place. **Plugins de `enabledPlugins` réellement installés** (`claude plugin install --scope project`). `claudeMdExcludes` présent. Index codegraph présent et récent. Motifs de secrets présents dans `.gitignore`. Workflows CI pointant sur la même version du harness. Renovate configuré. Labels présents, dépôt relié au Project |
| **Autotests (`-Deep`)** | Une suite **Pester** livrée avec le harness envoie des entrées JSON simulées à chaque dispatcher et vérifie la décision : `general-purpose` refusé, commit depuis la session principale refusé, lecture de `.env` refusée, `--no-verify` refusé, faux secret bloqué par gitleaks… Les scripts sont lancés en `-WhatIf` |

**Pourquoi un doctor maison.** Aucun outil existant ne connaît notre harness : nos hooks, nos modules, nos versions. Seul **`claude doctor`**, intégré à Claude Code, le complète : il vérifie l'installation de Claude Code elle-même, et notre doctor l'appelle au niveau « poste ».

**Quand il tourne :**
- **à l'ouverture d'une session** (hook `SessionStart`) : version rapide, une fois par jour, résultat mis en cache ;
- **dans la CI de chaque projet** : niveau « dépôt » ;
- **dans la CI de `harness`** : en `-Deep`, sur chaque archi générée (§16) ;
- **à la demande** : `/doctor` explique les écarts et propose les corrections.

---

## 19. Points ouverts

1. ❓ **Sites à intégrer** : lesquels, sur quelles stacks, hébergés où aujourd'hui, et déjà sur GitHub ? Ce n'est pas bloquant avant l'étape 7 de l'ordre de construction.
2. Conventions techniques par stack : à voir plus tard.

---

## 20. Ordre de construction

Voir [`ROADMAP.md`](ROADMAP.md) : 12 phases, chacune avec ses livrables, ses tests et son critère de sortie.
