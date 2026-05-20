# scripts/_Common.ps1
# Shared helpers for the Monaco wrapper scripts.
# Dot-source this file from each wrapper:  . "$PSScriptRoot/_Common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-MonacoExe {
    [CmdletBinding()]
    param(
        [string] $MonacoExe
    )

    if ($MonacoExe) {
        if (-not (Test-Path -LiteralPath $MonacoExe -PathType Leaf)) {
            throw "Monaco executable not found at the explicit -MonacoExe path: $MonacoExe"
        }
        return (Resolve-Path -LiteralPath $MonacoExe).ProviderPath
    }

    $cmd = Get-Command -Name monaco -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $envOverride = $env:MONACO_EXE
    if ($envOverride -and (Test-Path -LiteralPath $envOverride -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $envOverride).ProviderPath
    }

    throw "Monaco CLI not found. Install from https://github.com/Dynatrace/dynatrace-configuration-as-code/releases and ensure 'monaco' is on PATH, or pass -MonacoExe."
}

function Resolve-ManifestPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath

    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $manifest = Join-Path $resolved 'manifest.yaml'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "No manifest.yaml found in directory: $resolved"
        }
        return $manifest
    }

    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        return $resolved
    }

    throw "Path does not exist: $Path"
}

function Invoke-MonacoCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $MonacoExe,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $WorkingDirectory,
        [switch] $CaptureOutput
    )

    Write-Verbose ("monaco {0}" -f ($Arguments -join ' '))

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $MonacoExe
    foreach ($a in $Arguments) { $null = $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = [bool]$CaptureOutput
    $psi.RedirectStandardError = [bool]$CaptureOutput
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($CaptureOutput) {
        # Read both streams asynchronously to avoid the classic deadlock
        # where Monaco fills the unread stderr buffer while we block on
        # StandardOutput.ReadToEnd().
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    } else {
        $proc.WaitForExit()
        $stdout = $null
        $stderr = $null
    }

    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Write-DryRunMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutPath,
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $MonacoExe,
        [Parameter(Mandatory)] [int]    $ExitCode,
        [Parameter(Mandatory)] [string] $RawOutput
    )

    $manifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
    $createdAt    = (Get-Date).ToUniversalTime().ToString('o')

    # Best-effort summary: count Monaco's "would create / update / delete"
    # lines. Monaco's log format is subject to change across versions — we
    # expose the raw output too so reviewers and Invoke-MonacoDeploy can do
    # their own parsing.
    # Use [regex]::Matches directly: under StrictMode, dereferencing .Matches
    # on a null Select-String result throws, and array coercion with @(...)
    # adds ceremony without clarity.
    $created = ([regex]::Matches($RawOutput, 'would create', 'IgnoreCase')).Count
    $updated = ([regex]::Matches($RawOutput, 'would update', 'IgnoreCase')).Count
    $deleted = ([regex]::Matches($RawOutput, 'would delete', 'IgnoreCase')).Count

    $meta = [ordered]@{
        schema       = 'dt-pilot.dryrun/v1'
        createdAtUtc = $createdAt
        environment  = $Environment
        manifestPath = $ManifestPath
        manifestSha256 = $manifestHash
        monacoExe    = $MonacoExe
        exitCode     = $ExitCode
        summary      = [ordered]@{
            wouldCreate = $created
            wouldUpdate = $updated
            wouldDelete = $deleted
        }
        rawOutput    = $RawOutput
    }

    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutPath -Encoding utf8
}

function Read-DryRunMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DryRunFile
    )

    if (-not (Test-Path -LiteralPath $DryRunFile -PathType Leaf)) {
        throw "Dry-run file does not exist: $DryRunFile"
    }

    try {
        $obj = Get-Content -LiteralPath $DryRunFile -Raw | ConvertFrom-Json
    } catch {
        throw "Dry-run file is not valid JSON: $DryRunFile ($_)"
    }

    if (-not $obj.schema -or $obj.schema -ne 'dt-pilot.dryrun/v1') {
        throw "Dry-run file is not a dt-pilot dry-run artifact (missing or wrong 'schema' field): $DryRunFile"
    }
    if ($obj.exitCode -ne 0) {
        throw "Dry-run recorded a non-zero exit code ($($obj.exitCode)); refusing to deploy from a failed dry-run: $DryRunFile"
    }

    $obj
}
