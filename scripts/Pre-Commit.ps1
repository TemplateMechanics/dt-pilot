<#
.SYNOPSIS
    Local quality gate for dt-pilot. Run this before pushing or opening
    a PR. CI runs the same checks; this script is the local mirror so you
    don't ship red builds.

.DESCRIPTION
    Runs every check below in order, accumulating failures, then exits
    non-zero at the end if anything failed. This deliberately surfaces
    multiple problems per invocation so you can fix them in one round:
        1. Per-backend manifest schema check (reads config/catalog/backends.json,
           runs each backend's manifestValidator against its manifestPattern).
        2. MCP secret-hygiene scan (-StagedOnly by default; -All scans
           every tracked MCP config).
        3. Per-backend reflected catalog sync check (reads config/catalog/backends.json,
           runs each backend's catalogSyncScript with -Check).
        4. Pester suite (./tests/Harness.Tests.ps1) -- fast, doesn't
           require Monaco / Terraform / a live tenant.

    Repo-wide gate; intentionally takes no -Path parameter.

.PARAMETER All
    Scan every MCP config (not just staged files). Useful when running
    locally outside the pre-commit hook.

.PARAMETER SkipTests
    Skip the Pester suite. Use only to iterate faster on a doc-only
    change; CI will still run the tests.

.EXAMPLE
    ./scripts/Pre-Commit.ps1

.EXAMPLE
    ./scripts/Pre-Commit.ps1 -All -SkipTests
#>

[CmdletBinding()]
param(
    [switch] $All,
    [switch] $SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$failed   = $false

function Section($name) {
    Write-Host ""
    Write-Host "===== $name =====" -ForegroundColor Cyan
}

function Invoke-Step {
    param(
        [string] $Label,
        [scriptblock] $Block
    )
    try {
        & $Block
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAILED (exit $LASTEXITCODE): $Label" -ForegroundColor Red
            $script:failed = $true
        }
    } catch {
        Write-Host "  FAILED: $Label -> $_" -ForegroundColor Red
        $script:failed = $true
    }
}

# Load the backend registry. Tooling iterates this instead of hard-coding
# Monaco paths; new backends are picked up automatically by adding an entry.
$backendsPath = Join-Path $repoRoot 'config/catalog/backends.json'
if (-not (Test-Path -LiteralPath $backendsPath)) {
    throw "Backends registry not found at $backendsPath"
}
$backends = @((Get-Content -LiteralPath $backendsPath -Raw | ConvertFrom-Json).backends)

# 1. Per-backend manifest schema check.
Section "Manifest schema check (per backend)"
foreach ($b in $backends) {
    if (-not ($b.PSObject.Properties['manifestPattern'] -and $b.PSObject.Properties['manifestValidator'])) {
        Write-Host "  $($b.id): no manifestPattern/manifestValidator declared; skipping" -ForegroundColor DarkGray
        continue
    }
    $validator = Join-Path $repoRoot $b.manifestValidator
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        Write-Host "  FAILED: $($b.id) manifestValidator missing at $validator" -ForegroundColor Red
        $failed = $true
        continue
    }
    # Resolve the glob via Get-ChildItem -Recurse. backends.json uses a
    # glob like 'examples/**/manifest.yaml' which we split into root +
    # filter for the cmdlet.
    $patternRoot = ($b.manifestPattern -split '/\*\*/')[0]
    $patternFile = Split-Path -Leaf $b.manifestPattern
    $rootPath = Join-Path $repoRoot $patternRoot
    if (-not (Test-Path -LiteralPath $rootPath)) {
        Write-Host "  $($b.id): no $patternRoot directory; nothing to check" -ForegroundColor DarkGray
        continue
    }
    $manifests = Get-ChildItem -LiteralPath $rootPath -Filter $patternFile -Recurse -ErrorAction SilentlyContinue
    if (-not $manifests) {
        Write-Host "  $($b.id): no files match $($b.manifestPattern); nothing to check" -ForegroundColor DarkGray
        continue
    }
    foreach ($m in $manifests) {
        Invoke-Step -Label "$($b.id) :: $($m.FullName)" -Block {
            & $validator -Path $m.FullName
        }
    }
}

# 2. MCP secret-hygiene scan (backend-agnostic; lives at scripts/ root).
Section "MCP secret-hygiene scan"
$scanner = Join-Path $PSScriptRoot 'Test-McpConfigSecrets.ps1'
Invoke-Step -Label "MCP secret-hygiene scan" -Block {
    if ($All) { & $scanner } else { & $scanner -StagedOnly }
}

# 3. Per-backend reflected catalog sync check.
Section "Reflected catalog sync (per backend)"
foreach ($b in $backends) {
    if (-not $b.PSObject.Properties['catalogSyncScript']) {
        Write-Host "  $($b.id): no catalogSyncScript declared; skipping" -ForegroundColor DarkGray
        continue
    }
    $sync = Join-Path $repoRoot $b.catalogSyncScript
    if (-not (Test-Path -LiteralPath $sync -PathType Leaf)) {
        Write-Host "  FAILED: $($b.id) catalogSyncScript missing at $sync" -ForegroundColor Red
        $failed = $true
        continue
    }
    Invoke-Step -Label "$($b.id) catalog -Check" -Block { & $sync -Check }
}

# 4. Pester suite.
if (-not $SkipTests) {
    Section "Pester tests"
    $testsPath = Join-Path $repoRoot 'tests/Harness.Tests.ps1'
    if (-not (Test-Path -LiteralPath $testsPath)) {
        Write-Host "  (no test suite found at $testsPath)" -ForegroundColor DarkGray
    } else {
        if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge '5.0' } | Select-Object -First 1)) {
            Write-Host "  Pester 5+ is not installed. Install with: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force" -ForegroundColor Red
            $failed = $true
        } else {
            Import-Module Pester -MinimumVersion 5.0
            $config = New-PesterConfiguration
            $config.Run.Path = $testsPath
            $config.Run.PassThru = $true     # required for the run object to surface
            $config.Run.Exit = $false        # we own the exit code
            $config.Output.Verbosity = 'Detailed'
            $result = Invoke-Pester -Configuration $config
            if (-not $result -or $result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
                $failed = $true
            }
        }
    }
} else {
    Section "Pester tests"
    Write-Host "  (skipped via -SkipTests)" -ForegroundColor DarkGray
}

Write-Host ""
if ($failed) {
    Write-Host "Pre-Commit gate FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "Pre-Commit gate passed." -ForegroundColor Green
exit 0
