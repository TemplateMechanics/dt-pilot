<#
.SYNOPSIS
    Sanity-check a Monaco workspace: verify Monaco is installed, the manifest
    exists, and every project referenced by the manifest is present on disk.

.DESCRIPTION
    The Monaco CLI itself has no 'init' subcommand -- there is nothing to
    download or cache up front. This wrapper takes the place of that step
    by validating the harness pre-conditions and giving the user a clear,
    early error if something is wrong before they run dry-run or deploy.

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).

.PARAMETER MonacoExe
    Override the Monaco executable lookup. See Get-MonacoVersion.ps1.

.EXAMPLE
    ./scripts/monaco/Initialize-MonacoWorkspace.ps1 -Path examples/baseline-stack
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $MonacoExe
)

. "$PSScriptRoot/_Common.ps1"

$exe = Resolve-MonacoExe -MonacoExe $MonacoExe
$manifest = Resolve-ManifestPath -Path $Path
$manifestDir = Split-Path -Parent $manifest

Write-Host "Monaco:   $exe"
Write-Host "Manifest: $manifest"

# Light schema parse: read manifestVersion + project names without taking a
# YAML dependency. Monaco itself will give the authoritative validation; we
# just want a friendly fail-fast for the common pre-condition mistakes.
$content = Get-Content -LiteralPath $manifest -Raw
if ($content -notmatch '(?m)^\s*manifestVersion\s*:') {
    throw "manifest.yaml is missing a 'manifestVersion' field: $manifest"
}

# Walk the projects: section. We don't reuse Get-ManifestProjectDirs here
# because that helper only returns directories that already resolve on disk
# -- this script needs the project name -> resolved-path mapping so it can
# emit a precise error for each missing project. The walker honors
# `projects[].path` overrides and the bare-name + 'projects/<name>/'
# fallbacks identically to the helper.
$projectInfos = @()
$inProjects = $false
$currentName = $null
$currentPath = $null
foreach ($line in (Get-Content -LiteralPath $manifest)) {
    if ($line -match '^[A-Za-z_]+\s*:') {
        if ($currentName) { $projectInfos += [pscustomobject]@{ Name = $currentName; Path = $currentPath } }
        $currentName = $null; $currentPath = $null
        $inProjects = ($line -match '^\s*projects\s*:')
        continue
    }
    if (-not $inProjects) { continue }
    if ($line -match '^\s*-\s*name\s*:\s*(\S+)') {
        if ($currentName) { $projectInfos += [pscustomobject]@{ Name = $currentName; Path = $currentPath } }
        $currentName = $Matches[1].Trim('"').Trim("'")
        $currentPath = $null
        continue
    }
    if ($line -match '^\s*path\s*:\s*(\S+)') {
        $currentPath = $Matches[1].Trim('"').Trim("'")
    }
}
if ($currentName) { $projectInfos += [pscustomobject]@{ Name = $currentName; Path = $currentPath } }

if (-not $projectInfos) {
    Write-Warning "Could not parse any project names from the manifest. Skipping per-project existence check."
} else {
    foreach ($p in $projectInfos) {
        $candidates = if ($p.Path) {
            @( (Join-Path $manifestDir $p.Path) )
        } else {
            @( (Join-Path $manifestDir $p.Name),
               (Join-Path (Join-Path $manifestDir 'projects') $p.Name) )
        }
        $resolved = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
        if (-not $resolved) {
            $shown = if ($p.Path) { "'$($p.Path)' (from explicit projects[].path)" } else { "any of: $($candidates -join '; ')" }
            throw "Project '$($p.Name)' is listed in the manifest but no directory was found at $shown."
        }
        Write-Host "  project '$($p.Name)' -> $resolved"
    }
}

Write-Host "Workspace looks healthy."
exit 0
