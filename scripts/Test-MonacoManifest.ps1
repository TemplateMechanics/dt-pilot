<#
.SYNOPSIS
    Lightweight schema check for a Monaco manifest.yaml. Catches the most
    common mistakes (missing manifestVersion, missing projects/environments
    sections, projects referencing non-existent directories) without
    requiring Monaco itself to be installed.

.DESCRIPTION
    This script is intentionally schema-light: it parses manifest.yaml with
    a regex/line-based walker rather than a full YAML parser, so it has no
    third-party dependency and runs in CI bootstraps before Monaco is
    available. The authoritative validation is still Monaco's own
    'monaco deploy --dry-run' (via Validate-Monaco.ps1); this script
    catches the obvious mistakes faster.

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).

.EXAMPLE
    ./scripts/Test-MonacoManifest.ps1 -Path examples/baseline-stack
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path
)

. "$PSScriptRoot/_Common.ps1"

$manifest = Resolve-ManifestPath -Path $Path
$manifestDir = Split-Path -Parent $manifest
$content = Get-Content -LiteralPath $manifest -Raw
$errors = New-Object System.Collections.Generic.List[string]

if ($content -notmatch '(?m)^\s*manifestVersion\s*:') {
    $errors.Add("missing top-level 'manifestVersion' field")
}

if ($content -notmatch '(?m)^\s*projects\s*:') {
    $errors.Add("missing top-level 'projects' field")
}

if ($content -notmatch '(?m)^\s*environmentGroups\s*:') {
    $errors.Add("missing top-level 'environmentGroups' field")
}

# Find project names and check that each has an on-disk directory.
$projectNames = @()
$inProjects = $false
foreach ($line in (Get-Content -LiteralPath $manifest)) {
    if ($line -match '^\s*projects\s*:') { $inProjects = $true; continue }
    if ($inProjects) {
        if ($line -match '^\s*[A-Za-z_]+\s*:' -and $line -notmatch '^\s*-') {
            $inProjects = $false
            continue
        }
        if ($line -match '^\s*-\s*name\s*:\s*(\S+)') {
            $projectNames += $Matches[1].Trim('"').Trim("'")
        }
    }
}

foreach ($p in $projectNames) {
    $direct = Join-Path $manifestDir $p
    $nested = Join-Path (Join-Path $manifestDir 'projects') $p
    if (-not ((Test-Path -LiteralPath $direct -PathType Container) -or (Test-Path -LiteralPath $nested -PathType Container))) {
        $errors.Add("project '$p' referenced in manifest but no directory found at '$direct' or '$nested'")
    }
}

# Check for env-var-backed URL/auth — flag literal URLs and inline tokens as a smell.
foreach ($line in (Get-Content -LiteralPath $manifest)) {
    if ($line -match '^\s*value\s*:\s*(https?://\S+)') {
        $errors.Add("literal URL in manifest: '$($Matches[1])'. Use type: environment with an env-var name instead.")
    }
    if ($line -match '^\s*name\s*:\s*[A-Z][A-Z0-9_]{8,}\s*$') {
        # heuristic: this is fine — env var names are SHOUT_CASE. Do nothing.
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Manifest schema check FAILED for: $manifest" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "  - $e" -ForegroundColor Red }
    exit 1
}

Write-Host "Manifest schema check passed for: $manifest" -ForegroundColor Green
exit 0
