<#
.SYNOPSIS
    Scan committed (or staged) MCP configuration files for hardcoded
    secrets and live tenant URLs. The pre-commit gate calls this script
    with -StagedOnly to block accidental token commits.

.DESCRIPTION
    Parses each target file as JSON and inspects the load-bearing fields
    (every 'value' under 'env:' blocks and every 'value' under 'inputs[]'
    entries — i.e. the spots that actually get sent to the MCP client at
    launch time). 'description' fields and other free-text are NOT
    scanned, so realistic-looking example URLs in input prompts don't
    trip the scanner.

    Patterns detected:
        - Dynatrace token literals (any dt0XX. prefix family)
        - Live tenant URLs (*.live.dynatrace.com, *.apps.dynatrace.com,
          *.dynatracelabs.com)
        - Bearer tokens embedded in URLs (https://user:token@...)

    OAuth client-secret detection by string-shape is not attempted: secrets
    are entropy-shaped and string-shape heuristics produce too many false
    positives. The repo convention is that secrets never appear as inline
    values anyway — they come from env-var references — and the live tenant
    URL + token literal checks are sufficient to enforce that convention.

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
    # Wrap in @(...) to keep $targets as an array even when Where-Object
    # reduces to zero or one element under strict mode.
    $targets = @($targets | Where-Object { $_ -notmatch 'mcp\.session(\..*)?\.json$' })
}

if (-not $targets -or @($targets).Count -eq 0) {
    Write-Host "No MCP config files to scan." -ForegroundColor DarkGray
    exit 0
}

$findings = New-Object System.Collections.Generic.List[string]

# Dynatrace token literal. We MUST stay broad here — Dynatrace has
# shipped multiple token shapes over the years and will ship more, and
# the cost of a false negative (a real token leaked) outweighs the cost
# of a false positive (a token-shaped placeholder flagged). Anything
# starting with a 'dt0XX.' prefix and followed by enough characters to
# look secret triggers the rule. Adjust the lower bound only if a
# legitimate harmless string keeps tripping it.
$tokenPrefixRegex = '\bdt0[a-zA-Z0-9]{1,4}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b'
$tenantUrlRegex   = 'https?://[A-Za-z0-9.-]+\.(live\.dynatrace\.com|apps\.dynatrace\.com|dynatracelabs\.com)'
$bearerInUrlRegex = 'https?://[^:@\s]+:[^@\s]+@'

function Test-StringForSecrets {
    param(
        [string] $Value,
        [string] $File,
        [string] $Location
    )
    if (-not $Value) { return @() }
    $hits = @()
    if ($Value -match $tokenPrefixRegex) {
        $hits += ("{0}  ({1}): Dynatrace token literal detected" -f $File, $Location)
    }
    if ($Value -match $tenantUrlRegex) {
        $hits += ("{0}  ({1}): live tenant URL literal '{2}' — use type:environment + env-var reference instead" -f $File, $Location, $Matches[0])
    }
    if ($Value -match $bearerInUrlRegex) {
        $hits += ("{0}  ({1}): credential embedded in URL detected" -f $File, $Location)
    }
    return $hits
}

foreach ($file in $targets) {
    try {
        $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    } catch {
        $findings.Add(("{0}: not valid JSON — refusing to scan ({1})" -f $file, $_.Exception.Message))
        continue
    }

    # Every 'env' value under any 'servers.<id>'.
    if ($json.PSObject.Properties['servers']) {
        foreach ($srvProp in $json.servers.PSObject.Properties) {
            $srv = $srvProp.Value
            if ($srv.PSObject.Properties['env']) {
                foreach ($envProp in $srv.env.PSObject.Properties) {
                    $hits = Test-StringForSecrets -Value $envProp.Value -File $file -Location ("servers.{0}.env.{1}" -f $srvProp.Name, $envProp.Name)
                    foreach ($h in $hits) { $findings.Add($h) }
                }
            }
            # 'args' is also a load-bearing field — scan each entry.
            if ($srv.PSObject.Properties['args']) {
                for ($i = 0; $i -lt $srv.args.Count; $i++) {
                    $hits = Test-StringForSecrets -Value $srv.args[$i] -File $file -Location ("servers.{0}.args[{1}]" -f $srvProp.Name, $i)
                    foreach ($h in $hits) { $findings.Add($h) }
                }
            }
        }
    }

    # Inputs: only scan 'value' / 'default', NEVER 'description' (which
    # legitimately contains placeholder URLs).
    if ($json.PSObject.Properties['inputs']) {
        for ($i = 0; $i -lt $json.inputs.Count; $i++) {
            $inp = $json.inputs[$i]
            foreach ($field in @('value','default')) {
                if ($inp.PSObject.Properties[$field]) {
                    $hits = Test-StringForSecrets -Value $inp.$field -File $file -Location ("inputs[{0}].{1}" -f $i, $field)
                    foreach ($h in $hits) { $findings.Add($h) }
                }
            }
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

$count = @($targets).Count   # coerce — strict mode rejects .Count on a scalar
Write-Host "MCP secret-hygiene scan passed for $count file(s)." -ForegroundColor Green
exit 0
