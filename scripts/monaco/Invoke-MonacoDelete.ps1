<#
.SYNOPSIS
    Delete Monaco-managed configurations from a Dynatrace environment using
    a curated deletefile. Refuses to run without an explicit -Confirm.

.DESCRIPTION
    Wraps 'monaco delete'. Delete is irreversible at the Dynatrace platform
    layer for many configuration types. This wrapper:
        - requires -DeleteFile to point at an existing file
        - requires -Confirm:$true (mandatory parameter, must be explicit)
        - logs the deletefile contents to stdout before invoking Monaco so
          the operator can confirm what is about to be removed

    Generate a deletefile via Invoke-MonacoGenerate.ps1 -Type deletefile,
    review and prune it, then commit the curated file before running this
    wrapper.

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).

.PARAMETER Environment
    Restrict deletion to a single environment. Omit to apply the deletefile
    to every environment in the manifest (rare; usually you want a single
    environment).

.PARAMETER Group
    Restrict deletion to a single environment group.

.PARAMETER DeleteFile
    Required. Path to the curated deletefile.

.PARAMETER Confirm
    Required. Must be explicitly $true. The mandatory flag is the second
    safety gate after the deletefile-must-exist check; the dt-pilot agent
    contract additionally requires explicit destroy authorization in the
    conversation before invoking this script.

.PARAMETER MonacoExe
    Override the Monaco executable lookup.

.EXAMPLE
    ./scripts/monaco/Invoke-MonacoDelete.ps1 -Path . -Environment dev `
        -DeleteFile deletefile.yaml -Confirm
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $Environment,
    [string] $Group,
    [Parameter(Mandatory)] [string] $DeleteFile,
    [Parameter(Mandatory)] [switch] $Confirm,
    [string] $MonacoExe
)

. "$PSScriptRoot/_Common.ps1"

if (-not $Confirm) {
    throw "Refusing to delete: -Confirm was not specified. Pass -Confirm to acknowledge that delete is irreversible."
}

if (-not (Test-Path -LiteralPath $DeleteFile -PathType Leaf)) {
    throw "Deletefile does not exist: $DeleteFile"
}

$exe = Resolve-MonacoExe -MonacoExe $MonacoExe
$manifest = Resolve-ManifestPath -Path $Path
$workDir = Split-Path -Parent $manifest

Write-Host "About to delete the configurations listed in: $DeleteFile" -ForegroundColor Yellow
Write-Host "----- deletefile -----"
Get-Content -LiteralPath $DeleteFile | ForEach-Object { Write-Host "  $_" }
Write-Host "----------------------"
Write-Host "Manifest:    $manifest"
if ($Environment) { Write-Host "Environment: $Environment" }
if ($Group)       { Write-Host "Group:       $Group" }
Write-Host ""

$args = @('delete', '--manifest', (Split-Path -Leaf $manifest), '--file', (Resolve-Path -LiteralPath $DeleteFile).ProviderPath)
if ($Environment) { $args += @('--environment', $Environment) }
if ($Group)       { $args += @('--group', $Group) }

$result = Invoke-MonacoCommand -MonacoExe $exe -Arguments $args -WorkingDirectory $workDir -CaptureOutput

if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }

if ($result.ExitCode -ne 0) {
    Write-Host "Delete FAILED (exit code $($result.ExitCode))" -ForegroundColor Red
    exit $result.ExitCode
}

Write-Host "Delete completed." -ForegroundColor Green
exit 0
