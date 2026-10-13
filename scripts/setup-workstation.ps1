#Requires -Version 7.4
<#
.SYNOPSIS
    Installe et vérifie les outils du poste pour l'écosystème `services`.

.DESCRIPTION
    Idempotent : peut être relancé sans risque, il n'installe que ce qui manque.
    Voir STARTUP.md pour le déroulé complet.

.PARAMETER Role
    dev   : outils de développement, sans accès à l'infra.
    admin : dev + sops, age, kubectl, tofu, Ansible (WSL) et la clé age du poste.

.PARAMETER Check
    N'installe rien : affiche seulement l'état du poste.

.PARAMETER Upgrade
    Met aussi à jour les outils présents mais sous la version minimale.

.EXAMPLE
    ./scripts/setup-workstation.ps1 -Check
    ./scripts/setup-workstation.ps1 -Role admin -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('dev', 'admin')] [string] $Role = 'dev',
    [switch] $Check,
    [switch] $Upgrade,
    # Renvoie les résultats (objets) au lieu de les afficher : utilisé par harness-doctor.ps1.
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib' 'Services.psm1') -Force

# Name : nom affiché · Cmd : exécutable · Min : version minimale · Roles : profils concernés
# Source : winget:<id> | uvtool:<paquet> | manual:<instruction>
$tools = @(
    @{ Name = 'git';       Cmd = 'git';       Min = '2.45';  Roles = 'dev', 'admin'; Source = 'winget:Git.Git' }
    @{ Name = 'gh';        Cmd = 'gh';        Min = '2.60';  Roles = 'dev', 'admin'; Source = 'winget:GitHub.cli' }
    @{ Name = 'uv';        Cmd = 'uv';        Min = '0.5';   Roles = 'dev', 'admin'; Source = 'winget:astral-sh.uv' }
    @{ Name = 'copier';    Cmd = 'copier';    Min = '9.4';   Roles = 'dev', 'admin'; Source = 'uvtool:copier' }
    @{ Name = 'node';      Cmd = 'node';      Min = '22.0';  Roles = 'dev', 'admin'; Source = 'winget:OpenJS.NodeJS.LTS' }
    @{ Name = 'dotnet';    Cmd = 'dotnet';    Min = '10.0';  Roles = 'dev', 'admin'; Source = 'winget:Microsoft.DotNet.SDK.10' }
    @{ Name = 'docker';    Cmd = 'docker';    Min = '27.0';  Roles = 'dev', 'admin'; Source = 'winget:Docker.DockerDesktop' }
    @{ Name = 'gitleaks';  Cmd = 'gitleaks';  Min = '8.18';  Roles = 'dev', 'admin'; Source = 'winget:Gitleaks.Gitleaks'; Args = @('version') }
    @{ Name = 'git-cliff'; Cmd = 'git-cliff'; Min = '2.0';   Roles = 'dev', 'admin'; Source = 'winget:orhun.git-cliff' }
    @{ Name = 'codegraph'; Cmd = 'codegraph'; Min = '1.6';   Roles = 'dev', 'admin'; Source = 'manual:irm https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.ps1 | iex' }
    @{ Name = 'claude';    Cmd = 'claude';    Min = '2.1';   Roles = 'dev', 'admin'; Source = 'manual:irm https://claude.ai/install.ps1 | iex' }
    @{ Name = 'sops';      Cmd = 'sops';      Min = '3.9';   Roles = 'admin';        Source = 'winget:SecretsOPerationS.SOPS' }
    @{ Name = 'age';       Cmd = 'age';       Min = '1.2';   Roles = 'admin';        Source = 'winget:FiloSottile.age' }
    @{ Name = 'kubectl';   Cmd = 'kubectl';   Min = '1.30';  Roles = 'admin';        Source = 'winget:Kubernetes.kubectl'; Args = @('version', '--client') }
    @{ Name = 'tofu';      Cmd = 'tofu';      Min = '1.8';   Roles = 'admin';        Source = 'winget:OpenTofu.Tofu' }
)

$psModules = @(
    @{ Name = 'powershell-yaml'; Min = '0.4' }
    @{ Name = 'Pester';          Min = '5.5' }
)

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string] $Item, [string] $State, [string] $Detail) {
    $results.Add([pscustomobject]@{ Element = $Item; Etat = $State; Detail = $Detail })
}

function Install-Tool($tool) {
    $kind, $target = $tool.Source -split ':', 2
    switch ($kind) {
        'winget' {
            $verb = if (Get-Command $tool.Cmd -ErrorAction SilentlyContinue) { 'upgrade' } else { 'install' }
            if ($PSCmdlet.ShouldProcess($target, "winget $verb")) {
                winget $verb --id $target --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
                Update-SessionPath
            }
        }
        'uvtool' {
            if ($PSCmdlet.ShouldProcess($target, 'uv tool install')) {
                uv tool install --upgrade $target | Out-Host
                Update-SessionPath
            }
        }
        'manual' { }
    }
}

# --- 1. Outils ------------------------------------------------------------------
foreach ($tool in $tools | Where-Object { $_.Roles -contains $Role }) {
    $versionArgs = if ($tool.ContainsKey('Args')) { $tool.Args } else { @('--version') }
    $current = Get-ToolVersion -Command $tool.Cmd -VersionArgs $versionArgs
    $min = [version] $tool.Min
    $isManual = $tool.Source.StartsWith('manual:')

    $needsAction = (-not $current) -or ($Upgrade -and $current -lt $min)
    if ($needsAction -and -not $Check -and -not $isManual) {
        Install-Tool $tool
        $current = Get-ToolVersion -Command $tool.Cmd -VersionArgs $versionArgs
    }

    if (-not $current) {
        $hint = if ($isManual) { $tool.Source.Substring(7) } else { $tool.Source }
        Add-Result $tool.Name 'FAIL' "absent → $hint"
    }
    elseif ($current -lt $min) {
        Add-Result $tool.Name 'WARN' "$current < $min (relancer avec -Upgrade)"
    }
    else {
        Add-Result $tool.Name 'OK' "$current"
    }
}

# Les outils installés par `uv tool` doivent être dans le PATH.
if (Get-Command uv -ErrorAction SilentlyContinue) {
    $uvBin = (uv tool dir --bin).Trim()
    if (($env:Path -split ';') -notcontains $uvBin) {
        if (-not $Check -and $PSCmdlet.ShouldProcess($uvBin, 'uv tool update-shell')) {
            uv tool update-shell | Out-Host
            Update-SessionPath
        }
        else {
            Add-Result 'PATH uv' 'WARN' "$uvBin absent du PATH (uv tool update-shell)"
        }
    }
}

# --- 2. Modules PowerShell --------------------------------------------------------
foreach ($module in $psModules) {
    $installed = Get-Module -ListAvailable -Name $module.Name |
        Sort-Object Version -Descending | Select-Object -First 1
    if ((-not $installed -or $installed.Version -lt [version] $module.Min) -and -not $Check) {
        if ($PSCmdlet.ShouldProcess($module.Name, 'Install-PSResource')) {
            Install-PSResource -Name $module.Name -Scope CurrentUser -TrustRepository -Reinstall:($null -ne $installed)
            $installed = Get-Module -ListAvailable -Name $module.Name |
                Sort-Object Version -Descending | Select-Object -First 1
        }
    }
    if (-not $installed) { Add-Result "module $($module.Name)" 'FAIL' 'absent' }
    elseif ($installed.Version -lt [version] $module.Min) { Add-Result "module $($module.Name)" 'WARN' "$($installed.Version) < $($module.Min)" }
    else { Add-Result "module $($module.Name)" 'OK' "$($installed.Version)" }
}

# --- 3. Git -----------------------------------------------------------------------
$root = Get-ServicesRoot
$gitName = git -C $root config user.name
$gitEmail = git -C $root config user.email
if (-not $gitName -or -not $gitEmail) {
    Add-Result 'git identité' 'WARN' "user.name='$gitName' user.email='$gitEmail' (voir STARTUP.md §Identité Git)"
}
else {
    Add-Result 'git identité' 'OK' "$gitName <$gitEmail>"
}
if ((git config --global core.longpaths) -ne 'true' -and -not $Check) {
    if ($PSCmdlet.ShouldProcess('core.longpaths', 'git config --global')) {
        git config --global core.longpaths true
    }
}
if ((git config --global core.longpaths) -eq 'true') { Add-Result 'git longpaths' 'OK' 'true' }
else { Add-Result 'git longpaths' 'WARN' 'git config --global core.longpaths true (chemins > 260 caractères)' }

if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh auth status *> $null
    if ($LASTEXITCODE -eq 0) { Add-Result 'gh auth' 'OK' (gh api user --jq .login) }
    else { Add-Result 'gh auth' 'FAIL' 'gh auth login -p ssh -s project (à faire soi-même)' }

    # Git passe par SSH : aucun identifiant HTTPS à stocker.
    if ((gh config get git_protocol) -ne 'ssh' -and -not $Check -and $PSCmdlet.ShouldProcess('gh git_protocol', 'ssh')) {
        gh config set git_protocol ssh
    }
    if ((gh config get git_protocol) -eq 'ssh') { Add-Result 'gh protocole' 'OK' 'ssh' }
    else { Add-Result 'gh protocole' 'WARN' 'gh config set git_protocol ssh' }
}

$sshTest = ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | Out-String
if ($sshTest -match 'successfully authenticated') { Add-Result 'ssh github' 'OK' 'clé reconnue' }
else { Add-Result 'ssh github' 'FAIL' 'aucune clé SSH reconnue par GitHub (voir STARTUP.md §6)' }

if ((git config --global credential.helper) -eq 'store') {
    Add-Result 'git credentials' 'WARN' 'credential.helper=store garde un jeton en clair dans ~/.git-credentials (voir STARTUP.md §6)'
}

# --- 4. Admin : clé age et Ansible ------------------------------------------------
if ($Role -eq 'admin') {
    # Emplacement lu par défaut par sops sous Windows.
    $ageKey = Join-Path $env:APPDATA 'sops' 'age' 'keys.txt'
    if (-not (Test-Path $ageKey) -and -not $Check -and (Get-Command age-keygen -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($ageKey, 'age-keygen')) {
            New-Item -ItemType Directory -Force (Split-Path $ageKey) | Out-Null
            age-keygen -o $ageKey 2>$null
        }
    }
    if (Test-Path $ageKey) {
        $publicKey = age-keygen -y $ageKey
        Add-Result 'clé age' 'OK' "publique : $publicKey (→ add-workstation-key.ps1)"
    }
    else {
        Add-Result 'clé age' 'FAIL' "absente : $ageKey"
    }

    # Ansible ne tourne pas sous Windows : il vit dans WSL Ubuntu, installé par uv (sans sudo).
    # --exec : sinon wsl.exe interprète lui-même les `$` de la commande.
    $env:WSL_UTF8 = '1'
    $ansible = wsl -d Ubuntu --exec bash -lc 'command -v ansible-playbook' 2>$null
    if (-not $ansible -and -not $Check -and $PSCmdlet.ShouldProcess('WSL Ubuntu', 'uv tool install ansible-core')) {
        wsl -d Ubuntu --exec bash -lc 'command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh; "$HOME/.local/bin/uv" tool install ansible-core' | Out-Host
        $ansible = wsl -d Ubuntu --exec bash -lc 'command -v ansible-playbook' 2>$null
    }
    if ($LASTEXITCODE -eq 0 -and $ansible) { Add-Result 'ansible (WSL)' 'OK' $ansible }
    else { Add-Result 'ansible (WSL)' 'FAIL' 'absent dans WSL Ubuntu (voir STARTUP.md §Ansible)' }
}

# --- Bilan ------------------------------------------------------------------------
if ($PassThru) { return $results }
$results | Format-Table -AutoSize | Out-Host
$failed = @($results | Where-Object Etat -eq 'FAIL').Count
$warned = @($results | Where-Object Etat -eq 'WARN').Count
Write-Host ("Profil {0} : {1} échec(s), {2} avertissement(s)." -f $Role, $failed, $warned)
if ($failed -gt 0) { exit 1 }
