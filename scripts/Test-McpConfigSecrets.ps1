<#
.SYNOPSIS
    Scan committed (or staged) MCP configuration files AND Terraform
    .tf files for hardcoded secrets and live tenant URLs. The pre-commit
    gate calls this script with -StagedOnly to block accidental commits.

.DESCRIPTION
    Two scan paths:

    1. **MCP configs** (.vscode/mcp.json and any *.mcp.json). Parsed as
       JSON; only the load-bearing fields are scanned (every 'value'
       under 'env:' blocks and every 'value' under 'inputs[]' entries).
       'description' fields and other free-text are NOT scanned, so
       realistic example URLs in prompts don't trip the scanner.

    2. **Terraform .tf files** (anywhere in the repo). Line-by-line
       regex scan. The convention is that the dynatrace provider
       reads every credential from env vars at runtime, so the scanner
       flags any inline credential argument (url, api_token, client_id,
       client_secret, account_id) whose value is a string literal
       rather than a var./local./data. reference.

    Patterns detected in BOTH file types:
        - Dynatrace token literals (any dt0XX. prefix family)
        - Live tenant URLs (*.live.dynatrace.com, *.apps.dynatrace.com,
          *.dynatracelabs.com)
        - Bearer tokens embedded in URLs (https://user:token@...)

    OAuth client-secret detection by string-shape is not attempted:
    secrets are entropy-shaped and string-shape heuristics produce too
    many false positives. The repo convention is that secrets never
    appear as inline values anyway -- they come from env-var references
    -- and the live tenant URL + token literal + inline-provider-arg
    checks are sufficient to enforce that convention.

    Per-developer secrets belong in .vscode/mcp.session.json (gitignored)
    or in environment variables that mcp.json / the Terraform provider
    references by name.

.PARAMETER StagedOnly
    Scan only files currently staged for commit (git diff --cached).
    Default scans every *.mcp.json under .vscode/ AND every *.tf
    discovered by a recursive walk of the repo (untracked working-tree
    files included). Use -StagedOnly in the pre-commit hook so a local
    scratch file doesn't block your push; the default mode is for
    operator-driven full-repo audits.

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

$mcpTargets = @()
$tfTargets  = @()
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
        if (-not (Test-Path -LiteralPath $full)) { continue }
        if ($f -match '\.vscode[\\/](mcp|.*\.mcp)\.json$') { $mcpTargets += $full; continue }
        if ($f -match '\.tf$')                              { $tfTargets  += $full; continue }
    }
} else {
    $mcpTargets += Get-ChildItem -LiteralPath (Join-Path $repoRoot '.vscode') -Filter '*.mcp.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    $main = Join-Path $repoRoot '.vscode/mcp.json'
    if (Test-Path -LiteralPath $main) { $mcpTargets += $main }
    # Never scan the gitignored session file.
    # Wrap in @(...) to keep $mcpTargets as an array even when Where-Object
    # reduces to zero or one element under strict mode.
    $mcpTargets = @($mcpTargets | Where-Object { $_ -notmatch 'mcp\.session(\..*)?\.json$' })

    # All committed .tf files. Use Get-ChildItem -Recurse with explicit
    # exclusions for paths that aren't real source (.terraform/ provider
    # cache; downloaded/ snapshots).
    $tfTargets = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.tf' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](\.terraform|downloaded)[\\/]' } |
        ForEach-Object { $_.FullName })
}

if (-not $mcpTargets) { $mcpTargets = @() }
if (-not $tfTargets)  { $tfTargets  = @() }
if (@($mcpTargets).Count -eq 0 -and @($tfTargets).Count -eq 0) {
    Write-Host "No MCP configs or .tf files to scan." -ForegroundColor DarkGray
    exit 0
}

$findings = New-Object System.Collections.Generic.List[string]

# Dynatrace token literal. We MUST stay broad here -- Dynatrace has
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
        $hits += ("{0}  ({1}): live tenant URL literal '{2}' -- use type:environment + env-var reference instead" -f $File, $Location, $Matches[0])
    }
    if ($Value -match $bearerInUrlRegex) {
        $hits += ("{0}  ({1}): credential embedded in URL detected" -f $File, $Location)
    }
    return $hits
}

foreach ($file in $mcpTargets) {
    try {
        $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    } catch {
        $findings.Add(("{0}: not valid JSON -- refusing to scan ({1})" -f $file, $_.Exception.Message))
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
            # 'args' is also a load-bearing field -- scan each entry.
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

# .tf scan: line-by-line regex check for the three general patterns
# (token literal, live tenant URL, bearer-in-URL) plus the Terraform-
# specific inline-provider-argument heuristic. A line like
# `url = "https://..."`, `api_token = "..."`, `client_id = "..."`,
# `client_secret = "..."`, or `account_id = "..."` whose right-hand
# side is a string literal (not a var./local./data. reference) is
# flagged regardless of what HCL block it's inside -- the dynatrace
# provider in dt-pilot reads every credential from env vars, so a
# committed inline value is always a smell.
$tfArgRegex = '^\s*(url|api_token|client_id|client_secret|account_id)\s*=\s*"([^"]+)"'
foreach ($file in $tfTargets) {
    # Force an array: Get-Content returns a scalar string for
    # single-line files, which would make $lines[$i] index characters
    # rather than lines (and miss secrets in any .tf file that's a
    # single line).
    $lines = @(Get-Content -LiteralPath $file)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $loc  = "line $($i + 1)"
        $hits = Test-StringForSecrets -Value $line -File $file -Location $loc
        foreach ($h in $hits) { $findings.Add($h) }
        if ($line -match $tfArgRegex) {
            $argName = $Matches[1]
            $argVal  = $Matches[2]
            # Allow any string that CONTAINS a ${var.x}, ${local.x},
            # ${data.x.y}, or ${module.x.y} interpolation -- those
            # resolve to runtime values, not committed secrets.
            # (The previous `^\$\{...` anchor would false-positive on
            # 'https://${var.tenant}/path' which contains but doesn't
            # start with an interpolation.)
            if ($argVal -notmatch '\$\{(var|local|data|module)\.') {
                $findings.Add(("{0}  ({1}): provider argument '{2}' set to an inline string literal -- read it from an env var via the wrapper instead" -f $file, $loc, $argName))
            }
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host "Secret-hygiene scan FAILED:" -ForegroundColor Red
    foreach ($f in $findings) { Write-Host "  - $f" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Per-developer secrets belong in .vscode/mcp.session.json (gitignored) or in environment variables that mcp.json / the Terraform provider references by name." -ForegroundColor Yellow
    exit 1
}

$mcpCount = @($mcpTargets).Count   # coerce -- strict mode rejects .Count on a scalar
$tfCount  = @($tfTargets).Count
Write-Host "Secret-hygiene scan passed: $mcpCount MCP config file(s) + $tfCount .tf file(s)." -ForegroundColor Green
exit 0
