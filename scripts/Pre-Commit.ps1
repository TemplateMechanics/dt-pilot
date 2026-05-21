<#
.SYNOPSIS
    Local quality gate for dt-pilot. Run this before pushing or opening
    a PR. CI runs the same checks; this script is the local mirror so you
    don't ship red builds.

.DESCRIPTION
    Checks (in order; any failure stops the gate):
        1. Manifest schema check on every example/* project.
        2. MCP secret-hygiene scan (-StagedOnly by default; -All scans
           every tracked MCP config).
        3. Pester suite (./tests/Harness.Tests.ps1) — fast, doesn't
           require Monaco or a live Dynatrace tenant.

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

# 1. Manifest schema check on every example/* project that has a manifest.yaml.
Section "Manifest schema check"
$manifests = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'examples') -Filter 'manifest.yaml' -Recurse -ErrorAction SilentlyContinue
if (-not $manifests) {
    Write-Host "  (no example manifests yet — examples/baseline-stack lands in PR 7)" -ForegroundColor DarkGray
} else {
    foreach ($m in $manifests) {
        # The wrappers signal failure via non-zero exit, NOT via exceptions.
        # try/catch alone would silently swallow a manifest-validation failure.
        try {
            & (Join-Path $PSScriptRoot 'Test-MonacoManifest.ps1') -Path $m.FullName
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  FAILED (exit $LASTEXITCODE): $($m.FullName)" -ForegroundColor Red
                $failed = $true
            }
        } catch {
            Write-Host "  FAILED: $($m.FullName) -> $_" -ForegroundColor Red
            $failed = $true
        }
    }
}

# 2. MCP secret-hygiene scan.
Section "MCP secret-hygiene scan"
try {
    if ($All) {
        & (Join-Path $PSScriptRoot 'Test-McpConfigSecrets.ps1')
    } else {
        & (Join-Path $PSScriptRoot 'Test-McpConfigSecrets.ps1') -StagedOnly
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        $failed = $true
    }
} catch {
    Write-Host "  FAILED: $_" -ForegroundColor Red
    $failed = $true
}

# 3. Pester suite.
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
