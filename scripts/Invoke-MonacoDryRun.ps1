<#
.SYNOPSIS
    Run 'monaco deploy --dry-run' against a single environment and persist
    the result as a reviewable dry-run artifact.

.DESCRIPTION
    Produces a dt-pilot dry-run artifact (JSON; schema 'dt-pilot.dryrun/v1')
    at the path given by -Out. The artifact contains:
        - environment name
        - manifest path + SHA-256
        - Monaco executable path
        - dry-run exit code
        - best-effort would-create / would-update / would-delete counts
        - raw Monaco stdout/stderr

    Invoke-MonacoDeploy.ps1 requires this exact artifact via its -DryRunFile
    parameter. Hand-edited or stale artifacts are rejected.

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).

.PARAMETER Environment
    Required. The environment from the manifest to dry-run against.

.PARAMETER Out
    Output path for the dry-run artifact. Defaults to 'dryrun/<env>.json'
    relative to the current working directory.

.PARAMETER MonacoExe
    Override the Monaco executable lookup.

.EXAMPLE
    ./scripts/Invoke-MonacoDryRun.ps1 -Path examples/baseline-stack -Environment dev

.EXAMPLE
    ./scripts/Invoke-MonacoDryRun.ps1 -Path . -Environment prod -Out dryrun/prod.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Environment,
    [string] $Out,
    [string] $MonacoExe
)

. "$PSScriptRoot/_Common.ps1"

$exe = Resolve-MonacoExe -MonacoExe $MonacoExe
$manifest = Resolve-ManifestPath -Path $Path
$workDir = Split-Path -Parent $manifest

if (-not $Out) {
    $Out = Join-Path 'dryrun' ("{0}.json" -f $Environment)
}

$args = @('deploy', '--dry-run', '--environment', $Environment, (Split-Path -Leaf $manifest))

Write-Host "Dry-run: $manifest -> environment '$Environment'"
$result = Invoke-MonacoCommand -MonacoExe $exe -Arguments $args -WorkingDirectory $workDir -CaptureOutput

$raw = (($result.StdOut ?? '') + "`n" + ($result.StdErr ?? '')).TrimEnd()

# Always persist the artifact — including for failed dry-runs — so the
# reviewer can inspect why it failed. The metadata helper records the
# exit code; the deploy wrapper refuses to use a non-zero artifact.
Write-DryRunMetadata `
    -OutPath      $Out `
    -ManifestPath $manifest `
    -Environment  $Environment `
    -MonacoExe    $exe `
    -ExitCode     $result.ExitCode `
    -RawOutput    $raw

Write-Host "Dry-run artifact written: $Out"

if ($result.ExitCode -ne 0) {
    Write-Host "Dry-run FAILED (exit code $($result.ExitCode)). See raw output in the artifact." -ForegroundColor Red
    Write-Host $raw
    exit $result.ExitCode
}

# Surface the summary inline so the agent doesn't need to read the artifact
# back just to see the headline numbers.
$meta = Get-Content -LiteralPath $Out -Raw | ConvertFrom-Json
Write-Host ("Summary: wouldCreate={0}, wouldUpdate={1}, wouldDelete={2}" -f `
    $meta.summary.wouldCreate, $meta.summary.wouldUpdate, $meta.summary.wouldDelete) -ForegroundColor Green

exit 0
