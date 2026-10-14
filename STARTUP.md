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
