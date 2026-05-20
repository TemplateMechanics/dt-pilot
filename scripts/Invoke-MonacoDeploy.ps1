<#
.SYNOPSIS
    Deploy a previously reviewed dry-run to a Dynatrace environment.

.DESCRIPTION
    Refuses to run without a -DryRunFile produced by Invoke-MonacoDryRun.ps1.
    Verifies that the dry-run:
        - has the dt-pilot dryrun/v1 schema
        - was produced for the same manifest (SHA-256 match)
        - was produced for the same environment
        - succeeded (exit code 0)
        - is no older than -MaxAgeMinutes (default 30) so a stale review
          can't be used to mask drift introduced after the dry-run

    Only after every check passes does it invoke 'monaco deploy'.

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).

.PARAMETER Environment
    Required. The environment from the manifest to deploy to. Must match
    the dry-run artifact.

.PARAMETER DryRunFile
    Required. Path to a dt-pilot dry-run artifact produced by
    Invoke-MonacoDryRun.ps1.

.PARAMETER MaxAgeMinutes
    Maximum age of the dry-run artifact in minutes. Default 30. Set higher
    only with deliberate authorization — the freshness check exists to
    catch drift between dry-run and deploy.

.PARAMETER MonacoExe
    Override the Monaco executable lookup.

.EXAMPLE
    ./scripts/Invoke-MonacoDeploy.ps1 -Path . -Environment dev -DryRunFile dryrun/dev.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Environment,
    [Parameter(Mandatory)] [string] $DryRunFile,
    [int] $MaxAgeMinutes = 30,
    [string] $MonacoExe
)

. "$PSScriptRoot/_Common.ps1"

$exe = Resolve-MonacoExe -MonacoExe $MonacoExe
$manifest = Resolve-ManifestPath -Path $Path
$workDir = Split-Path -Parent $manifest

$meta = Read-DryRunMetadata -DryRunFile $DryRunFile

# Environment check.
if ($meta.environment -ne $Environment) {
    throw "Dry-run artifact was produced for environment '$($meta.environment)' but -Environment is '$Environment'. Re-run the dry-run for the intended environment."
}

# Manifest identity check (SHA-256 over the manifest file contents).
$currentSha = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
if ($meta.manifestSha256 -ne $currentSha) {
    throw "Manifest has changed since the dry-run was produced (SHA-256 mismatch). Re-run Invoke-MonacoDryRun.ps1 against the current manifest before deploying."
}

# Full workspace identity check: hashes the manifest plus every file under
# every project directory it references. Catches the case where the
# manifest itself is unchanged but a config.yaml or template.json was
# edited after the dry-run was produced — i.e. content that Monaco would
# read at deploy time but that was never reviewed.
$currentWorkspace = Get-WorkspaceHash -ManifestPath $manifest
if (-not $meta.PSObject.Properties.Match('workspaceHash')) {
    throw "Dry-run artifact predates the workspaceHash field. Re-run Invoke-MonacoDryRun.ps1 to regenerate it: $DryRunFile"
}
if ($meta.workspaceHash -ne $currentWorkspace) {
    throw "Workspace contents have changed since the dry-run was produced (workspaceHash mismatch). One or more project files (config.yaml / template.json) was edited after the dry-run. Re-run Invoke-MonacoDryRun.ps1 to regenerate the reviewed artifact."
}

# Freshness check.
$createdAt = [datetime]::Parse($meta.createdAtUtc).ToUniversalTime()
$ageMin = [int]([datetime]::UtcNow - $createdAt).TotalMinutes
if ($ageMin -gt $MaxAgeMinutes) {
    throw "Dry-run artifact is $ageMin minute(s) old; the maximum permitted age is $MaxAgeMinutes minute(s). Re-run Invoke-MonacoDryRun.ps1 to refresh the review window."
}

Write-Host "Dry-run artifact verified:"
Write-Host "  environment: $($meta.environment)"
Write-Host "  age:         $ageMin minute(s)"
Write-Host "  summary:     wouldCreate=$($meta.summary.wouldCreate), wouldUpdate=$($meta.summary.wouldUpdate), wouldDelete=$($meta.summary.wouldDelete)"
Write-Host ""
Write-Host "Deploying $manifest -> environment '$Environment'..." -ForegroundColor Cyan

$args = @('deploy', '--environment', $Environment, (Split-Path -Leaf $manifest))
$result = Invoke-MonacoCommand -MonacoExe $exe -Arguments $args -WorkingDirectory $workDir -CaptureOutput

if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }

if ($result.ExitCode -ne 0) {
    Write-Host "Deploy FAILED (exit code $($result.ExitCode))" -ForegroundColor Red
    exit $result.ExitCode
}

Write-Host "Deploy completed." -ForegroundColor Green
exit 0
