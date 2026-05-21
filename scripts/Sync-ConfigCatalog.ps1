<#
.SYNOPSIS
    Regenerate scaffolds under modules/configs/<family>/<id>/ from
    config/catalog/catalog.settings.json. Repo-wide gate; takes no
    -Path parameter.

.DESCRIPTION
    Reads the catalog and, for each entry, writes three files under
    modules/configs/<family>/<safe-id>/ :
        - SCAFFOLD.md       (human-readable rationale + usage)
        - config.yaml.example  (Monaco config.yaml with the entry's
          commonParameters pre-declared and TODO markers for values)
        - template.json.example  (minimal {{ .parameter }}-bearing
          JSON payload; intentionally NOT a valid Dynatrace payload —
          run monaco generate schema and fill in real fields)

    Every generated file has a 'GENERATED FILE — do not hand-edit'
    header. Hand-edits will be overwritten on the next sync.

    Use -Check in CI to fail if the on-disk modules drift from what
    the catalog would produce. Use without -Check locally to
    regenerate.

.PARAMETER Check
    Run in check mode: regenerate to a temp directory, diff against
    modules/configs/, exit non-zero on any difference. Does NOT
    modify modules/configs/. The CI gate uses this mode.

.EXAMPLE
    ./scripts/Sync-ConfigCatalog.ps1

.EXAMPLE
    ./scripts/Sync-ConfigCatalog.ps1 -Check
#>

[CmdletBinding()]
param(
    [switch] $Check
)

# Script uses only PS 5.1-compatible features plus .NET BCL calls for
# byte-correct UTF-8 NoBOM I/O. Runs identically on Windows PowerShell 5.1
# and PowerShell 7+; CI uses pwsh 7+.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $repoRoot 'config/catalog/catalog.settings.json'
$modulesRoot = Join-Path $repoRoot 'modules/configs'

if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "Catalog not found: $catalogPath"
}

# UTF-8 NoBOM for every file we write. Using [System.IO.File]::WriteAllText
# with an explicit UTF8Encoding($false) produces byte-identical output
# across PowerShell editions; Set-Content -Encoding utf8 disagrees between
# 5.1 (BOM) and 7+ (no BOM), which would silently break the -Check gate.
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Utf8NoBom {
    param([string] $Path, [string] $Content)
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Read the catalog as UTF-8 explicitly so non-ASCII content cannot be
# corrupted by ANSI default decoding under a non-pwsh interpreter.
$catalogRaw = [System.IO.File]::ReadAllText($catalogPath, $script:Utf8NoBom)
$catalog = $catalogRaw | ConvertFrom-Json

function ConvertTo-SafeName {
    param([string] $Id)
    # Convert 'builtin:problem.notifications/email' -> 'builtin-problem.notifications-email'.
    # ':' and '/' are not safe across all filesystems; '.' and '-' are.
    return ($Id -replace '[:/]', '-')
}

function New-ScaffoldFiles {
    param(
        [Parameter(Mandatory)] [pscustomobject] $Entry,
        [Parameter(Mandatory)] [string] $TargetDir
    )

    $safeId = ConvertTo-SafeName -Id $Entry.id
    # Force an array even if commonParameters is a single string (PS happily
    # unwraps single-element @(...) into a scalar on assignment, which would
    # break .Count under strict mode).
    [string[]] $params = @()
    if ($Entry.PSObject.Properties['commonParameters'] -and $null -ne $Entry.commonParameters) {
        [string[]] $params = @($Entry.commonParameters)
    }

    # SCAFFOLD.md
    $scaffoldMd = @()
    $scaffoldMd += "<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/Sync-ConfigCatalog.ps1 -->"
    $scaffoldMd += "<!-- SPDX-License-Identifier: MIT -->"
    $scaffoldMd += "# Scaffold: $($Entry.displayName)"
    $scaffoldMd += ""
    $scaffoldMd += "**Schema ID:** ``$($Entry.id)``"
    $scaffoldMd += "**Family:** $($Entry.family)"
    $scaffoldMd += "**Default scope:** $($Entry.scope)"
    $scaffoldMd += ""
    $scaffoldMd += "## Summary"
    $scaffoldMd += ""
    $scaffoldMd += $Entry.summary
    $scaffoldMd += ""
    $scaffoldMd += "## How to adopt"
    $scaffoldMd += ""
    $scaffoldMd += "1. Copy the two ``*.example`` files in this directory into your own project at ``projects/<your-project>/$safeId/`` and rename:"
    $scaffoldMd += "   - ``config.yaml.example`` -> ``config.yaml``"
    $scaffoldMd += "   - ``template.json.example`` -> ``template.json`` (or rename to match what the new ``config.yaml`` references)"
    $scaffoldMd += "2. Fill in the ``TODO`` markers in ``config.yaml`` with real parameter values."
    $scaffoldMd += "3. Replace the placeholder ``template.json`` body with the real Dynatrace payload. Get the live schema first via:"
    $scaffoldMd += ""
    $scaffoldMd += '   ```powershell'
    $scaffoldMd += "   ./scripts/Invoke-MonacoGenerate.ps1 -Path . -Type schema -Schema $($Entry.id)"
    $scaffoldMd += '   ```'
    $scaffoldMd += ""
    $scaffoldMd += "4. Register the project in the manifest's ``projects:`` list, then validate and dry-run before deploying."
    if ($params.Count -gt 0) {
        $scaffoldMd += ""
        $scaffoldMd += "## Pre-declared parameters"
        $scaffoldMd += ""
        foreach ($p in $params) { $scaffoldMd += "- ``$p``" }
    }

    # config.yaml.example
    $configYaml = @()
    $configYaml += "# GENERATED FILE - do not hand-edit. Regenerate with ./scripts/Sync-ConfigCatalog.ps1"
    $configYaml += "# SPDX-License-Identifier: MIT"
    $configYaml += "# Scaffold for $($Entry.displayName) ($($Entry.id))."
    $configYaml += "# Copy this file to projects/<your-project>/$safeId/config.yaml and fill in the TODO values."
    $configYaml += "configs:"
    $configYaml += "  - id: TODO-config-id"
    $configYaml += "    type:"
    $configYaml += "      settings:"
    $configYaml += "        schema: $($Entry.id)"
    $configYaml += "        scope: $($Entry.scope)"
    $configYaml += "    config:"
    $configYaml += "      name: TODO-display-name"
    $configYaml += "      template: template.json"
    if ($params.Count -gt 0) {
        $configYaml += "      parameters:"
        foreach ($p in $params) {
            $configYaml += "        ${p}:"
            $configYaml += "          type: value"
            $configYaml += "          value: TODO-$p"
        }
    }

    # template.json.example — hand-formatted instead of ConvertTo-Json
    # because PS 5.1 and PS 7 disagree on both indentation (4 vs 2 spaces)
    # and line endings (CRLF vs LF), which would break -Check across hosts.
    $jsonLines = New-Object System.Collections.Generic.List[string]
    $jsonLines.Add('{')
    $jsonEntries = New-Object System.Collections.Generic.List[string]
    $jsonEntries.Add('  "_comment": "GENERATED FILE - do not hand-edit. Regenerate with ./scripts/Sync-ConfigCatalog.ps1. Replace this with the real Dynatrace payload; run monaco generate schema for the authoritative shape."')
    if ($params.Count -gt 0) {
        foreach ($p in $params) {
            $jsonEntries.Add(('  "{0}": "{{{{ .{0} }}}}"' -f $p))
        }
    } else {
        $jsonEntries.Add('  "placeholder": "{{ .TODO }}"')
    }
    for ($k = 0; $k -lt $jsonEntries.Count; $k++) {
        $suffix = if ($k -lt ($jsonEntries.Count - 1)) { ',' } else { '' }
        $jsonLines.Add($jsonEntries[$k] + $suffix)
    }
    $jsonLines.Add('}')
    $jsonText = ($jsonLines -join "`n") + "`n"

    # Write files.
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        $null = New-Item -ItemType Directory -Path $TargetDir -Force
    }
    Write-Utf8NoBom (Join-Path $TargetDir 'SCAFFOLD.md')            (($scaffoldMd -join "`n") + "`n")
    Write-Utf8NoBom (Join-Path $TargetDir 'config.yaml.example')    (($configYaml  -join "`n") + "`n")
    Write-Utf8NoBom (Join-Path $TargetDir 'template.json.example')  $jsonText
}

# Pick an output root: live modules root, or a temp shadow for -Check.
if ($Check) {
    $outRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-catalog-check-" + [System.Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $outRoot -Force
} else {
    # Wipe-and-regenerate makes the script idempotent and self-healing:
    # removing a catalog entry now also removes its scaffold instead of
    # leaving an orphan that -Check would flag on the next run.
    # modules/configs/ is fully owned by this script, so a recursive
    # wipe of the entries inside it is safe.
    if (Test-Path -LiteralPath $modulesRoot -PathType Container) {
        Get-ChildItem -LiteralPath $modulesRoot -Force | Remove-Item -Recurse -Force
    } else {
        $null = New-Item -ItemType Directory -Path $modulesRoot -Force
    }
    $outRoot = $modulesRoot
}

foreach ($entry in $catalog.schemas) {
    $safeId = ConvertTo-SafeName -Id $entry.id
    $dir = Join-Path (Join-Path $outRoot $entry.family) $safeId
    New-ScaffoldFiles -Entry $entry -TargetDir $dir
}

if ($Check) {
    # Diff outRoot against modulesRoot — every file must exist in both
    # with byte-identical content, and modulesRoot must contain nothing
    # extra under family directories the catalog produces.
    $drift = New-Object System.Collections.Generic.List[string]

    $generatedFiles = Get-ChildItem -LiteralPath $outRoot -Recurse -File
    foreach ($g in $generatedFiles) {
        $rel = $g.FullName.Substring($outRoot.Length).TrimStart('\','/')
        $onDisk = Join-Path $modulesRoot $rel
        if (-not (Test-Path -LiteralPath $onDisk -PathType Leaf)) {
            $drift.Add("missing on disk: modules/configs/$($rel.Replace('\','/'))")
            continue
        }
        $hashGen = (Get-FileHash -LiteralPath $g.FullName -Algorithm SHA256).Hash
        $hashOnDisk = (Get-FileHash -LiteralPath $onDisk -Algorithm SHA256).Hash
        if ($hashGen -ne $hashOnDisk) {
            $drift.Add("content drift: modules/configs/$($rel.Replace('\','/'))")
        }
    }

    # Detect orphan files on disk under families the catalog produces.
    $catalogFamilies = ($catalog.schemas | ForEach-Object { $_.family } | Sort-Object -Unique)
    foreach ($fam in $catalogFamilies) {
        $famDir = Join-Path $modulesRoot $fam
        if (-not (Test-Path -LiteralPath $famDir)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $famDir -Recurse -File)) {
            $rel = $f.FullName.Substring($modulesRoot.Length).TrimStart('\','/')
            $shadow = Join-Path $outRoot $rel
            if (-not (Test-Path -LiteralPath $shadow -PathType Leaf)) {
                $drift.Add("orphan on disk: modules/configs/$($rel.Replace('\','/'))")
            }
        }
    }

    Remove-Item -LiteralPath $outRoot -Recurse -Force -ErrorAction SilentlyContinue

    if ($drift.Count -gt 0) {
        Write-Host "Reflected catalog drift detected:" -ForegroundColor Red
        foreach ($d in $drift) { Write-Host "  - $d" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Regenerate locally with: ./scripts/Sync-ConfigCatalog.ps1" -ForegroundColor Yellow
        Write-Host "Then commit the modules/configs changes in the same PR as the catalog edit." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "Reflected catalog is in sync ($(@($catalog.schemas).Count) entries)." -ForegroundColor Green
    exit 0
}

Write-Host "Wrote $(@($catalog.schemas).Count) scaffolds under modules/configs/." -ForegroundColor Green
exit 0
