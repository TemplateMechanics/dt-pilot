<#
.SYNOPSIS
    Refresh config/catalog/catalog.settings.json from live Dynatrace
    settings 2.0 schemas. Reads config/catalog/schemas.txt as the inputs
    list and calls `monaco generate schema --schema <id>` for each.

.DESCRIPTION
    Per Design 002 (docs/design/SCHEDULED-CATALOG-REFRESH.md), this
    script is the engine behind the weekly catalog-refresh cron. It is
    deliberately split into small, pure functions so the cron path
    AND the Pester suite can exercise each piece without touching live
    Dynatrace.

    Behavior:
      1. Read config/catalog/schemas.txt. Strip comments and blank lines.
      2. Read the existing config/catalog/catalog.settings.json so the
         hand-curated fields (family, commonParameters) survive the
         refresh.
      3. For each schema ID, fetch the live JSON Schema. Build the new
         catalog entry by overwriting summary + liveFields and keeping
         everything else from the existing entry. NEW schemas (no
         existing entry) get family: misc and empty commonParameters;
         a human reassigns these during PR review.
      4. Write the new catalog.settings.json with byte-deterministic
         formatting (UTF-8 NoBOM, LF, hand-formatted JSON) so the
         existing -Check gate (Sync-ConfigCatalog.ps1) stays green on
         re-runs that produce no semantic change.
      5. Optionally regenerate modules/configs/ via Sync-ConfigCatalog.ps1.

    Failure handling (per Design 002 section 7):
      - Per-schema failure: log loudly, continue with the remaining
        schemas. The schema ID is added to the "no longer resolvable"
        list in the refresh PR body.
      - Whole-environment unreachable: exit 0 with a loud log. The
        next cron will retry. This intentionally avoids paging weekly
        during a Dynatrace incident.
      - Operator-facing errors (missing schemas.txt, malformed entry,
        no creds set): exit non-zero with a clear message.

.PARAMETER WhatIf
    Compute the proposed catalog and print the diff summary without
    writing config/catalog/catalog.settings.json. The CI workflow runs
    without -WhatIf; the Pester suite runs with -WhatIf against a
    stubbed schema fetcher.

.PARAMETER OutputPath
    Override the destination catalog path. Defaults to the repo's
    config/catalog/catalog.settings.json. Tests use a temp file.

.PARAMETER InputsPath
    Override the schemas.txt path. Defaults to the repo's
    config/catalog/schemas.txt. Tests use a temp file.

.PARAMETER MonacoExe
    Override the Monaco executable lookup; passes through to
    _Common.Resolve-MonacoExe.

.PARAMETER FetchSchemaScript
    Internal hook used by the Pester suite to substitute a fake schema
    provider for the real `monaco generate schema` call. The block
    receives a single $SchemaId positional parameter and must return
    either a [pscustomobject] equivalent to what `ConvertFrom-Json`
    produces from a real schema response (specifically: accessed via
    .PSObject.Properties for optional-field detection, so plain
    hashtables won't work) or $null to signal "schema not resolvable".
    Do not set this in production; the workflow leaves it empty so the
    real monaco invocation is used.

.EXAMPLE
    # Dry inspection. Prints the diff summary, leaves catalog.settings.json untouched.
    ./scripts/monaco/Sync-CatalogFromSchemas.ps1 -WhatIf

.EXAMPLE
    # Real refresh. Writes catalog.settings.json and regenerates modules.
    ./scripts/monaco/Sync-CatalogFromSchemas.ps1
    ./scripts/monaco/Sync-ConfigCatalog.ps1   # regenerate scaffolds
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $OutputPath,
    [string] $InputsPath,
    [string] $MonacoExe,
    [scriptblock] $FetchSchemaScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_Common.ps1"

# Two parents up from scripts/monaco/ -> repo root (mirrors Sync-ConfigCatalog).
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $InputsPath)  { $InputsPath  = Join-Path $repoRoot 'config/catalog/schemas.txt' }
if (-not $OutputPath)  { $OutputPath  = Join-Path $repoRoot 'config/catalog/catalog.settings.json' }

# UTF-8 NoBOM writer — same pattern as Sync-ConfigCatalog.ps1 so the
# -Check gate downstream stays byte-deterministic across PS editions.
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Diag {
    param([string] $Message)
    [Console]::Error.WriteLine("[Sync-CatalogFromSchemas] $Message")
}

function Read-SchemasInputFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Inputs file not found: $Path"
    }
    $lines = [System.IO.File]::ReadAllLines($Path)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }
        # Validate shape: lowercase letters / digits / dot / colon / slash / hyphen.
        # Same character class allowed in catalog.settings 'id' field.
        if ($line -notmatch '^[a-z][a-z0-9.:/-]*[a-z0-9]$') {
            throw "Inputs file $Path contains an invalid schema ID: '$line'. Allowed characters: lowercase letters, digits, '.', ':', '/', '-'."
        }
        if ($ids.Contains($line)) {
            throw "Inputs file $Path contains a duplicate schema ID: '$line'."
        }
        $ids.Add($line)
    }
    if ($ids.Count -eq 0) {
        throw "Inputs file $Path declares zero schema IDs. Add at least one row, or delete the file if you genuinely want an empty catalog."
    }
    return ,$ids.ToArray()
}

function Read-ExistingCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        # Treat a missing catalog as "no curated state to preserve" rather
        # than an error: first-run on a fresh repo should still work.
        return @{}
    }
    $raw = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
    $obj = $raw | ConvertFrom-Json
    $byId = @{}
    if ($obj.PSObject.Properties['schemas']) {
        foreach ($entry in @($obj.schemas)) {
            $byId[$entry.id] = $entry
        }
    }
    return $byId
}

function Get-SchemaForId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SchemaId,
        [string] $MonacoExe,
        [scriptblock] $FetchSchemaScript
    )

    # Test hook: if a script-block was supplied, call it and trust it.
    if ($FetchSchemaScript) {
        return (& $FetchSchemaScript $SchemaId)
    }

    # Real path: invoke `monaco generate schema --schema <id>` via the
    # shared Invoke-MonacoCommand helper and parse the stdout as JSON.
    $exe = Resolve-MonacoExe -MonacoExe $MonacoExe
    $result = Invoke-MonacoCommand -MonacoExe $exe -Arguments @('generate', 'schema', '--schema', $SchemaId) -CaptureOutput
    if ($result.ExitCode -ne 0) {
        Write-Diag "monaco generate schema --schema $SchemaId exited with code $($result.ExitCode); treating as unresolvable. stderr: $(($result.StdErr -split [Environment]::NewLine | Select-Object -First 3) -join ' | ')"
        return $null
    }
    if (-not $result.StdOut) {
        Write-Diag "monaco generate schema --schema $SchemaId produced no stdout; treating as unresolvable."
        return $null
    }
    try {
        return ($result.StdOut | ConvertFrom-Json)
    } catch {
        Write-Diag "monaco generate schema --schema $SchemaId produced non-JSON stdout: $($_.Exception.Message)"
        return $null
    }
}

function New-CatalogEntryFromSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SchemaId,
        [Parameter(Mandatory)]            $Schema,         # parsed JSON object, untyped (pscustomobject or hashtable)
        $Existing                                          # existing catalog entry (pscustomobject) or $null
    )

    # liveFields: top-level property names from the schema, sorted for
    # deterministic output. If the schema doesn't expose properties (rare
    # for settings 2.0; can happen for some classic APIs), fall back to
    # an empty list.
    $liveFields = @()
    if ($Schema -and $Schema.PSObject.Properties['properties']) {
        $liveFields = @($Schema.properties.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    }

    # summary: prefer the schema's own description/title; fall back to
    # the existing entry's curated summary if present; final fallback is
    # a generic placeholder a human will replace during PR review.
    $summary = ''
    if ($Schema -and $Schema.PSObject.Properties['description'] -and $Schema.description) {
        $summary = [string]$Schema.description
    } elseif ($Schema -and $Schema.PSObject.Properties['title'] -and $Schema.title) {
        $summary = "$($Schema.title) settings type."
    } elseif ($Existing -and $Existing.PSObject.Properties['summary'] -and $Existing.summary) {
        $summary = [string]$Existing.summary
    } else {
        $summary = "TODO: assign a curated summary for $SchemaId."
    }

    # family, displayName, scope, commonParameters: preserve from the
    # existing entry if there is one. Otherwise emit defaults that flag
    # the entry as needing human attention.
    $family       = if ($Existing) { [string]$Existing.family }            else { 'misc' }
    $displayName  = if ($Existing) { [string]$Existing.displayName }       else { $SchemaId }
    $scope        = if ($Existing) { [string]$Existing.scope }             else { 'environment' }
    $commonParams = @()
    if ($Existing -and $Existing.PSObject.Properties['commonParameters'] -and $Existing.commonParameters) {
        $commonParams = @($Existing.commonParameters)
    }

    return [ordered]@{
        id               = $SchemaId
        family           = $family
        displayName      = $displayName
        scope            = $scope
        summary          = $summary
        commonParameters = $commonParams
        liveFields       = $liveFields
    }
}

function ConvertTo-StrictJsonString {
    [CmdletBinding()]
    param([AllowNull()] [string] $Value)
    # PowerShell's built-in ConvertTo-Json HTML-escapes '<', '>', "'" for
    # JS-safety even when the output isn't going to a browser. That makes
    # this script's catalog.settings.json byte-different from a
    # hand-authored copy with raw '<' in comments / paths. This helper
    # emits ONLY the JSON-spec-required escapes (backslash, quote, control
    # chars) so the refreshed catalog stays human-readable.
    if ($null -eq $Value) { return 'null' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"'  { $null = $sb.Append('\"'); continue }
            '\'  { $null = $sb.Append('\\'); continue }
            "`b" { $null = $sb.Append('\b'); continue }
            "`f" { $null = $sb.Append('\f'); continue }
            "`n" { $null = $sb.Append('\n'); continue }
            "`r" { $null = $sb.Append('\r'); continue }
            "`t" { $null = $sb.Append('\t'); continue }
            default {
                $code = [int][char]$ch
                if ($code -lt 0x20) {
                    $null = $sb.Append(('\u{0:x4}' -f $code))
                } else {
                    $null = $sb.Append($ch)
                }
            }
        }
    }
    $null = $sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-StrictJsonStringArray {
    [CmdletBinding()]
    param([AllowNull()] $Values)
    if ($null -eq $Values) { return '[]' }
    # Drop null elements so a re-emitted existing entry whose source
    # had no liveFields field doesn't serialize as [null]. (When the
    # caller does @($obj.missingProperty), PowerShell produces a
    # one-element array containing $null.)
    $clean = @($Values | Where-Object { $null -ne $_ -and $_ -ne '' })
    if ($clean.Count -eq 0) { return '[]' }
    return '[' + (($clean | ForEach-Object { ConvertTo-StrictJsonString ([string]$_) }) -join ',') + ']'
}

function Get-EntryField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )
    # Field access that works for BOTH the [ordered]@{} (OrderedDictionary)
    # entries built by New-CatalogEntryFromSchema AND the [pscustomobject]
    # entries loaded from the existing catalog via ConvertFrom-Json.
    # The two types expose membership differently: dictionaries via
    # .Contains(name), pscustomobjects via .PSObject.Properties.
    if ($null -eq $Entry) { return $Default }
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) {
            $val = $Entry[$Name]
            if ($null -eq $val) { return $Default }
            return $val
        }
        return $Default
    }
    $names = @($Entry.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -contains $Name) {
        $val = $Entry.$Name
        if ($null -eq $val) { return $Default }
        return $val
    }
    return $Default
}

function Format-CatalogJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SchemaRef,
        [Parameter(Mandatory)] [string] $CommentText,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] $Entries           # array of [ordered] hashtables from New-CatalogEntryFromSchema
    )

    # Hand-format for byte-deterministic output across PS editions
    # (PS 5.1 vs PS 7 ConvertTo-Json disagrees on indentation and line
    # endings; learned from PR #8). LF line endings throughout; trailing
    # LF on the file.
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('{').Append("`n")
    $null = $sb.Append('  "$schema": ').Append((ConvertTo-StrictJsonString $SchemaRef)).Append(',').Append("`n")
    $null = $sb.Append('  "_comment": ').Append((ConvertTo-StrictJsonString $CommentText)).Append(',').Append("`n")
    $null = $sb.Append('  "version": ').Append((ConvertTo-StrictJsonString $Version)).Append(',').Append("`n")
    $null = $sb.Append('  "schemas": [').Append("`n")

    $entryArr = @($Entries)
    for ($i = 0; $i -lt $entryArr.Count; $i++) {
        $entry = $entryArr[$i]
        # Use Get-EntryField so a re-emitted existing entry that lacks
        # liveFields (or commonParameters, or any other optional field)
        # serializes as [] instead of [null] / throws.
        $idVal      = [string](Get-EntryField -Entry $entry -Name 'id'          -Default '')
        $familyVal  = [string](Get-EntryField -Entry $entry -Name 'family'      -Default 'misc')
        $displayVal = [string](Get-EntryField -Entry $entry -Name 'displayName' -Default $idVal)
        $scopeVal   = [string](Get-EntryField -Entry $entry -Name 'scope'       -Default 'environment')
        $summaryVal = [string](Get-EntryField -Entry $entry -Name 'summary'     -Default '')
        $commonArr  =        (Get-EntryField -Entry $entry -Name 'commonParameters' -Default @())
        $liveArr    =        (Get-EntryField -Entry $entry -Name 'liveFields'       -Default @())

        $null = $sb.Append('    {').Append("`n")
        $null = $sb.Append('      "id": ').Append((ConvertTo-StrictJsonString $idVal)).Append(',').Append("`n")
        $null = $sb.Append('      "family": ').Append((ConvertTo-StrictJsonString $familyVal)).Append(',').Append("`n")
        $null = $sb.Append('      "displayName": ').Append((ConvertTo-StrictJsonString $displayVal)).Append(',').Append("`n")
        $null = $sb.Append('      "scope": ').Append((ConvertTo-StrictJsonString $scopeVal)).Append(',').Append("`n")
        $null = $sb.Append('      "summary": ').Append((ConvertTo-StrictJsonString $summaryVal)).Append(',').Append("`n")
        $null = $sb.Append('      "commonParameters": ').Append((ConvertTo-StrictJsonStringArray $commonArr)).Append(',').Append("`n")
        $null = $sb.Append('      "liveFields": ').Append((ConvertTo-StrictJsonStringArray $liveArr)).Append("`n")
        $suffix = if ($i -lt ($entryArr.Count - 1)) { '    },' } else { '    }' }
        $null = $sb.Append($suffix).Append("`n")
    }

    $null = $sb.Append('  ]').Append("`n")
    $null = $sb.Append('}').Append("`n")
    return $sb.ToString()
}

function Compare-Catalogs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Before,           # hashtable id -> entry (from Read-ExistingCatalog)
        [Parameter(Mandatory)] $AfterEntries,     # array of [ordered] hashtables
        [Parameter(Mandatory)] $UnresolvedIds     # array of schema IDs that failed to resolve
    )

    $afterIds = @($AfterEntries | ForEach-Object { $_.id })
    $beforeIds = @($Before.Keys)

    $added   = @($afterIds  | Where-Object { $beforeIds -notcontains $_ })
    $removed = @($beforeIds | Where-Object { $afterIds  -notcontains $_ -and $UnresolvedIds -notcontains $_ })
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $AfterEntries) {
        if (-not $Before.ContainsKey($entry.id)) { continue }
        $beforeEntry = $Before[$entry.id]
        $summaryChanged = ([string]$beforeEntry.summary) -ne ([string]$entry.summary)
        $beforeLive = if ($beforeEntry.PSObject.Properties['liveFields']) { @($beforeEntry.liveFields) } else { @() }
        $afterLive  = @($entry.liveFields)
        $liveChanged = ((($beforeLive | Sort-Object) -join '|') -ne (($afterLive | Sort-Object) -join '|'))
        if ($summaryChanged -or $liveChanged) {
            $changed.Add($entry.id)
        }
    }

    return [pscustomobject]@{
        Added        = $added
        Removed      = $removed
        Changed      = @($changed)
        Unresolvable = $UnresolvedIds
    }
}

# ---- main ----

Write-Diag "Inputs:  $InputsPath"
Write-Diag "Output:  $OutputPath"

$schemaIds = Read-SchemasInputFile -Path $InputsPath
$existing  = Read-ExistingCatalog  -Path $OutputPath

# Validate setup prerequisites UP FRONT (non-zero exit on failure) so
# operator-facing problems can't get silently swallowed by the
# per-schema try/catch below and treated as a transient
# "environment unreachable" condition. We skip these checks when a
# -FetchSchemaScript stub is provided since the stub replaces the real
# monaco invocation entirely.
if (-not $FetchSchemaScript) {
    # 1. Monaco must be locatable.
    $null = Resolve-MonacoExe -MonacoExe $MonacoExe

    # 2. Dynatrace tenant URL must be set; otherwise monaco will fail per
    # schema and the loop will mark every ID 'unresolvable', producing a
    # bogus catalog refresh PR full of TODO placeholders. Fail fast and
    # loud instead.
    if (-not $env:DT_ENVIRONMENT) {
        throw "DT_ENVIRONMENT is not set. Sync-CatalogFromSchemas.ps1 needs a Dynatrace platform URL to fetch live schemas. Set DT_ENVIRONMENT (and one of DT_PLATFORM_TOKEN or OAUTH_CLIENT_ID+OAUTH_CLIENT_SECRET) before running, or pass -FetchSchemaScript for offline test use."
    }

    # 3. At least one auth path must be configured.
    $hasPlatformToken = [bool]$env:DT_PLATFORM_TOKEN
    $hasOAuth         = ([bool]$env:OAUTH_CLIENT_ID) -and ([bool]$env:OAUTH_CLIENT_SECRET)
    if (-not ($hasPlatformToken -or $hasOAuth)) {
        throw "No Dynatrace credentials available. Set DT_PLATFORM_TOKEN, or both OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET, before running Sync-CatalogFromSchemas.ps1."
    }
}

$unresolved      = New-Object System.Collections.Generic.List[string]
$entries         = New-Object System.Collections.Generic.List[object]
$envFailureCount = 0
$resolvedCount   = 0   # count of IDs that returned a real schema; placeholders DON'T count

foreach ($id in $schemaIds) {
    try {
        $schema = Get-SchemaForId -SchemaId $id -MonacoExe $MonacoExe -FetchSchemaScript $FetchSchemaScript
    } catch {
        # An unrecoverable exception (not a per-schema failure) -- treat as
        # whole-environment unreachable per Design 002 section 7. Log
        # loudly, continue counting toward the threshold.
        Write-Diag "FATAL while fetching ${id}: $($_.Exception.Message)"
        $envFailureCount += 1
        $schema = $null
    }

    if ($null -eq $schema) {
        $unresolved.Add($id)
        Write-Diag "Unresolved: $id"
        continue
    }

    $existingEntry = if ($existing.ContainsKey($id)) { $existing[$id] } else { $null }
    $entry = New-CatalogEntryFromSchema -SchemaId $id -Schema $schema -Existing $existingEntry
    $entries.Add($entry)
    $resolvedCount += 1
}

# Unresolvable IDs that DO have an existing entry are re-added below
# (preserves the curated entry across a transient upstream failure).
# Unresolvable IDs that DON'T have an existing entry would otherwise
# silently disappear from the catalog AND from modules/configs/ on the
# next Sync-ConfigCatalog regen -- a brand-new schema added to
# schemas.txt would get dropped by the very first refresh that can't
# resolve it. Emit a placeholder entry so the catalog stays aligned
# with schemas.txt and a human reviewer can decide whether to retry,
# remove the ID, or curate the placeholder.
foreach ($id in $unresolved) {
    if ($existing.ContainsKey($id)) { continue }
    Write-Diag "Unresolved + no existing entry; emitting placeholder for $id"
    $placeholder = [ordered]@{
        id               = $id
        family           = 'misc'
        displayName      = $id
        scope            = 'environment'
        summary          = "TODO: Dynatrace returned no schema for $id at refresh time. Either retry on the next cron once upstream recovers, remove the ID from schemas.txt, or curate a placeholder summary by hand."
        commonParameters = @()
        liveFields       = @()
    }
    $entries.Add($placeholder)
}

# Whole-environment-unreachable heuristic: if NOT A SINGLE schema
# resolved AND at least one ID was attempted, treat the cron as a
# no-op rather than producing a refresh PR full of placeholders /
# deletions. The earlier version gated on $envFailureCount > 0, but
# Get-SchemaForId converts the common failure modes (non-zero monaco
# exit, empty stdout, non-JSON stdout) to $null without throwing -- so
# a complete outage often leaves $envFailureCount = 0 yet
# $resolvedCount = 0. Gating on $resolvedCount alone is the only
# correct check.
# Split into intermediate booleans -- PS 5.1's @($list).Count combined
# with -and inside a single if-expression can trip 'Argument types do
# not match' depending on the list's runtime shape.
$attemptedCount = @($schemaIds).Count
$shouldBailOut  = ($resolvedCount -eq 0) -and ($attemptedCount -gt 0)
if ($shouldBailOut) {
    Write-Diag "ZERO schemas resolved out of $attemptedCount attempted; assuming environment unreachable. Exiting 0 without changes per Design 002."
    exit 0
}

# Compute and print the diff summary.
$diff = Compare-Catalogs -Before $existing -AfterEntries $entries -UnresolvedIds $unresolved
Write-Host ""
Write-Host "Diff summary:"
Write-Host ("  added:        {0}" -f (@($diff.Added).Count))
Write-Host ("  removed:      {0}" -f (@($diff.Removed).Count))
Write-Host ("  changed:      {0}" -f (@($diff.Changed).Count))
Write-Host ("  unresolvable: {0}" -f (@($diff.Unresolvable).Count))
if (@($diff.Added).Count -gt 0)        { Write-Host "  + new schemas (family: misc until reassigned):";   foreach ($x in $diff.Added)        { Write-Host "      $x" } }
if (@($diff.Removed).Count -gt 0)      { Write-Host "  - schemas removed from inputs:";                    foreach ($x in $diff.Removed)      { Write-Host "      $x" } }
if (@($diff.Changed).Count -gt 0)      { Write-Host "  ~ schemas with refreshed summary/liveFields:";      foreach ($x in $diff.Changed)      { Write-Host "      $x" } }
if (@($diff.Unresolvable).Count -gt 0) {
    Write-Host "  ! schemas not resolvable upstream this run:"
    Write-Host "    (existing entries preserved unchanged; brand-new IDs got a TODO placeholder under family: misc)"
    foreach ($x in $diff.Unresolvable) { Write-Host "      $x" }
}

# Re-include unresolvable entries from the existing catalog so a transient
# upstream blip doesn't accidentally remove a curated entry from the
# committed catalog.
foreach ($id in $unresolved) {
    if ($existing.ContainsKey($id)) {
        $entries.Add($existing[$id])
    }
}
# Stable ordering: same order as schemas.txt.
$orderedEntries = @()
$entriesById = @{}
foreach ($e in $entries) { $entriesById[$e.id] = $e }
foreach ($id in $schemaIds) {
    if ($entriesById.ContainsKey($id)) { $orderedEntries += ,$entriesById[$id] }
}

$catalogText = Format-CatalogJson `
    -SchemaRef   './schema.json' `
    -CommentText 'Reflected catalog of Dynatrace settings 2.0 schemas and classic-API config types that dt-pilot ships scaffolds for. Sync-ConfigCatalog.ps1 reads this file and regenerates modules/configs/<family>/<safe-id>/ from each entry (where <safe-id> is the entry id with : and / replaced by -; see docs/CONFIG-COVERAGE.md). The summary and liveFields fields are refreshed weekly by scripts/monaco/Sync-CatalogFromSchemas.ps1 from live Dynatrace schemas; the family and commonParameters fields remain hand-curated.' `
    -Version     '1.0' `
    -Entries     $orderedEntries

if ($PSCmdlet.ShouldProcess($OutputPath, "Write refreshed catalog")) {
    [System.IO.File]::WriteAllText($OutputPath, $catalogText, $script:Utf8NoBom)
    Write-Host ""
    Write-Host "Wrote $OutputPath ($($orderedEntries.Count) entries)." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "WhatIf: not writing $OutputPath." -ForegroundColor Yellow
}

exit 0
