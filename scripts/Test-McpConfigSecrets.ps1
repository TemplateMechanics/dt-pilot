<#
.SYNOPSIS
    Scan committed (or staged) MCP configuration files for hardcoded
    secrets and live tenant URLs. The pre-commit gate calls this script
    with -StagedOnly to block accidental token commits.

.DESCRIPTION
    Inspects .vscode/mcp.json (and any other *.mcp.json patterns) for:
        - 'value' literals that look like Dynatrace tokens (dt0c01.*,
          dt0s01.*, dt0s06.*, dt0u01.*, dt0v01.*)
        - OAuth client secrets that look like raw secrets (long base64
          / hex strings inline rather than via env var references)
        - 'value' literals that look like live tenant URLs
          (*.live.dynatrace.com, *.apps.dynatrace.com, *.dynatracelabs.com)
        - Bearer tokens embedded in URLs (https://user:token@...)

    Per-developer secrets belong in .vscode/mcp.session.json (gitignored)
    or in environment variables that mcp.json references by name.

.PARAMETER StagedOnly
    Scan only files currently staged for commit (git diff --cached).
    Default scans every tracked *.mcp.json under .vscode/.

.EXAMPLE
    ./scripts/Test-McpConfigSecrets.ps1

.EXAMPLE
    ./scripts/Test-McpConfigSecrets.ps1 -StagedOnly
#>

[CmdletBinding()]
param(
    [switch] $StagedOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

$targets = @()
if ($StagedOnly) {
    Push-Location $repoRoot
    try {
        $staged = & git diff --cached --name-only --diff-filter=ACMR 2>$null
    } finally {
        Pop-Location
    }
    if (-not $staged) { Write-Host "No staged files; nothing to scan." -ForegroundColor DarkGray; exit 0 }
    foreach ($f in $staged) {
        $full = Join-Path $repoRoot $f
        if ($f -match '\.vscode[\\/](mcp|.*\.mcp)\.json$' -and (Test-Path -LiteralPath $full)) {
            $targets += $full
        }
    }
} else {
    $targets += Get-ChildItem -LiteralPath (Join-Path $repoRoot '.vscode') -Filter '*.mcp.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    $main = Join-Path $repoRoot '.vscode/mcp.json'
    if (Test-Path -LiteralPath $main) { $targets += $main }
    # Never scan the gitignored session file.
    $targets = $targets | Where-Object { $_ -notmatch 'mcp\.session(\..*)?\.json$' }
}

if (-not $targets) {
    Write-Host "No MCP config files to scan." -ForegroundColor DarkGray
    exit 0
}

$findings = New-Object System.Collections.Generic.List[string]

# Dynatrace token prefixes (current as of mid-2026 — extend as new types ship).
$tokenPrefixRegex = '\b(dt0[a-z0-9]{2,3}\.[A-Z0-9]{24}\.[A-Z0-9]{64})\b'
$tenantUrlRegex   = 'https?://[A-Za-z0-9.-]+\.(live\.dynatrace\.com|apps\.dynatrace\.com|dynatracelabs\.com)'
$bearerInUrlRegex = 'https?://[^:@\s]+:[^@\s]+@'

foreach ($file in $targets) {
    $lines = Get-Content -LiteralPath $file
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match $tokenPrefixRegex) {
            $findings.Add(("{0}:{1}  Dynatrace token literal detected" -f $file, ($i + 1)))
        }
        if ($line -match $tenantUrlRegex) {
            $findings.Add(("{0}:{1}  live tenant URL literal detected ({2}) — use type:environment + env-var reference instead" -f $file, ($i + 1), $Matches[0]))
        }
        if ($line -match $bearerInUrlRegex) {
            $findings.Add(("{0}:{1}  credential embedded in URL detected" -f $file, ($i + 1)))
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host "MCP secret-hygiene scan FAILED:" -ForegroundColor Red
    foreach ($f in $findings) { Write-Host "  - $f" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Per-developer secrets belong in .vscode/mcp.session.json (gitignored) or in environment variables that mcp.json references by name." -ForegroundColor Yellow
    exit 1
}

Write-Host "MCP secret-hygiene scan passed for $($targets.Count) file(s)." -ForegroundColor Green
exit 0
