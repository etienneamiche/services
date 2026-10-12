#Requires -Version 7.4
# Fonctions partagées par les scripts racine de `services`.

Set-StrictMode -Version Latest

# Sortie en UTF-8 quel que soit le terminal appelant (accents de nos messages et de winget).
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Get-ServicesRoot {
    # scripts/lib/ → racine du dépôt services
    (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
}

function Read-ReposConfig {
    param([string] $Root = (Get-ServicesRoot))

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "Module 'powershell-yaml' absent. Lancer scripts/setup-workstation.ps1."
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $file = Join-Path $Root 'repos.yaml'
    $config = Get-Content $file -Raw | ConvertFrom-Yaml
    foreach ($repo in $config.repos) {
        if (-not $repo.ContainsKey('path')) { $repo.path = $repo.name }
        $repo.fullPath = [IO.Path]::GetFullPath((Join-Path $Root $repo.path))
    }
    $config
}

function Update-SessionPath {
    # Recharge le PATH après une installation, sans rouvrir le terminal.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Get-ToolVersion {
    # Renvoie la première version x.y[.z] trouvée dans la sortie de la commande, ou $null.
    param(
        [Parameter(Mandatory)] [string] $Command,
        [string[]] $VersionArgs = @('--version')
    )
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { return $null }
    $output = try { & $Command @VersionArgs 2>&1 | Out-String } catch { '' }
    if ($output -match '(\d+\.\d+(\.\d+)?)') { return [version] $Matches[1] }
    [version] '0.0'
}

Export-ModuleMember -Function Get-ServicesRoot, Read-ReposConfig, Update-SessionPath, Get-ToolVersion
