#Requires -Version 7.4
<#
.SYNOPSIS
    Donne à un poste l'accès aux secrets SOPS de homelab, ou le lui retire.

.DESCRIPTION
    À lancer depuis un poste qui a DÉJÀ l'accès (STARTUP.md §8) :
      1. ajoute (ou retire) la clé publique age du poste dans chaque règle de homelab/.sops.yaml ;
      2. rechiffre chaque secret qui ne l'est pas encore : sops updatekeys à l'ajout, sops rotate --rm-age au retrait.
         Après un échec, relancer la même commande termine le travail.
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
    if ($PSCmdlet.ShouldProcess($sopsConfig, 'création')) {
        Set-Content $sopsConfig $initial -Encoding utf8NoBOM
        Write-Host "Créé : $sopsConfig, avec la clé de '$Name'. Ajouter aussi la clé publique homelab des clusters (« - age1… # homelab »), puis commiter dans homelab par une PR."
    }
    return
}

$lines = [Collections.Generic.List[string]] @(Get-Content $sopsConfig)
$escaped = [regex]::Escape($PublicKey)
# La clé homelab des clusters (commentaire « # homelab ») n'est pas une clé de poste.
$isHomelab = { param([string] $Line) $Line -match '#\s*homelab(\s|\(|$)' }

# Une liste de clés par règle de chiffrement : chaque suite de lignes « - age1… » consécutives
# (creation_rules → key_groups → age). Une ligne vide ou de commentaire ne coupe pas la liste.
$blocks = [Collections.Generic.List[object]]::new()
$current = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s+-\s+age1[0-9a-z]{58}') {
        if (-not $current) { $current = [Collections.Generic.List[int]]::new(); $blocks.Add($current) }
        $current.Add($i)
    }
    elseif ($lines[$i] -notmatch '^\s*(#.*)?$') { $current = $null }
}
if (-not $blocks.Count) { throw ".sops.yaml n'a pas la structure attendue (key_groups → age : liste de clés)." }

$configChanged = $false
if ($Remove) {
    if (@($lines | Where-Object { $_ -match $escaped -and (& $isHomelab $_) })) { throw 'Refus : la clé homelab des clusters ne se retire pas par ce script.' }
    # Chaque règle doit garder au moins une clé de poste, sinon plus aucun poste ne déchiffre ses fichiers.
    foreach ($block in $blocks) {
        $left = @($block | Where-Object { $lines[$_] -notmatch $escaped -and -not (& $isHomelab $lines[$_]) })
        if (-not $left) { throw 'Refus : une règle de .sops.yaml n''aurait plus aucune clé de poste, plus aucun poste ne pourrait déchiffrer ses fichiers.' }
    }
    # Toutes les occurrences, dans toutes les règles.
    $toRemove = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match "^\s+-\s+$escaped" })
    if ($toRemove -and $PSCmdlet.ShouldProcess($PublicKey, "retrait de .sops.yaml ($($toRemove.Count) ligne(s))")) {
        foreach ($i in ($toRemove | Sort-Object -Descending)) { $lines.RemoveAt($i) }
        $configChanged = $true
    }
}
else {
    # La clé va dans chaque règle qui ne l'a pas : de la dernière à la première, pour garder les indices.
    $missing = @($blocks | Where-Object { -not @($_ | Where-Object { $lines[$_] -match $escaped }) })
    if ($missing -and $PSCmdlet.ShouldProcess($PublicKey, "ajout dans .sops.yaml ($($missing.Count) règle(s))")) {
        foreach ($block in ($missing | Sort-Object { $_[-1] } -Descending)) {
            $indent = $lines[$block[-1]] -replace '^(\s+)-.*', '$1'
            $lines.Insert($block[-1] + 1, "$indent- $PublicKey # $Name")
        }
        $configChanged = $true
    }
}
if ($configChanged) { Set-Content $sopsConfig $lines -Encoding utf8NoBOM }

# Rechiffrement, fichier par fichier, de ceux qui ne sont pas encore à jour : une relance après un
# échec termine le travail au lieu de répondre « rien à faire ».
# - Ajout : `updatekeys` aligne les destinataires du fichier sur .sops.yaml.
# - Retrait : `rotate --rm-age` retire le destinataire ET génère une nouvelle clé de données, en une
#   seule écriture : sans nouvelle clé, un poste retiré qui a déjà déchiffré un secret lirait les
#   versions suivantes.
$secrets = @(Get-ChildItem (Join-Path $homelab 'secrets') -Recurse -Include *.sops.yaml, *.sops.yml -ErrorAction SilentlyContinue)
$recipients = { param([string] $Path) [regex]::Matches((Get-Content $Path -Raw), 'recipient:\s*(age1[0-9a-z]{58})') | ForEach-Object { $_.Groups[1].Value } }
$pending = @($secrets | Where-Object { $has = @(& $recipients $_.FullName) -contains $PublicKey; if ($Remove) { $has } else { -not $has } })

if (-not $configChanged -and -not $pending) {
    Write-Host "$(if ($Remove) { 'Clé absente' } else { 'Clé déjà présente' }) de .sops.yaml et des $($secrets.Count) secret(s) : rien à faire."
    return
}

# sops cherche .sops.yaml à partir du dossier courant, pas de celui du fichier : on se place dans homelab.
$done = 0
Push-Location $homelab
try {
    foreach ($file in $pending) {
        $action = if ($Remove) { 'sops rotate --rm-age' } else { 'sops updatekeys' }
        if (-not $PSCmdlet.ShouldProcess($file.Name, $action)) { continue }
        if ($Remove) { sops rotate --in-place --rm-age $PublicKey $file.FullName }
        else { sops updatekeys --yes $file.FullName }
        if ($LASTEXITCODE -ne 0) {
            throw "$action a échoué sur $($file.Name) : $($pending.Count - $done) secret(s) restent à rechiffrer. Corriger la cause, puis relancer la même commande pour terminer."
        }
        $done++
    }
}
finally { Pop-Location }

if ($WhatIfPreference) { Write-Host 'Simulation : rien n''a été écrit.'; return }
Write-Host "$(if ($Remove) { 'Retiré' } else { 'Ajouté' }) : '$Name'. $done secret(s) rechiffré(s). À commiter dans homelab par une PR."
if ($Remove) { Write-Host "⚠️ L'historique Git garde d'anciennes versions des secrets lisibles avec cette clé : si le poste est compromis, changer les secrets eux-mêmes." }
