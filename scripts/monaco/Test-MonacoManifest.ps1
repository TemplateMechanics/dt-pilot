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
    ./scripts/monaco/Test-MonacoManifest.ps1 -Path examples/baseline-stack
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

# Walk the projects: section honoring optional `projects[].path` overrides.
# End the section on any *unindented* top-level key; indented nested fields
# (path:, type:, etc.) do NOT terminate the walk.
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

foreach ($p in $projectInfos) {
    if ($p.Path) {
        $explicit = Join-Path $manifestDir $p.Path
        if (-not (Test-Path -LiteralPath $explicit -PathType Container)) {
            $errors.Add("project '$($p.Name)' has projects[].path = '$($p.Path)' but no directory exists at '$explicit'")
        }
        continue
    }
    $direct = Join-Path $manifestDir $p.Name
    $nested = Join-Path (Join-Path $manifestDir 'projects') $p.Name
    if (-not ((Test-Path -LiteralPath $direct -PathType Container) -or (Test-Path -LiteralPath $nested -PathType Container))) {
        $errors.Add("project '$($p.Name)' referenced in manifest but no directory found at '$direct' or '$nested'")
    }
}

# Check for env-var-backed URL/auth: flag both literal URLs and inline
# token / OAuth secret values. The convention is `type: environment` +
# `value: <ENV_VAR_NAME>` for URLs, and `name: <ENV_VAR_NAME>` (resolved
# from the env at deploy time) for tokens. Anything else is a smell.
$lines = Get-Content -LiteralPath $manifest
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^\s*value\s*:\s*(https?://\S+)') {
        $errors.Add("literal URL in manifest: '$($Matches[1])'. Use type: environment with an env-var name instead.")
    }
    # Detect an inline token under token: / platformToken: / clientId: /
    # clientSecret:. Monaco's contract is that these blocks resolve from
    # env vars via the `name:` field; a peer `value:` here means the
    # secret was inlined.
    if ($line -match '^(\s*)(token|platformToken|clientId|clientSecret)\s*:\s*$') {
        $baseIndent = $Matches[1].Length
        $authKey    = $Matches[2]
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $peer = $lines[$j]
            if ($peer -notmatch '^(\s*)\S') { continue }  # skip blank
            $peerIndent = $Matches[1].Length
            # Stop when indentation returns to (or above) the auth key's
            # level -- anything from here on belongs to a sibling block.
            if ($peerIndent -le $baseIndent) { break }
            if ($peer -match '^\s*value\s*:\s*\S') {
                # ${authKey}: -- braces force the scope separator. Bare $authKey:
                # is a PS parse error because ':' is otherwise a scope delimiter.
                $errors.Add("inline literal value detected under '${authKey}:' at line $($j + 1); auth blocks must reference env vars via 'name:' rather than inlining secrets.")
                break
            }
        }
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Manifest schema check FAILED for: $manifest" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "  - $e" -ForegroundColor Red }
    exit 1
}

Write-Host "Manifest schema check passed for: $manifest" -ForegroundColor Green
exit 0
