<#
.SYNOPSIS
    Launch the official Dynatrace MCP server (@dynatrace-oss/dynatrace-mcp-server)
    over stdio for VS Code / Claude Code / Cursor / any MCP client.

.DESCRIPTION
    Thin launcher script. Resolves and runs the upstream server via 'npx'
    so we always pull the latest published version unless the user pins
    via DT_MCP_VERSION. Validates the required environment variables
    (DT_ENVIRONMENT plus at least one of: DT_PLATFORM_TOKEN, or both of
    OAUTH_CLIENT_ID + OAUTH_CLIENT_SECRET) and fails fast with a clear
    message if anything is missing.

    Stdout is the MCP transport, so this script writes diagnostics ONLY to
    stderr. Anything we accidentally print to stdout would corrupt the
    MCP framing seen by the client.

.PARAMETER NpxExe
    Override the 'npx' executable path. Defaults to whatever's on PATH.

.PARAMETER McpVersion
    Version tag for @dynatrace-oss/dynatrace-mcp-server. Defaults to
    'latest'. Override via -McpVersion or DT_MCP_VERSION env var.

.PARAMETER ExtraArgs
    Extra arguments forwarded to the MCP server (e.g. --http to switch
    transports). Pass-through only — we do not validate them.

.EXAMPLE
    pwsh -NoProfile -File ./scripts/Start-DynatraceMcpServer.ps1
#>

[CmdletBinding()]
param(
    [string] $NpxExe,
    [string] $McpVersion,
    [string[]] $ExtraArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Diag {
    param([string] $Message)
    # Diagnostics go to stderr to avoid corrupting the MCP stdio transport.
    [Console]::Error.WriteLine("[Start-DynatraceMcpServer] $Message")
}

# Required environment.
if (-not $env:DT_ENVIRONMENT) {
    Write-Diag "DT_ENVIRONMENT is not set. Set it to your Dynatrace platform URL (e.g. https://abc12345.apps.dynatrace.com)."
    exit 2
}

$hasPlatformToken = [bool]$env:DT_PLATFORM_TOKEN
$hasOAuth = ($env:OAUTH_CLIENT_ID -and $env:OAUTH_CLIENT_SECRET)
if (-not ($hasPlatformToken -or $hasOAuth)) {
    Write-Diag "Provide either DT_PLATFORM_TOKEN, or both OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET. None are set."
    exit 2
}

# Resolve npx.
if (-not $NpxExe) {
    $cmd = Get-Command -Name npx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        Write-Diag "npx not found on PATH. Install Node.js (>= 20) from https://nodejs.org."
        exit 2
    }
    $NpxExe = $cmd.Path
}

# Resolve version pin.
if (-not $McpVersion) {
    $McpVersion = if ($env:DT_MCP_VERSION) { $env:DT_MCP_VERSION } else { 'latest' }
}

$pkg = "@dynatrace-oss/dynatrace-mcp-server@$McpVersion"
$args = @('-y', $pkg)
if ($ExtraArgs) { $args += $ExtraArgs }

Write-Diag "Launching $pkg via $NpxExe"
Write-Diag "DT_ENVIRONMENT=$($env:DT_ENVIRONMENT)"
Write-Diag ("Auth mode: " + ($(if ($hasOAuth) { 'OAuth (client credentials)' } else { 'Platform token' })))

# Exec via Process so the child inherits our stdio (stdin/stdout/stderr).
# We don't redirect any stream — the MCP client owns this process's stdio.
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $NpxExe
foreach ($a in $args) { $null = $psi.ArgumentList.Add($a) }
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $false
$psi.RedirectStandardError  = $false
$psi.RedirectStandardInput  = $false

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.WaitForExit()
exit $proc.ExitCode
