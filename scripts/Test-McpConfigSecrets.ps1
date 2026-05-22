<#
.SYNOPSIS
    Scan committed (or staged) MCP configuration files AND Terraform
    source files (.tf, .tfvars, .tfvars.json) for hardcoded secrets
    and live tenant URLs. The pre-commit gate calls this script with
    -StagedOnly to block accidental commits.

.DESCRIPTION
    Two scan paths:

    1. **MCP configs** (.vscode/mcp.json and any *.mcp.json). Parsed as
       JSON; only the load-bearing fields are scanned (every 'value'
       under 'env:' blocks and every 'value' under 'inputs[]' entries).
       'description' fields and other free-text are NOT scanned, so
       realistic example URLs in prompts don't trip the scanner.

    2. **Terraform source files** -- *.tf, *.tfvars, and *.tfvars.json
       anywhere in the repo. Line-by-line regex scan. The convention
       is that the dynatrace provider reads every credential from env
       vars at runtime, so the scanner flags any inline credential
       argument (api_token, client_id, client_secret, account_id)
       whose value is a string literal rather than a var./local./data.
       reference. `url` is deliberately NOT on the inline-arg list --
       it is a common, legitimate argument name in non-provider blocks
       (webhook endpoints, HTTP data sources, dashboard tiles), and
       the live-tenant-URL regex below already catches the only `url`
       value we actually care about: a hardcoded *.live.dynatrace.com /
       *.apps.dynatrace.com / *.dynatracelabs.com host. tfvars coverage
       matters because "I'll just put it in dev.tfvars for now" is
       one of the most common ways a token leaks into the repo. Per-
       developer tfvars files (the .gitignored envs/*.local.tfvars /
       envs/*.local.tfvars.json convention) are excluded from the full-
       repo walk so a local scratch file does not block your push.

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
    Default scans every *.mcp.json under .vscode/ AND every *.tf /
    *.tfvars / *.tfvars.json discovered by a recursive walk of the
    repo (untracked working-tree files included, .gitignored per-
    developer .local.tfvars files excluded). Use -StagedOnly in the
    pre-commit hook so a local scratch file doesn't block your push;
    the default mode is for operator-driven full-repo audits.

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
        if ($f -match '\.vscode[\\/](mcp|.*\.mcp)\.json$')   { $mcpTargets += $full; continue }
        # Match .tf, .tfvars, and .tfvars.json. Secrets accidentally
        # committed in tfvars (the typical "I'll just put it in dev.tfvars
        # for now" mistake) would bypass a .tf-only scan.
        if ($f -match '\.(tf|tfvars|tfvars\.json)$')          { $tfTargets  += $full; continue }
    }
} else {
    $mcpTargets += Get-ChildItem -LiteralPath (Join-Path $repoRoot '.vscode') -Filter '*.mcp.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    $main = Join-Path $repoRoot '.vscode/mcp.json'
    if (Test-Path -LiteralPath $main) { $mcpTargets += $main }
    # Never scan the gitignored session file.
    # Wrap in @(...) to keep $mcpTargets as an array even when Where-Object
    # reduces to zero or one element under strict mode.
    $mcpTargets = @($mcpTargets | Where-Object { $_ -notmatch 'mcp\.session(\..*)?\.json$' })

    # All Terraform source files in the working tree (.tf + .tfvars +
    # .tfvars.json -- tracked AND untracked, since `git diff --cached`
    # is the staged-only path above; this default mode is the operator-
    # driven full-repo audit and should catch scratch files too).
    # .tfvars is the most common place a developer accidentally pastes a
    # token while iterating ("I'll just put it in dev.tfvars for now"),
    # so the scanner MUST cover them too. Use Get-ChildItem -Recurse with
    # explicit exclusions for paths that aren't real source: the
    # .terraform/ provider cache, the downloaded/ snapshots, and the
    # gitignored developer-local override files. Two override conventions
    # are excluded:
    #   - *.local.tfvars / *.local.tfvars.json (dt-pilot's per-developer
    #     scratch convention; .gitignored).
    #   - *.auto.tfvars / *.auto.tfvars.json (Terraform's own auto-loaded
    #     overrides; also .gitignored in this repo; same intent --
    #     developer-local values that should never reach the audit).
    # Directory-pruning walker. Get-ChildItem -Recurse with a post-hoc
    # Where-Object filter still descends INTO every excluded directory
    # (`.git/`, `.terraform/`, `node_modules/`) and only drops them
    # after enumeration; on a large repo that's a real cost and
    # repeated three times (once per file pattern). Walk the tree
    # ourselves and skip excluded dirs at the dir level so they're
    # never traversed.
    $excludeDirs = @('.git', '.terraform', 'node_modules', 'downloaded')
    $tfTargets = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($repoRoot)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $entries = [System.IO.Directory]::EnumerateFileSystemEntries($dir)
        } catch {
            continue
        }
        foreach ($entry in $entries) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ([System.IO.Directory]::Exists($entry)) {
                if ($excludeDirs -notcontains $name) { $stack.Push($entry) }
            } else {
                # Match the same patterns the previous -Filter loop did,
                # then strip the gitignored per-developer overrides
                # (envs/*.local.tfvars[.json], *.auto.tfvars[.json]).
                if ($name -match '\.(tf|tfvars|tfvars\.json)$' -and $name -notmatch '\.(local|auto)\.tfvars(\.json)?$') {
                    $tfTargets.Add($entry)
                }
            }
        }
    }
    $tfTargets = @($tfTargets)
}

if (-not $mcpTargets) { $mcpTargets = @() }
if (-not $tfTargets)  { $tfTargets  = @() }
if (@($mcpTargets).Count -eq 0 -and @($tfTargets).Count -eq 0) {
    Write-Host "No MCP configs or Terraform source files to scan." -ForegroundColor DarkGray
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
# `api_token = "..."`, `client_id = "..."`, `client_secret = "..."`,
# or `account_id = "..."` whose right-hand side is a string literal
# (not a var./local./data. reference) is flagged regardless of what
# HCL block it's inside -- the dynatrace provider in dt-pilot reads
# every credential from env vars, so a committed inline value of those
# specifically-credential names is always a smell.
#
# `url` is deliberately NOT in this regex -- it's a common, legitimate
# argument name in non-provider blocks (webhook endpoints, HTTP data
# sources, dashboard tiles, notification configs), and flagging every
# inline `url = "..."` produced too many false positives. The actual
# leak case we care about -- a live Dynatrace tenant URL hardcoded
# anywhere in the file -- is already caught by $tenantUrlRegex above,
# which matches *.live.dynatrace.com / *.apps.dynatrace.com /
# *.dynatracelabs.com regardless of whether it's the LHS of a `url =`
# assignment, embedded in a template string, or appearing as a comment.
$tfArgRegex      = '^\s*(api_token|client_id|client_secret|account_id)\s*=\s*"([^"]+)"'
$credentialNames = @('api_token','client_id','client_secret','account_id')
foreach ($file in $tfTargets) {
    # Read once with -Raw, derive the per-line array from the raw
    # content. The previous version called Get-Content twice (once
    # default-mode for $lines, once -Raw for heredoc detection) which
    # doubled disk I/O on every Terraform file in the workspace.
    $fullContent = Get-Content -LiteralPath $file -Raw
    if ($null -eq $fullContent) { $fullContent = '' }
    # Split on either CRLF or LF and trim a trailing empty entry that
    # appears when the file ends with a newline. This preserves the
    # single-line-file safety the @(Get-Content ...) array coercion
    # gave us: even a one-line file becomes a 1-element array.
    #
    # The `-gt 1` guard is load-bearing: an empty file `-split` returns
    # a single-element `('')`, and `0..-1` is the REVERSE range `0,-1`
    # in PowerShell (not the empty range you'd expect from Python-style
    # slicing) which would duplicate / corrupt the line list. So only
    # trim when there are at least two elements to begin with.
    $lines = $fullContent -split "`r?`n"
    if ($lines.Length -gt 1 -and $lines[-1] -eq '') {
        $lines = $lines[0..($lines.Length - 2)]
    }
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
                # "credential field" rather than "provider argument" --
                # the same regex fires on .tf (a provider arg) and
                # .tfvars (a variable assignment); generic wording stays
                # accurate regardless of file type.
                $findings.Add(("{0}  ({1}): credential field '{2}' set to an inline string literal -- read it from an env var via the wrapper instead" -f $file, $loc, $argName))
            }
        }
    }

    # HCL heredoc credential assignments. The $tfArgRegex above only
    # matches single-line `key = "..."`. HCL also allows:
    #
    #   api_token = <<EOF
    #   dt0c01.ABC...
    #   EOF
    #
    # (and `<<-EOF` for indented variants). Without this scan, a
    # client_secret / account_id literal that isn't token-shaped could
    # be smuggled into a heredoc and bypass both the token-prefix regex
    # AND the single-line inline-arg regex. We treat ANY heredoc
    # assignment to one of the credential field names as a hit -- the
    # convention is that credentials never appear inline in any form.
    # Match on the full file content with the multiline flag so the
    # marker (the same identifier after <<) can find its closing line.
    if ($fullContent) {
        $heredocPattern = '(?m)^\s*(api_token|client_id|client_secret|account_id)\s*=\s*<<-?\s*(["'']?)(\w+)\2'
        foreach ($m in [regex]::Matches($fullContent, $heredocPattern)) {
            $argName = $m.Groups[1].Value
            # Same wording rationale as the single-line case: heredocs
            # appear in both .tf (provider blocks) and .tfvars (variable
            # values), so use file-type-agnostic "credential field" so
            # the diagnostic isn't misleading in tfvars context.
            $findings.Add(("{0}  (heredoc): credential field '{1}' set to a heredoc literal -- read it from an env var via the wrapper instead" -f $file, $argName))
        }
    }

    # .tfvars.json files use JSON syntax (`"api_token": "..."`), so the
    # HCL-shaped $tfArgRegex above never matches them. Parse JSON
    # variants separately and check the same credential field names.
    # Any non-empty string value for one of those keys is treated as an
    # inline literal (JSON has no interpolation analogue -- you can't
    # write ${var.x} in a JSON value).
    if ($file -match '\.tfvars\.json$') {
        try {
            $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        } catch {
            $findings.Add(("{0}: not valid JSON -- refusing to scan ({1})" -f $file, $_.Exception.Message))
            continue
        }
        if ($json -and $json.PSObject -and $json.PSObject.Properties) {
            foreach ($prop in $json.PSObject.Properties) {
                if ($credentialNames -contains $prop.Name -and $prop.Value -is [string] -and $prop.Value.Length -gt 0) {
                    # Don't include the literal value -- it's the secret
                    # we're trying NOT to leak. The field name + file
                    # location are enough for the operator to find and
                    # remove it. (Earlier draft passed three -f arguments
                    # while the format string only had {0} and {1}, so
                    # the value was silently dropped; explicit is better.)
                    $findings.Add(("{0}  (json key '{1}'): credential field set to an inline string literal -- read it from an env var via the wrapper instead" -f $file, $prop.Name))
                }
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
Write-Host "Secret-hygiene scan passed: $mcpCount MCP config file(s) + $tfCount Terraform source file(s) (*.tf / *.tfvars / *.tfvars.json)." -ForegroundColor Green
exit 0
