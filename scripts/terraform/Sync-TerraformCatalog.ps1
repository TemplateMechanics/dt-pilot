<#
.SYNOPSIS
    Regenerate scaffolds under modules/terraform/configs/<family>/<resource>/
    from config/catalog/terraform.json. Repo-wide gate; takes no -Path
    parameter.

.DESCRIPTION
    Mirrors scripts/monaco/Sync-ConfigCatalog.ps1 for the Terraform
    backend. Reads the catalog and, for each entry, writes three files
    under modules/terraform/configs/<family>/<resource>/:
        - SCAFFOLD.md          (human-readable rationale + usage)
        - main.tf.example      (HCL resource skeleton with TODO markers)
        - variables.tf.example (typed + documented variable declarations
                                for the entry's commonVariables)

    Every generated file carries a 'GENERATED FILE -- do not hand-edit'
    header. Hand-edits are overwritten on the next sync.

    Use -Check in CI to fail if the on-disk modules drift from what
    the catalog would produce. Use without -Check locally to regenerate.

    Byte-deterministic across PS 5.1 / 7 via UTF-8 NoBOM writes and a
    hand-rolled JSON-free formatter (HCL only).

.PARAMETER Check
    Run in check mode: regenerate to a temp directory, diff against
    modules/terraform/configs/, exit non-zero on any difference. Does
    NOT modify the live tree. CI uses this mode via Pre-Commit.ps1.

.EXAMPLE
    ./scripts/terraform/Sync-TerraformCatalog.ps1

.EXAMPLE
    ./scripts/terraform/Sync-TerraformCatalog.ps1 -Check
#>

[CmdletBinding()]
param([switch] $Check)

# Uses only PS 5.1-compatible features plus .NET BCL calls for
# byte-correct UTF-8 NoBOM I/O. CI runs pwsh 7+; same output either way.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# scripts/terraform/ -> scripts -> repo root.
$repoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$catalogPath = Join-Path $repoRoot 'config/catalog/terraform.json'
$modulesRoot = Join-Path $repoRoot 'modules/terraform/configs'

if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "Catalog not found: $catalogPath"
}

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Utf8NoBom {
    param([string] $Path, [string] $Content)
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

$catalogRaw = [System.IO.File]::ReadAllText($catalogPath, $script:Utf8NoBom)
$catalog = $catalogRaw | ConvertFrom-Json

if (-not $catalog.PSObject.Properties['resources'] -or $null -eq $catalog.resources) {
    throw "Catalog at $catalogPath has no 'resources' field."
}
$resourcesArr = @($catalog.resources)
if ($resourcesArr.Count -eq 0) {
    throw "Catalog at $catalogPath has an empty 'resources' array."
}

function New-ScaffoldFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Entry,
        [Parameter(Mandatory)] [string] $TargetDir
    )

    # Defensive array coercion (single-element @(...) unwraps under
    # strict mode without [string[]] / [object[]] cast).
    [object[]] $commonVars = @()
    if ($Entry.PSObject.Properties['commonVariables'] -and $null -ne $Entry.commonVariables) {
        [object[]] $commonVars = @($Entry.commonVariables)
    }

    # SCAFFOLD.md
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("<!-- GENERATED FILE - do not hand-edit. Regenerate with ./scripts/terraform/Sync-TerraformCatalog.ps1 -->")
    $md.Add("<!-- SPDX-License-Identifier: MIT -->")
    $md.Add("# Scaffold: $($Entry.displayName)")
    $md.Add("")
    $md.Add("**Terraform resource type:** ``$($Entry.resourceType)``")
    $md.Add("**Family:** $($Entry.family)")
    $md.Add("")
    $md.Add("## Summary")
    $md.Add("")
    $md.Add($Entry.summary)
    $md.Add("")
    $md.Add("## How to adopt")
    $md.Add("")
    $md.Add("1. Copy the two ``*.example`` files into your project at any path Terraform discovers (typically the project root or a sibling ``modules/`` directory), and rename:")
    $md.Add("   - ``main.tf.example`` -> ``main.tf`` (or merge into an existing main.tf)")
    $md.Add("   - ``variables.tf.example`` -> ``variables.tf`` (or merge into an existing variables.tf)")
    $md.Add("2. Fill in the ``TODO`` markers with real values; replace placeholder argument shapes with the real provider schema from:")
    $md.Add("   [registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/$($Entry.resourceType -replace '^dynatrace_','')](https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs/resources/$($Entry.resourceType -replace '^dynatrace_',''))")
    $md.Add("3. ``./scripts/terraform/Validate-Terraform.ps1 -Path .`` then ``./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment <env> -Out tfplan``.")
    if ($commonVars.Count -gt 0) {
        $md.Add("")
        $md.Add("## Pre-declared variables")
        $md.Add("")
        foreach ($v in $commonVars) { $md.Add("- ``$($v.name)`` (``$($v.type)``) -- $($v.description)") }
    }

    # main.tf.example -- a minimal HCL skeleton with TODO markers and
    # variable references for the catalog's commonVariables.
    $tf = New-Object System.Collections.Generic.List[string]
    $tf.Add("# GENERATED FILE - do not hand-edit. Regenerate with ./scripts/terraform/Sync-TerraformCatalog.ps1")
    $tf.Add("# SPDX-License-Identifier: MIT")
    $tf.Add("# Scaffold for $($Entry.displayName) ($($Entry.resourceType)).")
    $tf.Add("# Copy this file to your project's main.tf (or merge in) and fill the TODO markers.")
    $tf.Add("")
    $tf.Add("resource ""$($Entry.resourceType)"" ""TODO_local_name"" {")
    foreach ($v in $commonVars) {
        # If the catalog supplies an explicit providerArgument, use it as
        # the LHS so a copied scaffold is valid HCL out of the box (e.g.
        # `name = var.zone_name` for dynatrace_management_zone_v2 whose
        # dt-pilot variable is `zone_name`). When omitted (typical for
        # variables that feed nested blocks like notification.recipient_email
        # or slo.management_zone_id), fall back to `<name> = var.<name>`
        # with a TODO marker so the scaffold won't silently apply with a
        # bogus argument name.
        $hasProviderArg = [bool]($v.PSObject.Properties['providerArgument']) -and $v.providerArgument
        if ($hasProviderArg) {
            $tf.Add("  $($v.providerArgument) = var.$($v.name)")
        } else {
            $tf.Add("  $($v.name) = var.$($v.name)  # TODO: this variable feeds a nested block or has no top-level provider arg -- move into the right block before applying")
        }
    }
    $tf.Add("  # TODO: add the resource-specific blocks from the provider docs.")
    $tf.Add("}")

    # variables.tf.example. Catalog descriptions are author-written
    # free text; before injecting one into an HCL double-quoted string
    # we MUST escape the three characters HCL treats specially:
    #   \ -> \\   (must come first so the rest aren't doubled)
    #   " -> \"
    # plus collapse any embedded newlines to "\n" sequences so a multi-
    # line description doesn't break out of the string and produce
    # syntactically invalid HCL. None of the current catalog entries hit
    # this case, but it's a foot-gun waiting for the first description
    # that needs a literal quote.
    function Format-HclString {
        param([string] $S)
        if ($null -eq $S) { return '' }
        $escaped = $S.Replace('\','\\').Replace('"','\"')
        # Normalize CRLF -> LF first so we don't emit \r\n.
        $escaped = $escaped.Replace("`r`n","`n").Replace("`r","`n").Replace("`n",'\n')
        return $escaped
    }

    $vars = New-Object System.Collections.Generic.List[string]
    $vars.Add("# GENERATED FILE - do not hand-edit. Regenerate with ./scripts/terraform/Sync-TerraformCatalog.ps1")
    $vars.Add("# SPDX-License-Identifier: MIT")
    if ($commonVars.Count -eq 0) {
        $vars.Add("# (No commonVariables declared for this resource. Add your own variable blocks here.)")
    } else {
        foreach ($v in $commonVars) {
            $vars.Add("")
            $vars.Add("variable ""$($v.name)"" {")
            $vars.Add("  type        = $($v.type)")
            $vars.Add("  description = ""$(Format-HclString $v.description)""")
            $vars.Add("}")
        }
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        $null = New-Item -ItemType Directory -Path $TargetDir -Force
    }
    Write-Utf8NoBom (Join-Path $TargetDir 'SCAFFOLD.md')          (($md   -join "`n") + "`n")
    Write-Utf8NoBom (Join-Path $TargetDir 'main.tf.example')      (($tf   -join "`n") + "`n")
    Write-Utf8NoBom (Join-Path $TargetDir 'variables.tf.example') (($vars -join "`n") + "`n")
}

if ($Check) {
    $outRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tf-catalog-check-" + [System.Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $outRoot -Force
} else {
    if (Test-Path -LiteralPath $modulesRoot -PathType Container) {
        Get-ChildItem -LiteralPath $modulesRoot -Force | Remove-Item -Recurse -Force
    } else {
        $null = New-Item -ItemType Directory -Path $modulesRoot -Force
    }
    $outRoot = $modulesRoot
}

foreach ($entry in $resourcesArr) {
    # Safe directory name: drop the dynatrace_ prefix for readability.
    $safeName = ($entry.resourceType -replace '^dynatrace_','')
    $dir = Join-Path (Join-Path $outRoot $entry.family) $safeName
    New-ScaffoldFiles -Entry $entry -TargetDir $dir
}

if ($Check) {
    $drift = New-Object System.Collections.Generic.List[string]
    $generatedFiles = Get-ChildItem -LiteralPath $outRoot -Recurse -File
    foreach ($g in $generatedFiles) {
        $rel = $g.FullName.Substring($outRoot.Length).TrimStart('\','/')
        $onDisk = Join-Path $modulesRoot $rel
        if (-not (Test-Path -LiteralPath $onDisk -PathType Leaf)) {
            $drift.Add("missing on disk: modules/terraform/configs/$($rel.Replace('\','/'))")
            continue
        }
        $hashGen = (Get-FileHash -LiteralPath $g.FullName -Algorithm SHA256).Hash
        $hashOnDisk = (Get-FileHash -LiteralPath $onDisk -Algorithm SHA256).Hash
        if ($hashGen -ne $hashOnDisk) {
            $drift.Add("content drift: modules/terraform/configs/$($rel.Replace('\','/'))")
        }
    }
    # Scan EVERY file under $modulesRoot (not just families the current
    # catalog produces) so removing an entire family / catalog entry
    # surfaces the leftover files as drift. Otherwise a delete-only
    # catalog edit would silently leave orphans on disk.
    if (Test-Path -LiteralPath $modulesRoot -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $modulesRoot -Recurse -File)) {
            $rel = $f.FullName.Substring($modulesRoot.Length).TrimStart('\','/')
            $shadow = Join-Path $outRoot $rel
            if (-not (Test-Path -LiteralPath $shadow -PathType Leaf)) {
                $drift.Add("orphan on disk: modules/terraform/configs/$($rel.Replace('\','/'))")
            }
        }
    }
    Remove-Item -LiteralPath $outRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($drift.Count -gt 0) {
        Write-Host "Reflected Terraform catalog drift detected:" -ForegroundColor Red
        foreach ($d in $drift) { Write-Host "  - $d" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Regenerate locally with: ./scripts/terraform/Sync-TerraformCatalog.ps1" -ForegroundColor Yellow
        Write-Host "Then commit the modules/terraform/configs changes in the same PR as the catalog edit." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "Reflected Terraform catalog is in sync ($(@($resourcesArr).Count) entries)." -ForegroundColor Green
    exit 0
}

Write-Host "Wrote $(@($resourcesArr).Count) scaffolds under modules/terraform/configs/." -ForegroundColor Green
exit 0
