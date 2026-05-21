<#
.SYNOPSIS
    Verify the environment can launch the Dynatrace MCP server without
    actually starting it. Run this as the first step when troubleshooting
    'why isn't the MCP server connecting?'.

.DESCRIPTION
    Checks (in order):
      1. Node.js / npx is on PATH at version >= 20.
      2. DT_ENVIRONMENT is set and looks like a Dynatrace URL.
      3. At least one valid auth mode is configured (DT_PLATFORM_TOKEN,
         or OAUTH_CLIENT_ID + OAUTH_CLIENT_SECRET).
      4. The MCP catalog at .vscode/mcp.servers.catalog.json exists and
         parses as JSON.

    Returns non-zero on any failure with a single targeted error per
    issue, so the user can fix one problem and re-run.

.EXAMPLE
    ./scripts/Test-DynatraceMcpReadiness.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# 1. Node.js / npx version.
$npx = Get-Command -Name npx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $npx) {
    $errors.Add("npx not found on PATH. Install Node.js >= 20 from https://nodejs.org.")
}
$node = Get-Command -Name node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
    $errors.Add("node not found on PATH; cannot verify the Node.js >= 20 requirement. Install Node.js from https://nodejs.org.")
} else {
    $verOutput = (& $node.Path --version 2>$null)
    if (-not $verOutput) {
        $errors.Add("Could not read 'node --version' output. The node binary at $($node.Path) may be broken.")
    } else {
        $verRaw = $verOutput.Trim().TrimStart('v')
        $major = 0
        if (-not [int]::TryParse($verRaw.Split('.')[0], [ref]$major)) {
            $errors.Add("Could not parse Node.js version '$verRaw' from $($node.Path).")
        } elseif ($major -lt 20) {
            $errors.Add("Node.js v$verRaw is below the required v20. Upgrade Node.js.")
        } else {
            Write-Host "node: v$verRaw  ($($node.Path))"
        }
    }
}

# 2. DT_ENVIRONMENT.
if (-not $env:DT_ENVIRONMENT) {
    $errors.Add("DT_ENVIRONMENT is not set. Set it to your Dynatrace platform URL (e.g. https://abc12345.apps.dynatrace.com).")
} elseif ($env:DT_ENVIRONMENT -notmatch '^https?://[A-Za-z0-9.-]+(\.dynatrace\.com|\.dynatracelabs\.com)') {
    $warnings.Add("DT_ENVIRONMENT='$($env:DT_ENVIRONMENT)' does not look like a typical Dynatrace URL. Continuing anyway.")
} else {
    Write-Host "DT_ENVIRONMENT: $($env:DT_ENVIRONMENT)"
}

# 3. Auth mode.
$hasPlatformToken = [bool]$env:DT_PLATFORM_TOKEN
$hasOAuth = ($env:OAUTH_CLIENT_ID -and $env:OAUTH_CLIENT_SECRET)
if (-not ($hasPlatformToken -or $hasOAuth)) {
    $errors.Add("No auth configured. Set DT_PLATFORM_TOKEN, or both OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET.")
} elseif ($hasOAuth) {
    Write-Host "Auth mode: OAuth (client credentials)"
} else {
    Write-Host "Auth mode: Platform token"
}

# 4. Catalog presence + JSON parse.
$repoRoot = Split-Path -Parent $PSScriptRoot
$catalog = Join-Path $repoRoot '.vscode/mcp.servers.catalog.json'
if (-not (Test-Path -LiteralPath $catalog -PathType Leaf)) {
    $errors.Add("MCP catalog missing: $catalog")
} else {
    try {
        $null = Get-Content -LiteralPath $catalog -Raw | ConvertFrom-Json
        Write-Host "Catalog: $catalog (valid JSON)"
    } catch {
        $errors.Add("MCP catalog at $catalog is not valid JSON: $_")
    }
}

foreach ($w in $warnings) { Write-Warning $w }

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "Dynatrace MCP readiness check FAILED:" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "  - $e" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "Dynatrace MCP readiness check passed." -ForegroundColor Green
exit 0
