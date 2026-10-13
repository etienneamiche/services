#Requires -Version 7.4
<#
.SYNOPSIS
    Doctor de l'écosystème : le poste, la racine `services` et chaque dépôt.

.DESCRIPTION
    Trois niveaux (cadrage §18) :
      - poste  : setup-workstation.ps1 -Check (profil admin si une clé age existe) ;
      - racine : liste blanche du .gitignore, repos.yaml cohérent avec GitHub, dépôts clonés ;
      - dépôts : le doctor de chaque dépôt qui a le harness (.harness/tools/doctor.ps1).

.PARAMETER Fix
    Transmis aux doctors des dépôts (réparations sans risque).

.PARAMETER Deep
    Transmis aux doctors des dépôts (autotests Pester).

.PARAMETER Offline
    Aucun accès réseau : ni GitHub, ni dernière version du harness.
#>
[CmdletBinding()]
param([switch] $Fix, [switch] $Deep, [switch] $Offline)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib' 'Services.psm1') -Force
$root = Get-ServicesRoot
$config = Read-ReposConfig
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string] $Level, [string] $Item, [string] $State, [string] $Detail = '') {
    $results.Add([pscustomobject]@{ Niveau = $Level; Controle = $Item; Etat = $State; Detail = $Detail })
}

# --- Poste ------------------------------------------------------------------------
$role = if (Test-Path (Join-Path $env:APPDATA 'sops' 'age' 'keys.txt')) { 'admin' } else { 'dev' }
$poste = @(& (Join-Path $PSScriptRoot 'setup-workstation.ps1') -Check -Role $role -PassThru)
$posteProblems = @($poste | Where-Object Etat -ne 'OK')
if (-not $posteProblems) { Add-Result 'poste' "outils (profil $role)" 'OK' "$($poste.Count) contrôles" }
foreach ($p in $posteProblems) { Add-Result 'poste' $p.Element $p.Etat $p.Detail }

# Le CLI claude a sa propre connexion, distincte de l'app desktop, et elle expire (spike phase 1).
if (-not $Offline -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    $auth = try { claude auth status 2>$null | Out-String | ConvertFrom-Json } catch { $null }
    if ($auth -and $auth.loggedIn) { Add-Result 'poste' 'CLI claude connecté' 'OK' $auth.authMethod }
    else { Add-Result 'poste' 'CLI claude connecté' 'WARN' "lancer 'claude' puis /login" }
}

# --- Racine -----------------------------------------------------------------------
# Liste blanche : rien d'autre que le harness racine n'est suivi par services.
$allowed = @(Get-Content (Join-Path $root '.gitignore') | Where-Object { $_ -match '^!/' } | ForEach-Object { $_.Substring(2).TrimEnd('/') })
$tracked = @(git -C $root ls-files)
$intruders = @($tracked | Where-Object { $first = ($_ -split '/')[0]; $allowed -notcontains $first })
if ($intruders) { Add-Result 'racine' 'liste blanche' 'FAIL' "fichiers suivis hors liste : $($intruders | Select-Object -First 5)" }
else { Add-Result 'racine' 'liste blanche' 'OK' "$($tracked.Count) fichiers suivis, tous autorisés" }

foreach ($repo in $config.repos | Where-Object { $_.status -eq 'active' }) {
    $name = $repo.name
    if (-not (Test-Path (Join-Path $repo.fullPath '.git'))) { Add-Result 'racine' $name 'FAIL' 'non cloné (pull-all.ps1)'; continue }
    if (-not $Offline) {
        $remote = gh repo view "$($config.owner)/$name" --json visibility --jq .visibility 2>$null
        if (-not $remote) { Add-Result 'racine' $name 'FAIL' 'introuvable sur GitHub'; continue }
        if ($remote.ToLower() -ne $repo.visibility) { Add-Result 'racine' $name 'FAIL' "visibilité $($remote.ToLower()) sur GitHub, $($repo.visibility) attendue"; continue }
    }
    $dirty = @(git -C $repo.fullPath status --porcelain).Count
    Add-Result 'racine' $name ($dirty ? 'WARN' : 'OK') ($dirty ? "$dirty fichier(s) modifié(s)" : 'cloné, propre')
}

# --- Dépôts équipés du harness ----------------------------------------------------
foreach ($repo in $config.repos | Where-Object { $_.status -eq 'active' }) {
    $doctor = Join-Path $repo.fullPath '.harness' 'tools' 'doctor.ps1'
    if (-not (Test-Path $doctor)) { continue }
    $repoArgs = @('-Quiet')
    if ($Fix) { $repoArgs += '-Fix' }
    if ($Deep) { $repoArgs += '-Deep' }
    if ($Offline) { $repoArgs += '-Offline' }
    $output = pwsh -NoProfile -File $doctor @repoArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $summary = ($output.Trim() -split "`n")[-1].Trim()
    Add-Result 'dépôt' $repo.name ($code -eq 0 ? ($summary -match ' 0 avertissement' ? 'OK' : 'WARN') : 'FAIL') $summary
}

# --- Bilan ------------------------------------------------------------------------
$results | Format-Table -AutoSize -Wrap | Out-Host
$failed = @($results | Where-Object Etat -eq 'FAIL').Count
Write-Host ("Écosystème : {0} échec(s), {1} avertissement(s)." -f $failed, @($results | Where-Object Etat -eq 'WARN').Count)
exit ([int]($failed -gt 0))
