<#
.SYNOPSIS
    Enable or disable an MCP server by editing the 'disabled' field in
    .vscode/mcp.json. The catalog at .vscode/mcp.servers.catalog.json
    decides which servers may be toggled.

.DESCRIPTION
    Chat-driven MCP toggles MUST go through this script — never hand-edit
    .vscode/mcp.json. The catalog's 'alwaysEnabled' flag is authoritative:
    a server marked alwaysEnabled cannot be disabled.

.PARAMETER Server
    The server id, matching both the key under 'servers' in mcp.json and
    the 'id' field in the catalog.

.PARAMETER Enable
    Set the server's disabled field to false. Mutually exclusive with -Disable.

.PARAMETER Disable
    Set the server's disabled field to true. Mutually exclusive with -Enable.

.EXAMPLE
    ./scripts/Set-McpServerState.ps1 -Server context7 -Enable

.EXAMPLE
    ./scripts/Set-McpServerState.ps1 -Server context7 -Disable
#>

[CmdletBinding(DefaultParameterSetName = 'Enable')]
param(
    [Parameter(Mandatory)] [string] $Server,
    [Parameter(Mandatory, ParameterSetName = 'Enable')] [switch] $Enable,
    [Parameter(Mandatory, ParameterSetName = 'Disable')] [switch] $Disable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mcpJsonPath = Join-Path $repoRoot '.vscode/mcp.json'
$catalogPath = Join-Path $repoRoot '.vscode/mcp.servers.catalog.json'

if (-not (Test-Path -LiteralPath $mcpJsonPath)) { throw "MCP config not found: $mcpJsonPath" }
if (-not (Test-Path -LiteralPath $catalogPath)) { throw "MCP catalog not found: $catalogPath" }

$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$entry = $catalog.servers | Where-Object { $_.id -eq $Server } | Select-Object -First 1
if (-not $entry) {
    $known = ($catalog.servers | ForEach-Object { $_.id }) -join ', '
    throw "Server '$Server' is not in the catalog. Known servers: $known"
}

$targetDisabled = -not $Enable.IsPresent
if ($targetDisabled -and $entry.alwaysEnabled) {
    throw "Server '$Server' is marked alwaysEnabled in the catalog and cannot be disabled. Edit the catalog if this is genuinely the right move."
}

$mcp = Get-Content -LiteralPath $mcpJsonPath -Raw | ConvertFrom-Json
if (-not $mcp.servers.PSObject.Properties[$Server]) {
    throw "Server '$Server' is in the catalog but not configured in $mcpJsonPath. Add it there first."
}

$mcp.servers.$Server.disabled = $targetDisabled
$mcp | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mcpJsonPath -Encoding utf8

$state = if ($targetDisabled) { 'disabled' } else { 'enabled' }
Write-Host "Server '$Server' is now $state in $mcpJsonPath." -ForegroundColor Green
exit 0
