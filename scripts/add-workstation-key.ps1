#Requires -Version 7.4
<#
.SYNOPSIS
    Donne à un poste l'accès aux secrets SOPS de homelab, ou le lui retire.

.DESCRIPTION
    À lancer depuis un poste qui a DÉJÀ l'accès (STARTUP.md §8) :
      1. ajoute (ou retire) la clé publique age du poste dans homelab/.sops.yaml ;
      2. rechiffre chaque secret existant pour le nouvel ensemble de clés (sops updatekeys).
    La clé privée du poste ne transite jamais : seule sa clé publique est utilisée.
    La clé homelab des clusters (doc 07 §9 de homelab), notée « # homelab » dans .sops.yaml,
    ne se gère pas par ce script : il refuse de la retirer, et ne la compte pas comme un poste.
    Le résultat est une modification de homelab, à commiter par une PR.

.PARAMETER PublicKey
    Clé publique age du poste (age1…), affichée par setup-workstation.ps1 -Role admin.

.PARAMETER Name
    Nom du poste, gardé en commentaire dans .sops.yaml (ex. : fixe-bureau, portable).

.PARAMETER Remove
    Retire la clé (poste perdu ou abandonné), puis rechiffre.

.EXAMPLE
    ./scripts/add-workstation-key.ps1 -PublicKey age1abc… -Name portable
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidatePattern('^age1[0-9a-z]{58}$')] [string] $PublicKey,
    [Parameter(Mandatory)] [ValidatePattern('^[\w-]+$')] [ValidateScript({ $_ -ne 'homelab' }, ErrorMessage = 'homelab est réservé à la clé des clusters.')] [string] $Name,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib' 'Services.psm1') -Force
$homelab = Join-Path (Get-ServicesRoot) 'homelab'
$sopsConfig = Join-Path $homelab '.sops.yaml'
if (-not (Test-Path (Join-Path $homelab '.git'))) { throw "homelab n'est pas cloné ($homelab) : lancer pull-all.ps1." }

# Structure : une liste YAML de clés, une par ligne, chacune suivie du nom du poste en commentaire.
# Chiffre secrets/**/*.sops.yaml en entier (conventions du module infra) : un secret aux clés à plat
# (OpenTofu, Ansible) resterait en clair avec une règle limitée à data et stringData.
# Le motif accepte / et \ : sous Windows, sops compare le chemin tel qu'il est écrit.
$keyIndent = '          '
if (-not (Test-Path $sopsConfig)) {
    if ($Remove) { throw '.sops.yaml absent : aucune clé à retirer.' }
    $initial = @(
        '# Clés age qui déchiffrent les secrets : une par poste (services/scripts/add-workstation-key.ps1), et la clé homelab des clusters.'
        '# Un fichier de secrets est chiffré en entier (conventions du module infra).'
        '# SOPS applique la première règle qui correspond : la future règle des manifestes Secret de Kubernetes (data et stringData seulement) se pose avant celle-ci.'
        'creation_rules:'
        '  - path_regex: secrets[/\\].*\.sops\.ya?ml$'
        '    key_groups:'
        '      - age:'
        "$keyIndent- $PublicKey # $Name"
    )
    if ($PSCmdlet.ShouldProcess($sopsConfig, 'création')) { Set-Content $sopsConfig $initial -Encoding utf8NoBOM }
    Write-Host "Créé : $sopsConfig, avec la clé de '$Name'. Ajouter aussi la clé publique homelab des clusters (« - age1… # homelab »), puis commiter dans homelab par une PR."
    return
}

$lines = [Collections.Generic.List[string]] @(Get-Content $sopsConfig)
$keyLines = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s+-\s+age1[0-9a-z]{58}' })
if (-not $keyLines) { throw ".sops.yaml n'a pas la structure attendue (key_groups → age : liste de clés)." }
$present = @($keyLines | Where-Object { $lines[$_] -match [regex]::Escape($PublicKey) })
# La clé homelab des clusters n'est pas une clé de poste.
$isHomelab = { param($i) $lines[$i] -match '#\s*homelab\s*$' }
$workstations = @($keyLines | Where-Object { -not (& $isHomelab $_) })

if ($Remove) {
    if (-not $present) { Write-Host 'Clé absente de .sops.yaml : rien à faire.'; return }
    if (& $isHomelab $present[0]) { throw 'Refus : la clé homelab des clusters ne se retire pas par ce script.' }
    if ($workstations.Count -le 1) { throw 'Refus : ce serait la dernière clé de poste, plus aucun poste ne pourrait déchiffrer.' }
    if ($PSCmdlet.ShouldProcess($PublicKey, 'retrait de .sops.yaml')) { $lines.RemoveAt($present[0]) }
}
else {
    if ($present) { Write-Host 'Clé déjà présente dans .sops.yaml : rien à faire.'; return }
    $indent = $lines[$keyLines[-1]] -replace '^(\s+)-.*', '$1'
    if ($PSCmdlet.ShouldProcess($PublicKey, 'ajout dans .sops.yaml')) { $lines.Insert($keyLines[-1] + 1, "$indent- $PublicKey # $Name") }
}
if (-not $WhatIfPreference) { Set-Content $sopsConfig $lines -Encoding utf8NoBOM }

# Rechiffrement de chaque secret pour le nouvel ensemble de clés.
# `updatekeys` aligne les destinataires du fichier sur .sops.yaml (ajout ou retrait d'accès).
# Au retrait, `rotate` génère en plus une NOUVELLE clé de données : sans ça, un poste retiré qui
# a déjà déchiffré un secret connaît la clé de données et lirait les versions suivantes.
# L'ordre compte : `rotate` rechiffre pour les destinataires inscrits dans le fichier.
$secrets = @(Get-ChildItem (Join-Path $homelab 'secrets') -Recurse -Include *.sops.yaml, *.sops.yml -ErrorAction SilentlyContinue)
# sops cherche .sops.yaml à partir du dossier courant, pas de celui du fichier : on se place dans homelab.
Push-Location $homelab
try {
    foreach ($file in $secrets) {
        if ($PSCmdlet.ShouldProcess($file.Name, 'sops updatekeys')) {
            sops updatekeys --yes $file.FullName
            if ($LASTEXITCODE -ne 0) { throw "sops updatekeys a échoué sur $($file.Name)" }
        }
        if ($Remove -and $PSCmdlet.ShouldProcess($file.Name, 'sops rotate')) {
            sops rotate --in-place $file.FullName
            if ($LASTEXITCODE -ne 0) { throw "sops rotate a échoué sur $($file.Name)" }
        }
    }
}
finally { Pop-Location }
Write-Host "$(if ($Remove) { 'Retiré' } else { 'Ajouté' }) : '$Name'. $($secrets.Count) secret(s) rechiffré(s). À commiter dans homelab par une PR."
if ($Remove) { Write-Host "⚠️ L'historique Git garde d'anciennes versions des secrets lisibles avec cette clé : si le poste est compromis, changer les secrets eux-mêmes." }
