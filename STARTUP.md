# STARTUP — remonter l'écosystème sur un poste

De zéro jusqu'à un poste prêt, sur Windows 11. Compter environ 30 minutes, surtout du téléchargement.

| Profil | Pour qui | Accès |
|---|---|---|
| `dev` | Toi ou un autre développeur | Code des dépôts publics, sans aucun secret |
| `admin` | Toi seulement | En plus : `homelab` (privé), secrets SOPS, clusters |

---

## 1. Prérequis

- Windows 11 avec `winget` (présent d'origine).
- Un compte GitHub. Pour le profil `admin`, avoir accès au dépôt privé `homelab`.

## 2. Git et PowerShell 7

Dans un terminal Windows PowerShell :

```powershell
winget install --id Git.Git --exact
winget install --id Microsoft.PowerShell --exact
```

Fermer le terminal, puis en ouvrir un **PowerShell 7** (`pwsh`). Toutes les commandes suivantes s'y lancent.

## 3. Cloner `services`

```powershell
git clone https://github.com/<compte>/services.git C:\repo\services   # dépôt public : pas besoin d'être connecté
cd C:\repo\services
```

Le chemin `C:\repo\services` n'est pas obligatoire, mais un chemin court évite les soucis de longueur sous Windows.

## 4. Installer les outils

```powershell
./scripts/setup-workstation.ps1 -Check              # état des lieux, n'installe rien
./scripts/setup-workstation.ps1 -Role dev -Upgrade  # ou -Role admin
```

- Le script est **idempotent** : on peut le relancer autant de fois qu'on veut, il n'installe que ce qui manque.
- `-Upgrade` met aussi à jour les outils trop anciens.
- `-WhatIf` montre ce qui serait fait, sans le faire.

Deux outils ne s'installent pas par `winget` :
- **Claude Code** : `irm https://claude.ai/install.ps1 | iex`, puis lancer `claude` et taper `/login`. Le CLI a sa propre connexion, distincte de l'app desktop : si elle expire, recommencer `/login`.
- **codegraph** : `irm https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.ps1 | iex`

## 5. Identité Git

Les dépôts de l'écosystème sont **publics** : l'email de chaque commit est visible de tous. On utilise l'adresse *noreply* de GitHub, **uniquement pour les dépôts sous `C:\repo\services\`**, sans toucher à l'identité utilisée ailleurs (au travail, par exemple).

Dans `~/.gitconfig` :

```ini
[includeIf "gitdir/i:C:/repo/services/"]
    path = ~/.gitconfig-services
```

Dans `~/.gitconfig-services` :

```ini
[user]
    name = <Ton nom>
    email = <id>+<compte>@users.noreply.github.com
```

L'adresse *noreply* exacte se trouve dans GitHub → `Settings` → `Emails`.

Activer aussi les chemins longs :

```powershell
git config --global core.longpaths true
```

## 6. Se connecter à GitHub

Git passe par **SSH**. Aucun identifiant HTTPS n'est stocké sur le poste.

À faire **soi-même**, de façon interactive :

```powershell
gh auth login -p ssh -s project
```

- `-p ssh` règle `gh` pour cloner en SSH. S'il n'existe pas encore de clé dans `~/.ssh`, `gh` propose d'en créer une et de l'envoyer sur GitHub.
- Le droit `project` sert au GitHub Project commun à tous les dépôts.
- Vérification : `ssh -T git@github.com` doit répondre `Hi <compte>!`.

Si `git config --global credential.helper` vaut `store`, un jeton est gardé en clair dans `~/.git-credentials`. Avec SSH, il ne sert plus : retirer le réglage (`git config --global --unset credential.helper`), supprimer le fichier, et révoquer le jeton sur GitHub (`Settings` → `Developer settings`).

Ensuite, renseigner `owner:` dans `repos.yaml` s'il est vide (`gh api user --jq .login` donne le nom du compte).

## 7. Récupérer tous les dépôts

```powershell
./scripts/pull-all.ps1
```

Le script clone ce qui manque et met à jour le reste par `pull --ff-only`. Il ne touche jamais un dépôt modifié, en avance ou divergent : il le signale.

## 8. Profil `admin` uniquement

### Accès aux secrets

`setup-workstation.ps1 -Role admin` génère une **clé age propre à ce poste**, dans `%APPDATA%\sops\age\keys.txt`, et affiche sa clé publique.

- **La clé privée ne quitte jamais le poste**, sauf pour sa copie de secours. Elle ne se commite pas, ne s'envoie pas, ne se colle dans aucune conversation.
- **Copie de secours hors ligne, obligatoire sur le premier poste admin** : si toutes les clés sont perdues, tous les secrets le sont aussi. Ouvre `%APPDATA%\sops\age\keys.txt` toi-même, et range son contenu :
  - dans ton gestionnaire de mots de passe ;
  - **et** sur un support hors ligne : une impression ou une clé USB, rangée à part.

  Un deuxième poste admin, avec sa propre clé, ajoute une sécurité, mais ne remplace pas cette copie.
- Pour que ce poste puisse déchiffrer les secrets, **un poste qui a déjà l'accès** lance :
  ```powershell
  ./scripts/add-workstation-key.ps1 -PublicKey age1… -Name portable
  ```
  Le script ajoute la clé à `homelab/.sops.yaml`, rechiffre chaque secret pour le nouvel ensemble de clés, puis il reste à commiter le résultat dans `homelab` par une PR. Au tout premier usage, il crée `.sops.yaml`.
- **Pour retirer un poste** perdu ou abandonné : même commande, avec `-Remove`. Le script retire la clé, puis **change la clé de données** de chaque secret (`sops rotate`) : un poste retiré qui avait déjà déchiffré un secret ne peut pas lire les versions suivantes. Il refuse de retirer la dernière clé.
- L'historique Git garde les anciennes versions chiffrées. Si un poste est compromis, il faut aussi **changer les secrets eux-mêmes**.

### Ansible

Ansible ne tourne pas nativement sous Windows : il tourne dans **WSL Ubuntu**.

- Il faut une distribution Ubuntu dans WSL : `wsl --install -d Ubuntu` si elle n'existe pas.
- Le reste est fait par `setup-workstation.ps1 -Role admin`, qui installe `uv` puis `ansible-core` dans Ubuntu, **sans `sudo`**.

## 9. Vérification finale

```powershell
./scripts/harness-doctor.ps1          # poste, racine, et chaque dépôt équipé du harness
./scripts/harness-doctor.ps1 -Fix     # répare ce qui peut l'être sans risque (plugins, index codegraph…)
```

Le poste est prêt quand le bilan ne contient plus aucun `FAIL`. `-Deep` lance aussi les autotests des hooks de chaque dépôt, `-Offline` évite tout accès réseau.

## 10. Travailler sur Kimi quand les crédits Claude sont épuisés

On garde **Claude Code** et on branche seulement son modèle sur l'abonnement Kimi Code (K3.1 Pro), par l'API compatible Anthropic de Kimi. Les hooks, les skills, les agents et la mémoire du dépôt où la session est lancée restent les mêmes. La CLI Kimi Code, elle, ne lit ni les hooks ni les skills : les garde-fous du harness n'y existent pas.

**Une fois, sur le poste :**

1. Créer une clé dans la console Kimi Code, puis la poser en variable d'environnement utilisateur, sans qu'elle passe par l'historique du terminal :
   ```powershell
   [Environment]::SetEnvironmentVariable('KIMI_API_KEY', (Read-Host 'Clé Kimi Code' -MaskInput), 'User')
   ```
2. Vérifier dans la console Kimi Code **l'adresse de l'API compatible Anthropic** et **l'identifiant du modèle**. Le script prend par défaut `https://api.kimi.com/coding/` et `kimi-k3.1-pro`. Si la console donne autre chose, poser `KIMI_BASE_URL` et `KIMI_MODEL` de la même façon (et `KIMI_FAST_MODEL` pour un modèle plus léger sur les agents Haiku).
3. Rouvrir le terminal, puis contrôler, sans lancer Claude Code et sans afficher la clé :
   ```powershell
   C:\repo\services\scripts\claude-kimi.ps1 -Check   # configuration, et présence d'un harness dans le dossier courant
   C:\repo\services\scripts\claude-kimi.ps1 -Probe   # une requête par modèle : HTTP 200 confirme l'adresse, la clé et le modèle
   ```
   Une erreur de `-Probe` dit ce qui ne va pas (clé refusée, modèle inconnu…) : corriger `KIMI_BASE_URL`, `KIMI_MODEL` ou `KIMI_FAST_MODEL` (selon le modèle en erreur), puis relancer.

**À chaque session**, dans le terminal (pas l'application de bureau), **depuis le dépôt où l'on travaille**, là où l'on lancerait `claude` d'habitude. Claude Code ne charge que le harness de ce dossier : ses hooks, ses agents, ses skills et sa mémoire. La racine `services` n'a pas encore de harness (phase 9) : une session lancée là n'a ni hooks ni agents, et le script le signale.

```powershell
cd C:\repo\services\homelab
C:\repo\services\scripts\claude-kimi.ps1
C:\repo\services\scripts\claude-kimi.ps1 --continue          # une option longue de claude passe telle quelle
C:\repo\services\scripts\claude-kimi.ps1 -- -p "résume"      # une option courte se place après --
```

Les variables ne valent que pour cette session : à la sortie de Claude Code, le terminal retrouve son état d'avant, et `claude` seul repart sur Anthropic.

**Rester cohérent entre les deux modèles :**

- **Rien ne change dans le harness.** Les modèles qu'il impose (`opus` pour `dev`, `architect` et `auditor`, `haiku` pour les autres) deviennent des alias vers les modèles Kimi.
- **Chaque PR dit quel modèle a codé et lequel a audité**, dans ses points d'attention (par exemple « Codé et audité avec Kimi K3.1 Pro »). Les skills ont été mis au point sur Opus : un autre modèle peut suivre moins bien les consignes longues.
- **De préférence, `/audit-pr` sur Claude** dès que les crédits reviennent, pour les PR codées sur Kimi. C'est le dernier garde-fou avant la fusion.
- **Certaines fonctions côté serveur d'Anthropic** (la recherche web, par exemple) peuvent manquer sur Kimi.
- **`/retro`** montre où le modèle bute : refus de hooks répétés, corrections, constats d'`auditor` qui reviennent.
