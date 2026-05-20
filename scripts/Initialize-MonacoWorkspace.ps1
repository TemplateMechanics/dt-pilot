<#
.SYNOPSIS
    Sanity-check a Monaco workspace: verify Monaco is installed, the manifest
    exists, and every project referenced by the manifest is present on disk.

.DESCRIPTION
    The Monaco CLI itself has no 'init' subcommand — there is nothing to
    download or cache up front. This wrapper takes the place of that step
    by validating the harness pre-conditions and giving the user a clear,
    early error if something is wrong before they run dry-run or deploy.

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).

.PARAMETER MonacoExe
    Override the Monaco executable lookup. See Get-MonacoVersion.ps1.

.EXAMPLE
    ./scripts/Initialize-MonacoWorkspace.ps1 -Path examples/baseline-stack
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

$projectNames = @()
$inProjects = $false
foreach ($line in (Get-Content -LiteralPath $manifest)) {
    if ($line -match '^\s*projects\s*:') { $inProjects = $true; continue }
    if ($inProjects) {
        if ($line -match '^\s*[A-Za-z_]+\s*:') {
            # Hit a new top-level key in the manifest — projects section ended.
            if ($line -notmatch '^\s*-') { $inProjects = $false; continue }
        }
        if ($line -match '^\s*-\s*name\s*:\s*(\S+)') {
            $projectNames += $Matches[1].Trim('"').Trim("'")
        }
    }
}

if (-not $projectNames) {
    Write-Warning "Could not parse any project names from the manifest. Skipping per-project existence check."
} else {
    foreach ($p in $projectNames) {
        $projectDir = Join-Path $manifestDir $p
        if (-not (Test-Path -LiteralPath $projectDir -PathType Container)) {
            $alt = Join-Path (Join-Path $manifestDir 'projects') $p
            if (Test-Path -LiteralPath $alt -PathType Container) { $projectDir = $alt }
        }
        if (-not (Test-Path -LiteralPath $projectDir -PathType Container)) {
            throw "Project '$p' is listed in the manifest but no directory was found at '$projectDir' or 'projects/$p/'."
        }
        Write-Host "  project '$p' -> $projectDir"
    }
}

Write-Host "Workspace looks healthy."
exit 0
