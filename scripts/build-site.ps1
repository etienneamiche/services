#Requires -Version 7.4
<#
.SYNOPSIS
    Génère la page d'état de l'écosystème, site/index.html : roadmap, déploiement, commandes, scripts, dépôts, homelab, doc.

.DESCRIPTION
    La page se déduit des sources, sans recopier la doc : docs/ROADMAP.md, repos.yaml, les SKILL.md,
    agents et hooks du harness, le .SYNOPSIS des scripts, homelab/docs/adressage.md et les titres des docs.
    docs/site.yaml ne porte que ce qui ne se déduit de rien (livrables de la phase en cours, étapes de
    déploiement, commandes de terminal). Le travail ouvert est lu par gh, sauf avec -Offline.

    La page contient les adresses du homelab : elle reste sur le poste (site/ n'est pas versionné).
    Ce qui manque ou dérive dans les sources est signalé en fin d'exécution et en bas de la page.

.EXAMPLE
    ./scripts/build-site.ps1
    ./scripts/build-site.ps1 -Offline     # sans gh : pas d'issues ni de PR ouvertes
#>
[CmdletBinding()]
param(
    [switch] $Offline
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib' 'Services.psm1') -Force

$root = Get-ServicesRoot
$config = Read-ReposConfig
$owner = $config.owner
$site = Get-Content (Join-Path $root 'docs' 'site.yaml') -Raw | ConvertFrom-Yaml
$warnings = [System.Collections.Generic.List[string]]::new()
$harnessDir = Join-Path $root 'harness'
$homelabDir = Join-Path $root 'homelab'

# --- Outils ---------------------------------------------------------------------------------------

function Enc([string] $Text) { [Net.WebUtility]::HtmlEncode($Text) }

function Format-Inline([string] $Text) {
    # Le Markdown courant d'une ligne : code, gras, italique ; les liens gardent leur texte.
    $h = Enc $Text
    $h = [regex]::Replace($h, '`([^`]+)`', '<code>$1</code>')
    $h = [regex]::Replace($h, '\*\*(.+?)\*\*', '<strong>$1</strong>')
    $h = [regex]::Replace($h, '(?<![\w*])\*([^*]+)\*(?![\w*])', '<em>$1</em>')
    [regex]::Replace($h, '\[([^\]]+)\]\([^)]+\)', '$1')
}

function Get-FileLink([string] $Path) { 'file:///' + ($Path -replace '\\', '/') }

function Get-Synopsis([string] $File) {
    $text = Get-Content -LiteralPath $File -Raw
    if ($text -match '(?s)\.SYNOPSIS\s*\r?\n(.+?)\r?\n\s*\r?\n') { return ($Matches[1] -replace '\s+', ' ').Trim() }
    $null
}

function Read-Frontmatter([string] $File) {
    $meta = @{}
    $lines = Get-Content -LiteralPath $File
    if ($lines[0] -ne '---') { return $meta }
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if ($line -eq '---') { break }
        if ($line -match '^(\w[\w-]*):\s*(.*)$') { $meta[$Matches[1]] = $Matches[2].Trim('"', ' ') }
    }
    $meta
}

function Get-FirstSentence([string] $Text) {
    $cut = $Text -split ' — |\. ', 2
    $cut[0].TrimEnd('.')
}

function Get-JinjaCondition([string] $Name) {
    # Nom de fichier conditionnel du template : « {% if kind in [...] %}release{% endif %} ».
    if ($Name -notmatch '^\{%\s*if\s+(.+?)\s*%\}(.+?)\{%\s*endif\s*%\}$') { return @{ Name = $Name; When = '' } }
    $cond, $plain = $Matches[1], $Matches[2]
    $when = if ($cond -match "^'(\w+)' in modules$") { "module $($Matches[1])" }
            elseif ($cond -match '^kind in \[(.+)\]$') { 'types ' + (($Matches[1] -replace "'", '') -replace '\s*,\s*', ', ') }
            else { $cond }
    @{ Name = $plain; When = $when }
}

function Get-MdTitle([string] $File) {
    $line = Get-Content -LiteralPath $File | Where-Object { $_ -match '^#\s+' } | Select-Object -First 1
    if ($line) { ($line -replace '^#\s+', '').Trim() } else { [IO.Path]::GetFileNameWithoutExtension($File) }
}

function Get-Badge([string] $State) {
    $label = @{ done = 'fait'; current = 'en cours'; todo = 'à venir' }[$State]
    "<span class=""badge $State"">$label</span>"
}

# --- Roadmap --------------------------------------------------------------------------------------

$roadmapText = Get-Content (Join-Path $root 'docs' 'ROADMAP.md') -Raw
$phases = foreach ($m in [regex]::Matches($roadmapText, '(?m)^\|\s*(\d+)\s*(✅)?\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$')) {
    [pscustomobject]@{ Id = [int] $m.Groups[1].Value; Done = $m.Groups[2].Success; Theme = $m.Groups[3].Value; Deps = $m.Groups[4].Value }
}
$current = ($phases | Where-Object { -not $_.Done } | Select-Object -First 1).Id
$donePhases = @($phases | Where-Object Done | ForEach-Object Id)

$homelabPhases = foreach ($m in [regex]::Matches($roadmapText, '(?m)^\|\s*(H\d)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$')) {
    $state = $m.Groups[4].Value
    $s = if ($state -match '✅') { 'done' } elseif ($state -match '^(À venir|—)$') { 'todo' } else { 'current' }
    [pscustomobject]@{ Id = $m.Groups[1].Value; Theme = $m.Groups[2].Value; Deps = $m.Groups[3].Value; State = $s; Note = ($state -replace '^✅\s*', '') }
}
$homelabDone = @($homelabPhases | Where-Object State -eq 'done' | ForEach-Object Id)

$reserve = @()
$reserveAt = $roadmapText.IndexOf('## En réserve')
if ($reserveAt -ge 0) {
    $reserve = foreach ($m in [regex]::Matches($roadmapText.Substring($reserveAt), '(?m)^\|\s*(\*\*.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$')) {
        [pscustomobject]@{ Subject = $m.Groups[1].Value; Date = $m.Groups[2].Value; Why = $m.Groups[3].Value }
    }
}

# --- Skills, agents, hooks, scripts ---------------------------------------------------------------

$skillDirs = @(
    @{ Scope = 'harness'; Path = Join-Path $harnessDir 'template' '.claude' 'skills' }
    @{ Scope = 'racine'; Path = Join-Path $root '.claude' 'skills' }
)
$skills = foreach ($d in $skillDirs) {
    if (-not (Test-Path -LiteralPath $d.Path)) { continue }
    foreach ($dir in Get-ChildItem -LiteralPath $d.Path -Directory) {
        $file = Join-Path $dir.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $meta = Read-Frontmatter $file
        $cond = Get-JinjaCondition $dir.Name
        [pscustomobject]@{ Name = $(if ($meta.name) { $meta.name } else { $cond.Name }); Scope = $d.Scope; When = $cond.When
                           Summary = Get-FirstSentence $meta.description; File = $file }
    }
}
$skillNames = @($skills | ForEach-Object Name)

if (-not (Test-Path (Join-Path $harnessDir 'template'))) { $warnings.Add('harness absent : pas de skills, d''agents ni de hooks du harness (lancer pull-all.ps1)') }
$agents = foreach ($f in Get-ChildItem -LiteralPath (Join-Path $harnessDir 'template' '.claude' 'agents') -File -Filter '*.md' -ErrorAction SilentlyContinue) {
    $meta = Read-Frontmatter $f.FullName
    $cond = Get-JinjaCondition ($f.Name -replace '\.md$', '')
    [pscustomobject]@{ Name = $meta.name; Model = $meta.model; When = $cond.When; Summary = Get-FirstSentence $meta.description }
}

$hooks = foreach ($f in Get-ChildItem -LiteralPath (Join-Path $harnessDir 'template' '.harness' 'hooks' 'rules') -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue) {
    $first = (Get-Content -LiteralPath $f.FullName -TotalCount 1) -replace '^#\s*', ''
    $name, $what = $first -split '\s*:\s*', 2
    [pscustomobject]@{ Name = $name; Event = $f.Directory.Name; Summary = $what.TrimEnd(',', '.') }
}

$scriptGroups = @(
    @{ Title = 'services/scripts'; Path = Join-Path $root 'scripts' }
    @{ Title = 'Outils du harness (.harness/tools, dans chaque projet)'; Path = Join-Path $harnessDir 'template' '.harness' 'tools' }
    @{ Title = 'harness/tools (développement du harness)'; Path = Join-Path $harnessDir 'tools' }
)
foreach ($g in $scriptGroups) {
    $g.Items = foreach ($f in Get-ChildItem -LiteralPath $g.Path -File -Filter '*.ps1' -ErrorAction SilentlyContinue) {
        $syn = Get-Synopsis $f.FullName
        if (-not $syn) { $warnings.Add("$($g.Title)/$($f.Name) n'a pas de .SYNOPSIS") }
        [pscustomobject]@{ Name = $f.Name; Summary = $syn; File = $f.FullName }
    }
}

# --- Dépôts ---------------------------------------------------------------------------------------

$reposRaw = Get-Content (Join-Path $root 'repos.yaml') -Raw
$repos = foreach ($r in $config.repos) {
    $phase = if ($reposRaw -match "(?s)- name: $([regex]::Escape($r.name))\s.*?status:\s*\w+\s*#\s*phase\s*(\d+)") { $Matches[1] } else { '' }
    $local = Test-Path (Join-Path $r.fullPath '.git')
    $branch = if ($local) { git -C $r.fullPath branch --show-current } else { '' }
    [pscustomobject]@{ Name = $r.name; Kind = $r.kind; Visibility = $r.visibility; Status = $r.status; Phase = $phase
                       Local = $local; Path = $r.fullPath; Branch = $branch }
}
$activeRepos = @($repos | Where-Object Status -eq 'active')

$harnessVersion = if (Test-Path (Join-Path $harnessDir '.git')) { git -C $harnessDir describe --tags --abbrev=0 --match 'v[0-9]*' 2>$null } else { $null }
$harnessAhead = if ($harnessVersion) { git -C $harnessDir rev-list --count "$harnessVersion..HEAD" } else { 0 }

# --- Livrables et déploiement ---------------------------------------------------------------------

function Test-Deliverable($item) {
    if ($item.ContainsKey('done')) { return [bool] $item.done }
    if ($item.skill) { return $skillNames -contains $item.skill }
    if ($item.repo) { return [bool] ($repos | Where-Object { $_.Name -eq $item.repo -and $_.Status -eq 'active' }) }
    if ($item.path) { return Test-Path (Join-Path $root $item.path) }
    if ($item.tag) {
        $dir = ($repos | Where-Object Name -eq $item.tag.repo).Path
        return [bool] ($dir -and (git -C $dir tag --list $item.tag.name 2>$null))
    }
    $warnings.Add("site.yaml : le livrable « $($item.label) » n'a pas de critère (skill, repo, path, tag ou done)")
    $false
}

if ([int] $site.deliverables.phase -ne $current) {
    $warnings.Add("site.yaml : les livrables sont ceux de la phase $($site.deliverables.phase), mais la phase en cours est la $current")
}
$deliverables = foreach ($item in $site.deliverables.items) { [pscustomobject]@{ Label = $item.label; Done = Test-Deliverable $item } }
$delivDone = @($deliverables | Where-Object Done).Count

$knownPhases = @($phases | ForEach-Object Id)
$steps = foreach ($s in $site.deployment.steps) {
    if ($knownPhases -notcontains [int] $s.phase) { $warnings.Add("site.yaml : l'étape « $($s.title) » cite la phase $($s.phase), absente de la roadmap") }
    $state = if (($s.skill -and $skillNames -contains $s.skill) -or $donePhases -contains [int] $s.phase) { 'done' }
             elseif ([int] $s.phase -eq $current) { 'current' } else { 'todo' }
    [pscustomobject]@{ Title = $s.title; Detail = $s.detail; Phase = $s.phase; State = $state }
}

foreach ($group in $site.commands) {
    foreach ($c in $group.items) {
        if ($c.cmd -match '^\./scripts/([\w-]+\.ps1)' -and -not (Test-Path (Join-Path $root 'scripts' $Matches[1]))) {
            $warnings.Add("site.yaml : la commande « $($c.cmd) » cite un script absent")
        }
    }
}

# --- Homelab --------------------------------------------------------------------------------------

# Les services prévus : le tableau de synthèse du catalogue (homelab/docs/01-catalogue-projets.md).
$catalogue = @()
$catalogueFile = Join-Path $homelabDir 'docs' '01-catalogue-projets.md'
if (Test-Path $catalogueFile) {
    $text = Get-Content $catalogueFile -Raw
    $at = $text.IndexOf('## Tableau de synthèse')
    if ($at -ge 0) {
        $block = ($text.Substring($at) -split '(?m)^#{2,3} ', 3)[1]
        $catalogue = foreach ($m in [regex]::Matches($block, '(?m)^\|\s*(\d+)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$')) {
            $project = $m.Groups[2].Value
            $name = if ($project -match '\*\*(.+?)\*\*') { $Matches[1] } else { $project }
            $detail = ($project -replace '\*\*.+?\*\*', '').Trim(' ', ':', '—')
            [pscustomobject]@{ No = [int] $m.Groups[1].Value; Name = $name; Detail = ($detail -replace '^\((.*)\)$', '$1')
                               Cpu = $m.Groups[3].Value; Ram = $m.Groups[4].Value; Disk = $m.Groups[5].Value
                               Unlock = $m.Groups[6].Value; Prio = $(if ($m.Groups[7].Value -match '(P\d)') { $Matches[1] } else { '?' }) }
        }
    }
    if (-not $catalogue) { $warnings.Add('homelab/docs/01-catalogue-projets.md : tableau de synthèse introuvable ou illisible') }
}
else { $warnings.Add('homelab/docs/01-catalogue-projets.md absent : pas de services prévus du homelab') }

$machines = @()
$adressage = Join-Path $homelabDir 'docs' 'adressage.md'
if (Test-Path $adressage) {
    $text = Get-Content $adressage -Raw
    $at = $text.IndexOf('## Attributions')
    if ($at -ge 0) {
        $block = ($text.Substring($at) -split '(?m)^## ', 3)[1]
        $machines = foreach ($m in [regex]::Matches($block, '(?m)^\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$')) {
            $phase = if ($m.Groups[4].Value -match '(H\d)') { $Matches[1] } else { '' }
            $state = if (-not $phase -or $homelabDone -contains $phase) { 'done' } else { 'todo' }
            [pscustomobject]@{ Name = $m.Groups[1].Value; Ip = $m.Groups[2].Value; Role = $m.Groups[3].Value; Phase = $phase; State = $state
                               Guest = $m.Groups[3].Value -match '^(VM|LXC)\b' }
        }
    }
    $gateway = if ($text -match 'passerelle `([^`]+)`') { $Matches[1] } else { '' }
    $network = if ($text -match 'Réseau de la maison : `([^`]+)`') { $Matches[1] } else { '' }
}
else { $warnings.Add('homelab/docs/adressage.md absent : pas de schéma du homelab (dépôt privé non cloné ?)') }

function Get-HomelabSvg {
    if (-not $machines) { return '<p class="muted">Schéma indisponible : <code>homelab/docs/adressage.md</code> introuvable.</p>' }
    $hosts = @($machines | Where-Object { -not $_.Guest })
    $guests = @($machines | Where-Object Guest)
    $w = 270; $h = 64; $gap = 24
    $hostX = { param($i) 20 + $i * ($w + $gap) }
    $width = [math]::Max(20 + $hosts.Count * ($w + $gap), 20 + [math]::Max(1, $guests.Count) * ($w + $gap))
    $height = 120 + $h + 70 + $h + 30
    $sb = [Text.StringBuilder]::new()
    [void] $sb.Append("<svg viewBox=""0 0 $width $height"" role=""img"" aria-label=""Schéma du réseau du homelab"" class=""diagram"">")
    # La box et le réseau.
    [void] $sb.Append("<rect x=""20"" y=""10"" width=""$w"" height=""54"" rx=""8"" class=""node box""/>")
    [void] $sb.Append("<text x=""$(20 + $w / 2)"" y=""33"" class=""t1"">Box</text><text x=""$(20 + $w / 2)"" y=""52"" class=""t2"">$(Enc $gateway)</text>")
    [void] $sb.Append("<line x1=""20"" y1=""92"" x2=""$($width - 20)"" y2=""92"" class=""lan""/>")
    [void] $sb.Append("<line x1=""$(20 + $w / 2)"" y1=""64"" x2=""$(20 + $w / 2)"" y2=""92"" class=""link""/>")
    [void] $sb.Append("<text x=""$($width - 24)"" y=""86"" class=""t2 end"">LAN $(Enc $network)</text>")
    for ($i = 0; $i -lt $hosts.Count; $i++) {
        $m = $hosts[$i]; $x = & $hostX $i; $y = 120
        [void] $sb.Append("<line x1=""$($x + $w / 2)"" y1=""92"" x2=""$($x + $w / 2)"" y2=""$y"" class=""link""/>")
        [void] $sb.Append("<rect x=""$x"" y=""$y"" width=""$w"" height=""$h"" rx=""8"" class=""node $($m.State)""/>")
        [void] $sb.Append("<text x=""$($x + $w / 2)"" y=""$($y + 24)"" class=""t1"">$(Enc $m.Name) · $(Enc $m.Ip)</text>")
        [void] $sb.Append("<text x=""$($x + $w / 2)"" y=""$($y + 44)"" class=""t2"">$(Enc ($m.Role -replace '\s*\(.*\)$', ''))$(if ($m.Phase) { ' · ' + $m.Phase })</text>")
    }
    if ($guests) {
        # Les VM et conteneurs vivent sur le premier hyperviseur.
        $parentX = (& $hostX 0) + $w / 2
        $gy = 120 + $h + 70
        [void] $sb.Append("<line x1=""$parentX"" y1=""$(120 + $h)"" x2=""$parentX"" y2=""$($gy - 20)"" class=""link""/>")
        [void] $sb.Append("<line x1=""$(20 + $w / 2)"" y1=""$($gy - 20)"" x2=""$(20 + ($guests.Count - 1) * ($w + $gap) + $w / 2)"" y2=""$($gy - 20)"" class=""link""/>")
        for ($i = 0; $i -lt $guests.Count; $i++) {
            $m = $guests[$i]; $x = 20 + $i * ($w + $gap)
            [void] $sb.Append("<line x1=""$($x + $w / 2)"" y1=""$($gy - 20)"" x2=""$($x + $w / 2)"" y2=""$gy"" class=""link""/>")
            [void] $sb.Append("<rect x=""$x"" y=""$gy"" width=""$w"" height=""$h"" rx=""8"" class=""node $($m.State)""/>")
            [void] $sb.Append("<text x=""$($x + $w / 2)"" y=""$($gy + 24)"" class=""t1"">$(Enc $m.Name) · $(Enc $m.Ip)</text>")
            [void] $sb.Append("<text x=""$($x + $w / 2)"" y=""$($gy + 44)"" class=""t2"">$(Enc ($m.Role -replace '`', ''))$(if ($m.Phase) { ' · ' + $m.Phase })</text>")
        }
        [void] $sb.Append("<text x=""$($parentX + 8)"" y=""$($gy - 28)"" class=""t2 start"">hébergés par $(Enc $hosts[0].Name)</text>")
    }
    [void] $sb.Append('</svg>')
    $sb.ToString()
}

# --- Travail ouvert (gh) --------------------------------------------------------------------------

$openWork = @()
$openNote = ''
if ($Offline) { $openNote = 'Page générée avec -Offline : issues et PR non lues.' }
elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) { $openNote = 'gh absent : issues et PR non lues.' }
else {
    # Le bac à sable ne porte que des fixtures d'évaluation : il n'est pas du travail ouvert.
    $openWork = foreach ($r in $activeRepos | Where-Object Kind -ne 'sandbox') {
        $issues = gh issue list -R "$owner/$($r.Name)" --state open --json number,title,url,labels --limit 100 2>$null | ConvertFrom-Json
        $prs = gh pr list -R "$owner/$($r.Name)" --state open --json number,title,url,headRefName --limit 50 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -and -not $issues -and -not $prs) { $warnings.Add("gh n'a pas pu lire $($r.Name)"); continue }
        [pscustomobject]@{ Repo = $r.Name; Issues = @($issues); Prs = @($prs) }
    }
}

# --- Page -----------------------------------------------------------------------------------------

$servicesPct = [math]::Round((($donePhases.Count + $(if ($deliverables) { $delivDone / @($deliverables).Count } else { 0 })) / @($phases).Count) * 100)
$homelabPct = [math]::Round(($homelabDone.Count / [math]::Max(1, @($homelabPhases).Count)) * 100)
$currentPhase = $phases | Where-Object Id -eq $current
$generated = Get-Date -Format 'yyyy-MM-dd HH:mm'

$html = [Text.StringBuilder]::new()
function Out-Html([string] $Text) { [void] $html.AppendLine($Text) }

$navItems = @(
    @('roadmap', 'Roadmap'), @('ouvert', 'Travail ouvert'), @('deploiement', 'Déploiement'), @('commandes', 'Commandes'),
    @('scripts', 'Scripts'), @('agents', 'Agents et hooks'), @('depots', 'Dépôts'), @('homelab', 'Homelab'), @('catalogue', 'Services du homelab'),
    @('doc', 'Documentation'), @('reserve', 'En réserve')
)
if ($warnings.Count) { $navItems += , @('a-completer', 'À compléter') }
$nav = ($navItems | ForEach-Object -Begin { $n = 0 } -Process { $n++; "<a href=""#$($_[0])"" data-sec=""$($_[0])""><span class=""idx"">$('{0:00}' -f $n)</span>$(Enc $_[1])<span class=""hits""></span></a>" }) -join ''

Out-Html @"
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>État de services</title>
<style>
:root {
  --bg:#f6f7f9; --panel:#ffffff; --side:#fbfbfc; --fg:#111827; --fg2:#374151; --muted:#6b7280; --line:#e5e7eb; --line2:#d1d5db;
  --accent:#2563eb; --accent-soft:#eff4ff; --hover:#f3f4f6; --code:#f3f4f6;
  --done:#15803d; --current:#b45309; --todo:#6b7280;
  --mono:ui-monospace,"Cascadia Code","JetBrains Mono",Consolas,"SFMono-Regular",monospace;
  --sans:"Inter","Segoe UI Variable","Segoe UI",system-ui,-apple-system,sans-serif;
}
@media (prefers-color-scheme: dark) { :root {
  --bg:#0b0d10; --panel:#111418; --side:#0e1114; --fg:#e5e7eb; --fg2:#c4c8cf; --muted:#8b929c; --line:#1f242b; --line2:#2b313a;
  --accent:#60a5fa; --accent-soft:#132033; --hover:#161a20; --code:#171b21;
  --done:#4ade80; --current:#fbbf24; --todo:#8b929c;
} }
* { box-sizing:border-box; }
[hidden] { display:none !important; }
html { scroll-padding-top:16px; }
body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.55 var(--sans); -webkit-font-smoothing:antialiased; }
a { color:var(--accent); text-decoration:none; } a:hover { text-decoration:underline; }
code, kbd, .mono { font-family:var(--mono); font-size:12.5px; }
code { background:var(--code); border:1px solid var(--line); padding:0 5px; border-radius:4px; color:var(--fg2); }
.muted { color:var(--muted); }

.shell { display:grid; grid-template-columns:260px minmax(0,1fr); min-height:100vh; }
.side { position:sticky; top:0; height:100vh; overflow-y:auto; background:var(--side); border-right:1px solid var(--line); padding:18px 14px; display:flex; flex-direction:column; gap:14px; }
.brand { display:flex; align-items:center; gap:8px; font-weight:650; letter-spacing:-.01em; }
.brand .logo { width:22px; height:22px; border-radius:6px; background:var(--accent); display:grid; place-items:center; color:#fff; font:700 12px var(--mono); }
.brand .tag { margin-left:auto; font:500 11px var(--mono); color:var(--muted); border:1px solid var(--line2); border-radius:4px; padding:0 5px; }
.search { position:relative; display:block; }
.search input { width:100%; font:13px var(--sans); color:var(--fg); background:var(--panel); border:1px solid var(--line2); border-radius:6px; padding:7px 34px 7px 10px; outline:none; }
.search input:focus { border-color:var(--accent); box-shadow:0 0 0 3px var(--accent-soft); }
.search kbd { position:absolute; right:7px; top:50%; transform:translateY(-50%); color:var(--muted); border:1px solid var(--line2); border-bottom-width:2px; border-radius:4px; padding:0 5px; font-size:11px; background:var(--side); }
.qcount { font:12px var(--mono); color:var(--muted); min-height:16px; margin-top:-6px; }
.menu summary { display:none; }
.menu nav { display:flex; flex-direction:column; gap:1px; }
.menu nav a { display:flex; align-items:center; gap:10px; padding:6px 8px; border-radius:6px; color:var(--fg2); font-size:13.5px; }
.menu nav a:hover { background:var(--hover); text-decoration:none; color:var(--fg); }
.menu nav a.dim { opacity:.35; }
.menu .idx { font:11px var(--mono); color:var(--muted); width:18px; }
.menu .hits { margin-left:auto; font:11px var(--mono); color:var(--accent); }
.meta { margin-top:auto; font:11.5px/1.6 var(--mono); color:var(--muted); border-top:1px solid var(--line); padding-top:12px; }

main { padding:28px 32px 40px; max-width:1180px; width:100%; }
.top h1 { margin:0; font-size:22px; letter-spacing:-.02em; font-weight:650; }
.top .sub { color:var(--muted); margin:4px 0 18px; }
.kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:1px; background:var(--line); border:1px solid var(--line); border-radius:8px; overflow:hidden; }
.kpi { background:var(--panel); padding:14px 16px; }
.kpi .label { font:500 11px var(--mono); text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
.kpi .value { font:600 24px/1.3 var(--sans); letter-spacing:-.02em; font-variant-numeric:tabular-nums; margin:4px 0 2px; }
.kpi .detail { color:var(--muted); font-size:12.5px; }
.bar { height:4px; background:var(--line); border-radius:2px; overflow:hidden; margin-top:10px; }
.bar i { display:block; height:100%; background:var(--accent); }

main { counter-reset:sec; }
section { background:var(--panel); border:1px solid var(--line); border-radius:8px; margin:20px 0; scroll-margin-top:16px; }
section > h2 { counter-increment:sec; margin:0; padding:12px 16px; border-bottom:1px solid var(--line); font-size:14px; font-weight:600; display:flex; align-items:center; gap:10px; }
section > h2::before { content:counter(sec, decimal-leading-zero); font:500 11px var(--mono); color:var(--muted); border:1px solid var(--line2); border-radius:4px; padding:0 5px; }
section > :not(h2) { margin-left:16px; margin-right:16px; }
section > :last-child { margin-bottom:16px; }
section > p.muted { font-size:12.5px; margin-top:12px; }
h3 { font:500 11px var(--mono); text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:18px 16px 8px; }

.table { overflow-x:auto; border:1px solid var(--line); border-radius:6px; }
table { border-collapse:collapse; width:100%; font-size:13px; }
th { font:500 11px var(--mono); text-transform:uppercase; letter-spacing:.05em; color:var(--muted); text-align:left; padding:8px 10px; background:var(--side); border-bottom:1px solid var(--line); white-space:nowrap; }
td { padding:7px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
tr:last-child td { border-bottom:0; }
tr:hover td { background:var(--hover); }
td:first-child { white-space:nowrap; }

.badge { display:inline-flex; align-items:center; gap:6px; font:500 11.5px var(--mono); white-space:nowrap; color:var(--todo); }
.badge::before { content:""; width:7px; height:7px; border-radius:50%; background:currentColor; }
.badge.done { color:var(--done); } .badge.current { color:var(--current); } .badge.current::before { box-shadow:0 0 0 3px color-mix(in srgb, currentColor 25%, transparent); }

ul { padding-left:18px; } li { margin:3px 0; }
ul.check { list-style:none; padding:0; display:grid; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:2px 16px; }
ul.check li { display:flex; gap:10px; align-items:baseline; }
ul.check .badge { width:78px; flex:none; }

.flow { display:grid; grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); gap:10px; margin-top:12px; }
.step { position:relative; border:1px solid var(--line); border-radius:6px; padding:10px 12px 10px 14px; background:var(--panel); }
.step::before { content:""; position:absolute; left:0; top:8px; bottom:8px; width:3px; border-radius:2px; background:var(--todo); opacity:.5; }
.step.done::before { background:var(--done); opacity:1; } .step.current::before { background:var(--current); opacity:1; }
.step b { display:flex; gap:8px; font-weight:600; font-size:13.5px; }
.step .n { font:500 11px/1.9 var(--mono); color:var(--muted); }
.step small { display:flex; gap:10px; color:var(--muted); font:11.5px var(--mono); margin:2px 0 6px; }
.step div { color:var(--fg2); font-size:12.5px; }

.diagram { width:100%; min-width:640px; height:auto; display:block; font-family:var(--mono); }
.diagram .node { fill:var(--panel); stroke:var(--line2); stroke-width:1.2; } .diagram .node.done { stroke:var(--done); } .diagram .node.todo { stroke:var(--todo); stroke-dasharray:4 4; }
.diagram .node.box { stroke:var(--accent); } .diagram .lan { stroke:var(--accent); stroke-width:2; } .diagram .link { stroke:var(--line2); stroke-width:1.2; }
.diagram text { fill:var(--fg); text-anchor:middle; } .diagram .t1 { font-size:13px; font-weight:600; } .diagram .t2 { font-size:11px; fill:var(--muted); } .diagram .start { text-anchor:start; } .diagram .end { text-anchor:end; }
section .table:has(> .diagram) { padding:12px; margin-top:12px; }
.warn { border-color:var(--current); } .warn > h2 { color:var(--current); }
.empty { text-align:center; color:var(--muted); padding:40px 0; font:13px var(--mono); }
footer { color:var(--muted); font-size:12px; margin-top:24px; }

@media (max-width: 900px) {
  .shell { grid-template-columns:minmax(0,1fr); }
  .side, main { min-width:0; }
  .side { position:sticky; top:0; z-index:5; height:auto; overflow:visible; flex-direction:row; flex-wrap:wrap; align-items:center; gap:8px 10px; padding:10px 12px; border-right:0; border-bottom:1px solid var(--line); }
  .brand { order:1; } .brand .tag { display:none; }
  .menu { order:2; margin-left:auto; position:relative; }
  .menu summary { display:block; list-style:none; cursor:pointer; font:500 12px var(--mono); color:var(--fg2); border:1px solid var(--line2); border-radius:6px; padding:5px 10px; background:var(--panel); }
  .menu summary::-webkit-details-marker { display:none; }
  .menu[open] nav { position:absolute; z-index:10; right:0; top:calc(100% + 6px); width:min(280px, calc(100vw - 24px)); background:var(--panel); border:1px solid var(--line2); border-radius:8px; padding:6px; box-shadow:0 10px 30px rgba(0,0,0,.18); }
  .search { order:3; flex:1 1 100%; }
  .qcount { order:4; flex:1 1 100%; margin:0; min-height:0; }
  .meta { display:none; }
  main { padding:16px 12px 32px; }
  .kpis { grid-template-columns:repeat(2,minmax(0,1fr)); } .kpi { padding:12px; } .kpi .value { font-size:20px; }
  section > :not(h2) { margin-left:12px; margin-right:12px; } h3 { margin-left:12px; }
}
</style>
</head>
<body>
<div class="shell">
<aside class="side">
<div class="brand"><span class="logo">S</span>services<span class="tag">état</span></div>
<label class="search"><input id="q" type="search" placeholder="Rechercher dans la page…" autocomplete="off" spellcheck="false" aria-label="Rechercher dans la page"><kbd>/</kbd></label>
<div id="qcount" class="qcount" aria-live="polite"></div>
<details class="menu" id="menu"><summary>Sections</summary><nav>$nav</nav></details>
<div class="meta">Généré le $generated<br>scripts/build-site.ps1<br>source : docs/site.yaml + dépôts</div>
</aside>
<main>
<header class="top">
<h1>État de l'écosystème services</h1>
<div class="sub">Point d'entrée : chaque section renvoie vers la doc qui fait foi.</div>
<div class="kpis">
<div class="kpi"><div class="label">Phase en cours</div><div class="value">Phase $current</div><div class="detail">$(Format-Inline $currentPhase.Theme)</div></div>
<div class="kpi"><div class="label">Roadmap services</div><div class="value">$servicesPct %</div><div class="detail">$($donePhases.Count)/$(@($phases).Count) phases · phase $current : $delivDone/$(@($deliverables).Count) livrables</div><div class="bar"><i style="width:$servicesPct%"></i></div></div>
<div class="kpi"><div class="label">Piste homelab</div><div class="value">$homelabPct %</div><div class="detail">$($homelabDone.Count)/$(@($homelabPhases).Count) phases</div><div class="bar"><i style="width:$homelabPct%"></i></div></div>
<div class="kpi"><div class="label">Harness</div><div class="value">$(if ($harnessVersion) { Enc $harnessVersion } else { '—' })</div><div class="detail">$harnessAhead commit(s) depuis cette version</div></div>
</div>
</header>
<div id="empty" class="empty" hidden>Aucun résultat.</div>
"@

# Roadmap
Out-Html '<section id="roadmap"><h2>Roadmap</h2>'
Out-Html "<p class=""muted"">Source : <a href=""$(Get-FileLink (Join-Path $root 'docs\ROADMAP.md'))"">docs/ROADMAP.md</a>, phases et critères de sortie.</p>"
Out-Html '<div class="table"><table><tr><th>Phase</th><th>Thème</th><th>Dépend de</th><th>État</th></tr>'
foreach ($p in $phases) {
    $state = if ($p.Done) { 'done' } elseif ($p.Id -eq $current) { 'current' } else { 'todo' }
    Out-Html "<tr><td>$($p.Id)</td><td>$(Format-Inline $p.Theme)</td><td>$(Format-Inline $p.Deps)</td><td>$(Get-Badge $state)</td></tr>"
}
Out-Html '</table></div>'
Out-Html "<h3>Phase $current : livrables ($delivDone sur $(@($deliverables).Count))</h3><ul class=""check"">"
foreach ($d in $deliverables) { Out-Html "<li>$(if ($d.Done) { Get-Badge 'done' } else { Get-Badge 'todo' }) $(Format-Inline $d.Label)</li>" }
Out-Html '</ul><h3>Piste homelab</h3><div class="table"><table><tr><th>Phase</th><th>Thème</th><th>Dépend de</th><th>État</th></tr>'
foreach ($p in $homelabPhases) {
    $note = if ($p.State -eq 'done' -and $p.Note) { "<br><small class=""muted"">$(Format-Inline $p.Note)</small>" } else { '' }
    Out-Html "<tr><td>$($p.Id)</td><td>$(Format-Inline $p.Theme)$note</td><td>$(Format-Inline $p.Deps)</td><td>$(Get-Badge $p.State)</td></tr>"
}
Out-Html '</table></div></section>'

# Travail ouvert
Out-Html '<section id="ouvert"><h2>Travail ouvert</h2>'
if ($openNote) { Out-Html "<p class=""muted"">$(Enc $openNote)</p>" }
foreach ($w in $openWork) {
    if (-not $w.Issues -and -not $w.Prs) { continue }
    Out-Html "<h3>$(Enc $w.Repo) <span class=""muted"">· $(@($w.Issues).Count) issue(s), $(@($w.Prs).Count) PR</span></h3><ul>"
    foreach ($pr in $w.Prs) { Out-Html "<li>PR <a href=""$($pr.url)"">#$($pr.number)</a> $(Enc $pr.title) <code>$(Enc $pr.headRefName)</code></li>" }
    foreach ($i in $w.Issues) {
        $labels = ($i.labels | ForEach-Object { "<code>$(Enc $_.name)</code>" }) -join ' '
        Out-Html "<li><a href=""$($i.url)"">#$($i.number)</a> $(Enc $i.title) $labels</li>"
    }
    Out-Html '</ul>'
}
if (-not $openNote -and -not ($openWork | Where-Object { $_.Issues -or $_.Prs })) { Out-Html '<p class="muted">Aucune issue ni PR ouverte.</p>' }
Out-Html '</section>'

# Déploiement
$deployDoc = Join-Path $root ($site.deployment.doc -replace '/', '\')
Out-Html '<section id="deploiement"><h2>Du travail à la production</h2>'
Out-Html "<p class=""muted"">Le détail fait foi dans <a href=""$(Get-FileLink $deployDoc)"">$(Enc $site.deployment.doc)</a>, $(Enc $site.deployment.section). Une étape est faite quand son skill existe ou que sa phase est terminée.</p><div class=""flow"">"
$stepNo = 0
foreach ($s in $steps) { $stepNo++; Out-Html "<div class=""step $($s.State)""><b><span class=""n"">$('{0:00}' -f $stepNo)</span>$(Format-Inline $s.Title)</b><small>Phase $($s.Phase) · $(Get-Badge $s.State)</small><div>$(Format-Inline $s.Detail)</div></div>" }
Out-Html '</div></section>'

# Commandes
Out-Html '<section id="commandes"><h2>Commandes</h2><h3>Skills (dans Claude Code)</h3><div class="table"><table><tr><th>Skill</th><th>Ce qu''il fait</th><th>Où</th></tr>'
foreach ($s in $skills | Sort-Object Scope, Name) {
    $where = if ($s.When) { "$($s.Scope), $(Enc $s.When)" } else { $s.Scope }
    Out-Html "<tr><td><a href=""$(Get-FileLink $s.File)""><code>/$(Enc $s.Name)</code></a></td><td>$(Format-Inline $s.Summary)</td><td>$where</td></tr>"
}
Out-Html '</table></div>'
foreach ($group in $site.commands) {
    Out-Html "<h3>$(Enc $group.group)</h3><div class=""table""><table><tr><th>Commande</th><th>Ce qu'elle fait</th></tr>"
    foreach ($c in $group.items) {
        $doc = if ($c.doc) { " <span class=""muted"">(voir $(Enc $c.doc))</span>" } else { '' }
        Out-Html "<tr><td><code>$(Enc $c.cmd)</code></td><td>$(Format-Inline $c.what)$doc</td></tr>"
    }
    Out-Html '</table></div>'
}
Out-Html '</section>'

# Scripts
Out-Html '<section id="scripts"><h2>Scripts</h2>'
foreach ($g in $scriptGroups) {
    if (-not $g.Items) { continue }
    Out-Html "<h3>$(Enc $g.Title)</h3><div class=""table""><table><tr><th>Script</th><th>Rôle (.SYNOPSIS)</th></tr>"
    foreach ($s in $g.Items) { Out-Html "<tr><td><a href=""$(Get-FileLink $s.File)""><code>$(Enc $s.Name)</code></a></td><td>$(if ($s.Summary) { Format-Inline $s.Summary } else { '<span class="muted">sans .SYNOPSIS</span>' })</td></tr>" }
    Out-Html '</table></div>'
}
Out-Html '</section>'

# Agents et hooks
Out-Html '<section id="agents"><h2>Agents et hooks du harness</h2><div class="table"><table><tr><th>Agent</th><th>Modèle</th><th>Rôle</th></tr>'
foreach ($a in $agents | Sort-Object Model, Name) {
    $when = if ($a.When) { " <span class=""muted"">($(Enc $a.When))</span>" } else { '' }
    Out-Html "<tr><td><code>$(Enc $a.Name)</code>$when</td><td>$(Enc $a.Model)</td><td>$(Format-Inline $a.Summary)</td></tr>"
}
Out-Html '</table></div><h3>Hooks</h3><div class="table"><table><tr><th>Hook</th><th>Événement</th><th>Rôle</th></tr>'
foreach ($h in $hooks | Sort-Object Event, Name) { Out-Html "<tr><td><code>$(Enc $h.Name)</code></td><td>$(Enc $h.Event)</td><td>$(Format-Inline $h.Summary)</td></tr>" }
Out-Html '</table></div></section>'

# Dépôts
Out-Html '<section id="depots"><h2>Dépôts</h2>'
Out-Html "<p class=""muted"">Source : <a href=""$(Get-FileLink (Join-Path $root 'repos.yaml'))"">repos.yaml</a>.</p><div class=""table""><table><tr><th>Dépôt</th><th>Type</th><th>Visibilité</th><th>État</th><th>Local</th></tr>"
foreach ($r in $repos) {
    $state = if ($r.Status -eq 'active') { Get-Badge 'done' } else { "$(Get-Badge 'todo') <span class=""muted"">phase $($r.Phase)</span>" }
    $gh = if ($r.Status -eq 'active') { "<a href=""https://github.com/$owner/$($r.Name)"">$(Enc $r.Name)</a>" } else { Enc $r.Name }
    $local = if ($r.Local) { "<a href=""$(Get-FileLink $r.Path)"">$(Enc $r.Path)</a> <code>$(Enc $r.Branch)</code>" } else { '<span class="muted">—</span>' }
    Out-Html "<tr><td>$gh</td><td>$(Enc $r.Kind)</td><td>$(Enc $r.Visibility)</td><td>$state</td><td>$local</td></tr>"
}
Out-Html '</table></div></section>'

# Homelab
Out-Html '<section id="homelab"><h2>Architecture du homelab</h2>'
Out-Html "<p class=""muted"">Source : <a href=""$(Get-FileLink $adressage)"">homelab/docs/adressage.md</a>. Les clusters, l'exposition et GitOps : <a href=""$(Get-FileLink (Join-Path $homelabDir 'docs\07-plateforme-k3s-gitops.md'))"">doc 07</a> ; les composants : <a href=""$(Get-FileLink (Join-Path $homelabDir 'ARCHITECTURE.md'))"">ARCHITECTURE.md</a>. Trait plein : en service ; pointillé : à venir.</p>"
Out-Html "<div class=""table"">$(Get-HomelabSvg)</div>"
if ($machines) {
    Out-Html '<div class="table"><table><tr><th>Machine</th><th>IP</th><th>Rôle</th><th>Arrive en</th></tr>'
    foreach ($m in $machines) { Out-Html "<tr><td><code>$(Enc $m.Name)</code></td><td>$(Enc $m.Ip)</td><td>$(Format-Inline $m.Role)</td><td>$(if ($m.Phase) { "$($m.Phase) $(Get-Badge $m.State)" } else { '—' })</td></tr>" }
    Out-Html '</table></div>'
}
Out-Html '</section>'

# Services prévus du homelab
Out-Html '<section id="catalogue"><h2>Services prévus du homelab</h2>'
Out-Html "<p class=""muted"">Source : <a href=""$(Get-FileLink $catalogueFile)"">homelab/docs/01-catalogue-projets.md</a>, tableau de synthèse : ressources, matériel et priorité de chaque projet. Le découpage en phases H1 à H5 est dans <a href=""$(Get-FileLink (Join-Path $homelabDir 'docs\03-roadmap.md'))"">doc 03</a>. P0 : socle de H1 ; P3 : plus tard, souvent avec du matériel en plus.</p>"
if ($catalogue) {
    $prioLabels = @{ P0 = 'P0 · socle'; P1 = 'P1 · prioritaire'; P2 = 'P2 · ensuite'; P3 = 'P3 · plus tard' }
    foreach ($group in $catalogue | Group-Object Prio | Sort-Object Name) {
        $label = if ($prioLabels[$group.Name]) { $prioLabels[$group.Name] } else { $group.Name }
        Out-Html "<h3>$(Enc $label) · $($group.Count)</h3><div class=""table""><table><tr><th>#</th><th>Projet</th><th>Ressources</th><th>Débloqué par</th></tr>"
        foreach ($c in $group.Group) {
            $detail = if ($c.Detail) { "<br><small class=""muted"">$(Format-Inline $c.Detail)</small>" } else { '' }
            Out-Html "<tr><td class=""mono"">$($c.No)</td><td><strong>$(Format-Inline $c.Name)</strong>$detail</td><td class=""mono"">$(Enc "$($c.Cpu) vCPU · $($c.Ram) · $($c.Disk)")</td><td>$(Format-Inline $c.Unlock)</td></tr>"
        }
        Out-Html '</table></div>'
    }
}
Out-Html '</section>'

# Documentation
Out-Html '<section id="doc"><h2>Documentation</h2><p class="muted">Les documents qui font foi, par dépôt : le titre, puis le fichier.</p>'
foreach ($r in $activeRepos) {
    if (-not $r.Local) { continue }
    $files = @(Get-ChildItem -LiteralPath $r.Path -File -Filter '*.md' | Where-Object Name -in 'README.md', 'STARTUP.md', 'ARCHITECTURE.md', 'AGENTS.md', 'CHANGELOG.md')
    $docsDir = Join-Path $r.Path 'docs'
    if (Test-Path $docsDir) { $files += @(Get-ChildItem -LiteralPath $docsDir -File -Recurse -Filter '*.md') }
    if (-not $files) { continue }
    Out-Html "<h3>$(Enc $r.Name)</h3><div class=""table""><table><tr><th>Document</th><th>Fichier</th></tr>"
    foreach ($f in $files) {
        $rel = [IO.Path]::GetRelativePath($r.Path, $f.FullName) -replace '\\', '/'
        Out-Html "<tr><td>$(Format-Inline (Get-MdTitle $f.FullName))</td><td><a href=""$(Get-FileLink $f.FullName)""><code>$(Enc $rel)</code></a></td></tr>"
    }
    Out-Html '</table></div>'
}
Out-Html '</section>'

# En réserve
Out-Html '<section id="reserve"><h2>En réserve</h2><p class="muted">Sujets écartés volontairement, à reprendre par <code>/evolve</code> (docs/ROADMAP.md).</p><div class="table"><table><tr><th>Sujet</th><th>Décidé le</th><th>Pourquoi plus tard</th></tr>'
foreach ($r in $reserve) { Out-Html "<tr><td>$(Format-Inline $r.Subject)</td><td>$(Enc $r.Date)</td><td>$(Format-Inline $r.Why)</td></tr>" }
Out-Html '</table></div></section>'

if ($warnings.Count) {
    Out-Html '<section id="a-completer" class="warn"><h2>À compléter dans les sources</h2><ul>'
    foreach ($w in $warnings) { Out-Html "<li>$(Format-Inline $w)</li>" }
    Out-Html '</ul></section>'
}
Out-Html @'
<footer>Données : <code>docs/site.yaml</code> pour ce qui ne se déduit d'aucune source ; le reste est lu dans les dépôts. La page contient les adresses du homelab : elle reste sur le poste.</footer>
</main>
</div>
<script>
(() => {
  const norm = s => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const q = document.getElementById('q'), count = document.getElementById('qcount'), empty = document.getElementById('empty');
  const menu = document.getElementById('menu'), wide = matchMedia('(min-width: 901px)');
  const sections = [...document.querySelectorAll('main section')];
  const items = sections.flatMap(s => [...s.querySelectorAll('tr, ul > li, .step')].filter(e => !e.querySelector('th')).map(e => ({ e, s, t: norm(e.textContent) })));
  const titles = new Map(sections.map(s => [s, norm(s.querySelector('h2').textContent)]));
  const links = new Map([...document.querySelectorAll('.menu nav a')].map(a => [a.dataset.sec, a]));

  const syncMenu = () => { menu.open = wide.matches; };
  syncMenu(); wide.addEventListener('change', syncMenu);
  document.querySelectorAll('.menu nav a').forEach(a => a.addEventListener('click', () => { if (!wide.matches) menu.open = false; }));

  function apply() {
    const terms = norm(q.value).split(/\s+/).filter(Boolean);
    const hits = new Map(sections.map(s => [s, 0]));
    for (const it of items) {
      const ok = !terms.length || terms.every(t => it.t.includes(t)) || terms.every(t => titles.get(it.s).includes(t));
      it.e.hidden = !ok;
      if (ok) hits.set(it.s, hits.get(it.s) + 1);
    }
    let total = 0, shown = 0;
    for (const s of sections) {
      const n = hits.get(s), keep = !terms.length || n > 0;
      s.hidden = !keep; total += terms.length ? n : 0; if (keep) shown++;
      // Blocs vidés par le filtre : tableau sans ligne, liste sans élément, intertitre sans contenu.
      s.querySelectorAll('.table, ul, .flow').forEach(b => {
        const rows = [...b.querySelectorAll('tr, li, .step')].filter(e => !e.querySelector('th'));
        b.hidden = terms.length > 0 && rows.length > 0 && rows.every(e => e.hidden);
      });
      s.querySelectorAll('h3').forEach(h => { const next = h.nextElementSibling; h.hidden = !!next && next.hidden; });
      const a = links.get(s.id);
      if (a) { a.classList.toggle('dim', !keep); a.querySelector('.hits').textContent = terms.length && n ? n : ''; }
    }
    count.textContent = terms.length ? `${total} résultat${total > 1 ? 's' : ''} · ${shown} section${shown > 1 ? 's' : ''}` : '';
    empty.hidden = !terms.length || shown > 0;
  }
  q.addEventListener('input', apply);
  addEventListener('keydown', e => {
    if (e.key === '/' && document.activeElement !== q) { e.preventDefault(); q.focus(); q.select(); }
    else if (e.key === 'Escape' && document.activeElement === q) { q.value = ''; apply(); q.blur(); }
  });
})();
</script>
</body>
</html>
'@

$outDir = Join-Path $root 'site'
New-Item -ItemType Directory -Force $outDir | Out-Null
$outFile = Join-Path $outDir 'index.html'
[IO.File]::WriteAllText($outFile, $html.ToString(), [Text.UTF8Encoding]::new($false))

Write-Host "Page générée : $outFile"
foreach ($w in $warnings) { Write-Host "  à compléter : $w" -ForegroundColor Yellow }
