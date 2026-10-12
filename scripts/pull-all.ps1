#Requires -Version 7.4
<#
.SYNOPSIS
    Clone les dépôts manquants de repos.yaml et met à jour les autres.

.DESCRIPTION
    Ne fait jamais que des `pull --ff-only`, et seulement sur un dépôt propre.
    Un dépôt modifié, en avance ou divergent est signalé, jamais touché.
    Les dépôts `status: planned` sont ignorés.

.EXAMPLE
    ./scripts/pull-all.ps1
    ./scripts/pull-all.ps1 -NoFetch     # état local seulement, sans réseau
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $NoFetch
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib' 'Services.psm1') -Force

$config = Read-ReposConfig
$owner = $config.owner
$rows = [System.Collections.Generic.List[object]]::new()

function Add-Row($repo, [string] $state, [string] $detail = '') {
    $branch = if (Test-Path (Join-Path $repo.fullPath '.git')) { git -C $repo.fullPath branch --show-current } else { '' }
    $rows.Add([pscustomobject]@{ Depot = $repo.name; Branche = $branch; Etat = $state; Detail = $detail })
}

foreach ($repo in $config.repos | Where-Object { $_.status -eq 'active' }) {
    $path = $repo.fullPath

    # 1. Absent : on clone.
    if (-not (Test-Path (Join-Path $path '.git'))) {
        if (-not $owner) { Add-Row $repo 'FAIL' "owner vide dans repos.yaml"; continue }
        if ((Test-Path $path) -and (Get-ChildItem $path -Force | Select-Object -First 1)) {
            Add-Row $repo 'FAIL' "$path existe, n'est pas un dépôt Git et n'est pas vide"; continue
        }
        if ($PSCmdlet.ShouldProcess("$owner/$($repo.name)", "gh repo clone → $path")) {
            gh repo clone "$owner/$($repo.name)" $path -- --quiet
            if ($LASTEXITCODE -ne 0) { Add-Row $repo 'FAIL' 'échec du clonage'; continue }
            git -C $path config core.longpaths true
            Add-Row $repo 'cloné'
        }
        continue
    }

    # 2. Présent : on regarde avant de toucher.
    if (-not (git -C $path remote)) { Add-Row $repo 'local' 'aucun remote'; continue }

    if (-not $NoFetch) {
        git -C $path fetch --quiet --prune 2>$null
        if ($LASTEXITCODE -ne 0) { Add-Row $repo 'FAIL' 'échec du fetch'; continue }
    }

    $dirty = git -C $path status --porcelain
    $upstream = git -C $path rev-parse --abbrev-ref '@{upstream}' 2>$null
    if (-not $upstream) { Add-Row $repo 'sans upstream' 'branche non suivie'; continue }

    $counts = (git -C $path rev-list --left-right --count "HEAD...$upstream") -split '\s+'
    $ahead, $behind = [int] $counts[0], [int] $counts[1]

    if ($dirty) { Add-Row $repo 'modifié' "$(@($dirty).Count) fichier(s), en retard de $behind"; continue }
    if ($ahead -gt 0 -and $behind -gt 0) { Add-Row $repo 'divergé' "+$ahead / -$behind"; continue }
    if ($ahead -gt 0) { Add-Row $repo 'en avance' "+$ahead à pousser"; continue }
    if ($behind -eq 0) { Add-Row $repo 'à jour'; continue }

    if ($PSCmdlet.ShouldProcess($repo.name, "git pull --ff-only (-$behind)")) {
        git -C $path pull --ff-only --quiet
        if ($LASTEXITCODE -eq 0) { Add-Row $repo 'mis à jour' "-$behind" }
        else { Add-Row $repo 'FAIL' 'échec du pull' }
    }
}

$rows | Format-Table -AutoSize | Out-Host
$planned = @($config.repos | Where-Object { $_.status -eq 'planned' }).Count
Write-Host "$planned dépôt(s) prévu(s), ignoré(s)."
if ($rows | Where-Object Etat -eq 'FAIL') { exit 1 }
