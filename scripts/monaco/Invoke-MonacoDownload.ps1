<#
.SYNOPSIS
    Download Monaco-shaped configuration from a live Dynatrace environment
    into a local directory for reconciliation against the manifest.

.DESCRIPTION
    Wraps 'monaco download'. Two modes:

      1. Manifest mode (preferred): the environment is named in the
         manifest, auth is resolved from the manifest's env-var-backed
         token/oAuth blocks. Pass -Path and -Environment.

      2. URL mode (ad-hoc): point at an arbitrary environment with -Url
         and -TokenEnv (the name of an env var holding the token).

    Downloads are written under -Output (default 'downloaded/') and are
    gitignored by default. Treat the download as input for review; do not
    overwrite committed configs wholesale.

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).
    Required for manifest mode.

.PARAMETER Environment
    Environment name from the manifest. Required for manifest mode.

.PARAMETER Url
    Environment URL. Required for URL mode.

.PARAMETER TokenEnv
    Name of an environment variable holding the classic API token. Required
    for URL mode. The token value itself is never printed by this wrapper.

.PARAMETER Output
    Output directory for the downloaded project. Default 'downloaded/'.

.PARAMETER MonacoExe
    Override the Monaco executable lookup.

.EXAMPLE
    ./scripts/monaco/Invoke-MonacoDownload.ps1 -Path . -Environment dev -Output downloaded/dev

.EXAMPLE
    ./scripts/monaco/Invoke-MonacoDownload.ps1 -Url https://abc.live.dynatrace.com `
        -TokenEnv DT_DEV_TOKEN -Output downloaded/
#>

[CmdletBinding(DefaultParameterSetName = 'Manifest')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Manifest')] [string] $Path,
    [Parameter(Mandatory, ParameterSetName = 'Manifest')] [string] $Environment,

    [Parameter(Mandatory, ParameterSetName = 'Url')] [string] $Url,
    [Parameter(Mandatory, ParameterSetName = 'Url')] [string] $TokenEnv,

    [string] $Output = 'downloaded',
    [string] $MonacoExe
)

. "$PSScriptRoot/_Common.ps1"

$exe = Resolve-MonacoExe -MonacoExe $MonacoExe

if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
    $manifest = Resolve-ManifestPath -Path $Path
    $workDir = Split-Path -Parent $manifest
    $args = @('download', '--manifest', (Split-Path -Leaf $manifest), '--environment', $Environment, '--output-folder', $Output)
    Write-Host "Downloading from environment '$Environment' (manifest: $manifest)"
} else {
    $tokenValue = [System.Environment]::GetEnvironmentVariable($TokenEnv)
    if (-not $tokenValue) {
        throw "Environment variable '$TokenEnv' is not set; cannot resolve the API token for URL-mode download."
    }
    $workDir = (Get-Location).Path
    # Monaco's --token argument accepts the env-var NAME (not the value);
    # the validation above only confirms that the named variable resolves.
    $args = @('download', '--url', $Url, '--token', $TokenEnv, '--output-folder', $Output)
    Write-Host "Downloading from $Url (token from `$env:$TokenEnv)"
}

$result = Invoke-MonacoCommand -MonacoExe $exe -Arguments $args -WorkingDirectory $workDir -CaptureOutput

if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }

if ($result.ExitCode -ne 0) {
    Write-Host "Download FAILED (exit code $($result.ExitCode))" -ForegroundColor Red
    exit $result.ExitCode
}

Write-Host "Download completed to: $Output" -ForegroundColor Green
exit 0
