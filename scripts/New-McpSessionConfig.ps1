<#
.SYNOPSIS
    Generate a per-developer .vscode/mcp.session.json from the committed
    template and catalog. The session file is gitignored.

.DESCRIPTION
    Reads .vscode/mcp.json (the shareable template) and applies the
    catalog's defaultEnabled state for each known server, producing a
    .vscode/mcp.session.json the user can freely edit (with secrets,
    custom env, etc.) without risking a commit.

    The session file is what an MCP client should actually load if the
    client supports a per-session override (Claude Code does); for clients
    that only read .vscode/mcp.json, this script is a no-op and the
    committed template is used as-is.

.PARAMETER Force
    Overwrite an existing .vscode/mcp.session.json without prompting.

.EXAMPLE
    ./scripts/New-McpSessionConfig.ps1

.EXAMPLE
    ./scripts/New-McpSessionConfig.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$template = Join-Path $repoRoot '.vscode/mcp.json'
$catalog  = Join-Path $repoRoot '.vscode/mcp.servers.catalog.json'
$session  = Join-Path $repoRoot '.vscode/mcp.session.json'

if (-not (Test-Path -LiteralPath $template)) { throw "Template not found: $template" }
if (-not (Test-Path -LiteralPath $catalog))  { throw "Catalog not found: $catalog" }

if ((Test-Path -LiteralPath $session) -and -not $Force) {
    throw "$session already exists. Re-run with -Force to overwrite."
}

$mcp = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json
$cat = Get-Content -LiteralPath $catalog  -Raw | ConvertFrom-Json

foreach ($srv in $cat.servers) {
    if (-not $mcp.servers.PSObject.Properties[$srv.id]) { continue }
    $mcp.servers.$($srv.id).disabled = -not $srv.defaultEnabled
}

$mcp | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $session -Encoding utf8

Write-Host "Wrote $session" -ForegroundColor Green
Write-Host "Edit this file freely — it is gitignored. Secrets and tenant URLs stay local." -ForegroundColor DarkGray
exit 0
