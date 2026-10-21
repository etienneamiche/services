#Requires -Version 7.4
<#
.SYNOPSIS
    Pose les labels communs sur les dépôts actifs, et crée le GitHub Project unique de l'écosystème.

.DESCRIPTION
    Se relance sans risque : chaque étape vérifie l'état avant d'agir.
    - Labels : les six labels du cadrage sur chaque dépôt `status: active` de repos.yaml,
      créés ou remis au bon format. Les labels créés par défaut par GitHub sont retirés, seulement
      si aucune issue ni PR ne les utilise.
    - Project : « services », privé, avec un champ Status à cinq colonnes (Idée → Fait), et les dépôts
      actifs rattachés. Les colonnes ne sont réécrites que tant que le Project est vide : le faire
      plus tard effacerait le statut des cartes.
    Les automatismes du Project (issue fermée → Fait…) ne s'activent pas par l'API : le script
    rappelle à la fin ceux à activer dans l'interface web.

.EXAMPLE
    ./scripts/github-setup.ps1 -WhatIf     # ce qui serait fait, sans rien changer
    ./scripts/github-setup.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib' 'Services.psm1') -Force

$config = Read-ReposConfig
$owner = $config.owner
if (-not $owner) { throw 'owner vide dans repos.yaml.' }
$repos = @($config.repos | Where-Object { $_.status -eq 'active' })
$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string] $target, [string] $state, [string] $detail = '') {
    $rows.Add([pscustomobject]@{ Cible = $target; Etat = $state; Detail = $detail })
}

$labels = [ordered]@{
    'feature'        = @{ Color = '1D76DB'; Description = 'Nouvelle fonctionnalité' }
    'bug'            = @{ Color = 'D73A4A'; Description = 'Quelque chose ne marche pas' }
    'harness-update' = @{ Color = '5319E7'; Description = 'Mise à jour ou évolution du harness' }
    'infra'          = @{ Color = '0E8A16'; Description = 'Infrastructure et déploiement' }
    'integration'    = @{ Color = 'FBCA04'; Description = "Mise aux normes d'un site existant (/integrate)" }
    'from-users'     = @{ Color = 'C2E0C6'; Description = 'Signalé par un utilisateur (feedback)' }
}
$githubDefaults = 'documentation', 'duplicate', 'enhancement', 'good first issue', 'help wanted', 'invalid', 'question', 'wontfix', 'accessibility'

$statuses = @(
    @{ name = 'Idée'; color = 'GRAY'; description = 'Notée, pas encore spécifiée (/idea)' }
    @{ name = 'Prêt'; color = 'BLUE'; description = 'Spécifiée, critères d''acceptation écrits (/spec)' }
    @{ name = 'En cours'; color = 'YELLOW'; description = 'En développement (/feature)' }
    @{ name = 'En revue'; color = 'PURPLE'; description = 'PR ouverte, revue auditor (/ship, /audit-pr)' }
    @{ name = 'Fait'; color = 'GREEN'; description = 'Fusionnée' }
)
$projectTitle = 'services'

# 1. Labels, dépôt par dépôt.
foreach ($repo in $repos) {
    $full = "$owner/$($repo.name)"
    $existing = @{}
    foreach ($l in (gh label list --repo $full --limit 200 --json name,color,description | ConvertFrom-Json)) { $existing[$l.name] = $l }
    if ($LASTEXITCODE -ne 0) { Add-Row $full 'FAIL' 'lecture des labels impossible'; continue }

    foreach ($name in $labels.Keys) {
        $want = $labels[$name]
        $have = $existing[$name]
        if ($have -and $have.color -eq $want.Color.ToLower() -and $have.description -eq $want.Description) { continue }
        $verb = if ($have) { 'mis au format' } else { 'créé' }
        if ($PSCmdlet.ShouldProcess($full, "label $name ($verb)")) {
            gh label create $name --repo $full --color $want.Color --description $want.Description --force | Out-Null
            if ($LASTEXITCODE -eq 0) { Add-Row $full "label $verb" $name } else { Add-Row $full 'FAIL' "label $name" }
        }
    }

    foreach ($name in $githubDefaults | Where-Object { $existing.ContainsKey($_) }) {
        $used = @(gh issue list --repo $full --label $name --state all --limit 1 --json number | ConvertFrom-Json).Count +
                @(gh pr list --repo $full --label $name --state all --limit 1 --json number | ConvertFrom-Json).Count
        if ($used) { Add-Row $full 'label gardé' "$name (utilisé)"; continue }
        if ($PSCmdlet.ShouldProcess($full, "label $name (retiré, inutilisé)")) {
            gh label delete $name --repo $full --yes | Out-Null
            if ($LASTEXITCODE -eq 0) { Add-Row $full 'label retiré' $name } else { Add-Row $full 'FAIL' "retrait de $name" }
        }
    }
}

# 2. Le Project unique.
$project = (gh project list --owner $owner --limit 100 --format json | ConvertFrom-Json).projects | Where-Object title -eq $projectTitle | Select-Object -First 1
if (-not $project) {
    if ($PSCmdlet.ShouldProcess("$owner/$projectTitle", 'création du Project (privé)')) {
        $project = gh project create --owner $owner --title $projectTitle --format json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $project) { throw 'création du Project impossible.' }
        Add-Row "Project $projectTitle" 'créé' "n° $($project.number)"
    }
}
if ($project) {
    $n = $project.number
    $view = gh api graphql -f query='query($login: String!, $n: Int!) { user(login: $login) { projectV2(number: $n) {
        id public items(first: 1) { totalCount } repositories(first: 100) { nodes { name } }
        field(name: "Status") { ... on ProjectV2SingleSelectField { id options { name } } } } } }' -f login=$owner -F n=$n --jq '.data.user.projectV2' | ConvertFrom-Json

    if ($view.public -and $PSCmdlet.ShouldProcess("Project $projectTitle", 'passage en privé')) {
        gh project edit $n --owner $owner --visibility PRIVATE | Out-Null
        Add-Row "Project $projectTitle" 'rendu privé'
    }

    # Les colonnes : réécrites seulement si elles diffèrent, et seulement sur un Project vide.
    $current = @($view.field.options.name) -join '|'
    $wanted = @($statuses.name) -join '|'
    if ($current -ne $wanted) {
        if ($view.items.totalCount -gt 0) {
            Add-Row "Project $projectTitle" 'WARN' "colonnes à revoir à la main ($current) : le Project a déjà des cartes"
        }
        elseif ($PSCmdlet.ShouldProcess("Project $projectTitle", "colonnes : $($wanted -replace '\|', ' → ')")) {
            $mutation = 'mutation($id: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]!) {
                updateProjectV2Field(input: { fieldId: $id, singleSelectOptions: $options }) { clientMutationId } }'
            $body = @{ query = $mutation; variables = @{ id = $view.field.id; options = $statuses } } | ConvertTo-Json -Depth 5
            $body | gh api graphql --input - | Out-Null
            if ($LASTEXITCODE -eq 0) { Add-Row "Project $projectTitle" 'colonnes posées' ($wanted -replace '\|', ' → ') }
            else { Add-Row "Project $projectTitle" 'FAIL' 'colonnes' }
        }
    }

    $linked = @($view.repositories.nodes.name)
    foreach ($repo in $repos | Where-Object { $linked -notcontains $_.name }) {
        if ($PSCmdlet.ShouldProcess("Project $projectTitle", "rattacher $($repo.name)")) {
            gh project link $n --owner $owner --repo "$owner/$($repo.name)" | Out-Null
            if ($LASTEXITCODE -eq 0) { Add-Row "Project $projectTitle" 'dépôt rattaché' $repo.name } else { Add-Row "Project $projectTitle" 'FAIL' "rattacher $($repo.name)" }
        }
    }
}

if ($rows.Count) { $rows | Format-Table -AutoSize | Out-Host } else { Write-Host 'Rien à faire : labels et Project sont déjà en place.' }
if ($project) {
    Write-Host "Project : n° $($project.number), https://github.com/users/$owner/projects/$($project.number)"
    Write-Host "À activer à la main (Project → Workflows) : « Item closed » et « Pull request merged » → Fait, « Item reopened » → En cours."
}
if ($rows | Where-Object Etat -eq 'FAIL') { exit 1 }
