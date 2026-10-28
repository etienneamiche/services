#Requires -Version 7.4

<#
.SYNOPSIS
    Lance Claude Code sur Kimi (abonnement Kimi Code) quand les crédits Claude sont épuisés, avec le même harness.

.DESCRIPTION
    Claude Code reste l'outil : les hooks (git-guard, secret-guard, model-guard…), les skills, les agents et la
    mémoire de projet sont les mêmes. Seul le modèle change, par l'API compatible Anthropic de Kimi.

    Claude Code ne charge que le harness du dossier où il est lancé : lancer ce script depuis le dépôt où l'on
    travaille (par exemple C:\repo\services\scripts\claude-kimi.ps1 depuis homelab). La racine services n'a pas
    encore de harness (phase 9) : une session lancée là n'a ni hooks ni agents, et le script le signale.

    Les alias opus, sonnet et haiku pointent vers des modèles Kimi : les modèles imposés par le harness
    (opus pour dev, architect et auditor, haiku pour les autres agents) restent valides.

    La clé se lit dans la variable d'environnement utilisateur KIMI_API_KEY (voir STARTUP.md) ; elle n'est jamais
    affichée ni écrite. Les variables ne valent que pour la session lancée : le terminal retrouve son état
    d'avant à la sortie de Claude Code.

.PARAMETER Model
    Modèle Kimi de la session et des alias opus et sonnet. Par défaut : $env:KIMI_MODEL, sinon kimi-k3.1-pro.
    L'identifiant exact se vérifie dans la console Kimi Code.

.PARAMETER FastModel
    Modèle Kimi de l'alias haiku (agents légers : git-ops, reviewer, linter…). Par défaut : $env:KIMI_FAST_MODEL,
    sinon le même que -Model.

.PARAMETER BaseUrl
    Adresse de l'API compatible Anthropic. Par défaut : $env:KIMI_BASE_URL, sinon https://api.kimi.com/coding/
    (abonnement Kimi Code). Pour un paiement au jeton : https://api.moonshot.ai/anthropic.

.PARAMETER Check
    Montre la configuration, sans la clé, et dit si le dossier courant a un harness, puis s'arrête sans lancer
    Claude Code.

.PARAMETER Probe
    Envoie une requête minimale (1 jeton) à l'API avec la clé, l'adresse et le modèle, et n'affiche que le statut
    HTTP et, en cas d'erreur, son type et son message : de quoi vérifier l'adresse et l'identifiant du modèle
    avant une vraie session. Puis s'arrête sans lancer Claude Code.

.PARAMETER ClaudeArgs
    Arguments passés tels quels à `claude`. Une option longue passe seule (--continue) ; une option courte
    (-p, -c) se place après `--`, sinon PowerShell la prend pour un paramètre du script.

.EXAMPLE
    ./scripts/claude-kimi.ps1 -Check
    ./scripts/claude-kimi.ps1 -Probe
    C:\repo\services\scripts\claude-kimi.ps1                # depuis le dépôt où l'on travaille
    ./scripts/claude-kimi.ps1 --continue
    ./scripts/claude-kimi.ps1 -Model kimi-k3 -- -p "résume la roadmap"
#>
# Pas de liaison par position : un argument libre (--continue) va à claude, pas à -Model.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string] $Model = $(if ($env:KIMI_MODEL) { $env:KIMI_MODEL } else { 'kimi-k3.1-pro' }),
    [string] $FastModel = $(if ($env:KIMI_FAST_MODEL) { $env:KIMI_FAST_MODEL } else { '' }),
    [string] $BaseUrl = $(if ($env:KIMI_BASE_URL) { $env:KIMI_BASE_URL } else { 'https://api.kimi.com/coding/' }),
    [switch] $Check,
    [switch] $Probe,
    [Parameter(ValueFromRemainingArguments)] [string[]] $ClaudeArgs
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib' 'Services.psm1') -Force

if (-not $FastModel) { $FastModel = $Model }
# La variable de la session d'abord (un essai ponctuel), puis celle de l'utilisateur.
$key = if ($env:KIMI_API_KEY) { $env:KIMI_API_KEY } else { [Environment]::GetEnvironmentVariable('KIMI_API_KEY', 'User') }
$claude = Get-Command claude -ErrorAction SilentlyContinue
# Claude Code ne charge que le harness du dossier où il est lancé (hooks, agents, skills).
$harness = Test-Path (Join-Path (Get-Location) '.claude' 'settings.json')
$noHarness = "pas de .claude/settings.json dans $(Get-Location) : ni hooks ni agents du harness. Lancer depuis le dépôt où l'on travaille."

# ANTHROPIC_API_KEY est vidée : sinon elle passerait avant la clé Kimi.
$vars = [ordered]@{
    ANTHROPIC_BASE_URL             = $BaseUrl
    ANTHROPIC_AUTH_TOKEN           = $key
    ANTHROPIC_API_KEY              = $null
    ANTHROPIC_MODEL                = $Model
    ANTHROPIC_DEFAULT_OPUS_MODEL   = $Model
    ANTHROPIC_DEFAULT_SONNET_MODEL = $Model
    ANTHROPIC_DEFAULT_HAIKU_MODEL  = $FastModel
    ANTHROPIC_SMALL_FAST_MODEL     = $FastModel
}

if ($Check) {
    foreach ($name in $vars.Keys) {
        $shown = if ($name -eq 'ANTHROPIC_AUTH_TOKEN') { if ($key) { "définie ($($key.Length) caractères)" } else { 'ABSENTE' } }
                 elseif ($null -eq $vars[$name]) { '(vidée pour la session)' } else { $vars[$name] }
        '{0,-32} {1}' -f $name, $shown
    }
    '{0,-32} {1}' -f 'claude', $(if ($claude) { $claude.Source } else { 'ABSENT' })
    '{0,-32} {1}' -f 'harness (dossier courant)', $(if ($harness) { 'présent' } else { "ABSENT — $noHarness" })
    if (-not $key -or -not $claude) { exit 1 }
    exit 0
}

if ($Probe) {
    if (-not $key) { Write-Host 'claude-kimi : KIMI_API_KEY absente, pas de requête.' -ForegroundColor Red; exit 1 }
    # Le même chemin que Claude Code : l'adresse de base suivie de /v1/messages.
    $uri = $BaseUrl.TrimEnd('/') + '/v1/messages'
    $body = @{ model = $Model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'ping' }) } | ConvertTo-Json -Depth 4
    $headers = @{ Authorization = "Bearer $key"; 'anthropic-version' = '2023-06-01' }
    try {
        $r = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -SkipHttpErrorCheck -TimeoutSec 30
    }
    catch { Write-Host "claude-kimi : $uri injoignable ($($_.Exception.Message))" -ForegroundColor Red; exit 1 }
    # Seuls le statut, le modèle rendu ou l'erreur sont affichés : jamais la clé ni les en-têtes.
    $data = try { $r.Content | ConvertFrom-Json } catch { $null }
    $detail = if ($r.StatusCode -lt 300) { "modèle rendu : $($data.model)" }
              elseif ($data.error) { "$($data.error.type) : $($data.error.message)" }
              else { ([string] $r.Content).Substring(0, [Math]::Min(200, ([string] $r.Content).Length)) }
    $color = if ($r.StatusCode -lt 300) { 'Green' } else { 'Red' }
    Write-Host "POST $uri ($Model) → HTTP $($r.StatusCode) — $detail" -ForegroundColor $color
    exit $(if ($r.StatusCode -lt 300) { 0 } else { 1 })
}

if (-not $key) {
    Write-Host "claude-kimi : KIMI_API_KEY absente. La poser une fois, sans qu'elle passe par l'historique (STARTUP.md) :" -ForegroundColor Red
    Write-Host "  [Environment]::SetEnvironmentVariable('KIMI_API_KEY', (Read-Host 'Clé Kimi Code' -MaskInput), 'User')"
    exit 1
}
if (-not $claude) { Write-Host 'claude-kimi : Claude Code (claude) introuvable dans le PATH.' -ForegroundColor Red; exit 1 }

Write-Host "Claude Code sur Kimi : $Model (agents légers : $FastModel), $BaseUrl" -ForegroundColor Cyan
if (-not $harness) { Write-Warning $noHarness }
# Les variables ne valent que pour cette session : leur valeur d'avant est remise à la sortie.
$saved = @{}
foreach ($name in $vars.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    foreach ($name in $vars.Keys) { [Environment]::SetEnvironmentVariable($name, $vars[$name], 'Process') }
    & $claude.Source @ClaudeArgs
    $code = $LASTEXITCODE
}
finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
exit $code
