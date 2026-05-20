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

    # Precedence: explicit -MonacoExe > MONACO_EXE env var > 'monaco'
    # discovered on PATH. The env var beats PATH so a CI pin in
    # MONACO_EXE deterministically overrides a stray binary on the
    # runner's PATH.
    if ($MonacoExe) {
        if (-not (Test-Path -LiteralPath $MonacoExe -PathType Leaf)) {
            throw "Monaco executable not found at the explicit -MonacoExe path: $MonacoExe"
        }
        return (Resolve-Path -LiteralPath $MonacoExe).ProviderPath
    }

    $envOverride = $env:MONACO_EXE
    if ($envOverride) {
        if (-not (Test-Path -LiteralPath $envOverride -PathType Leaf)) {
            throw "MONACO_EXE points to a non-existent file: $envOverride"
        }
        return (Resolve-Path -LiteralPath $envOverride).ProviderPath
    }

    # Restrict the PATH lookup to actual executables — an alias or function
    # named 'monaco' would expose a .Source that is not a runnable file
    # path, and the later Process.Start would fail with a confusing error.
    $cmd = Get-Command -Name monaco -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Path }

    throw "Monaco CLI not found. Install from https://github.com/Dynatrace/dynatrace-configuration-as-code/releases and ensure 'monaco' is on PATH, or set MONACO_EXE, or pass -MonacoExe."
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

function Get-ManifestProjectDirs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath
    )

    $manifestDir = Split-Path -Parent $ManifestPath
    $lines = Get-Content -LiteralPath $ManifestPath

    $dirs = New-Object System.Collections.Generic.List[string]
    $inProjects = $false
    $currentName = $null
    $currentPath = $null

    $emit = {
        if (-not $currentName) { return }
        $candidate = if ($currentPath) {
            # `path:` is relative to the manifest directory.
            Join-Path $manifestDir $currentPath
        } else {
            $direct = Join-Path $manifestDir $currentName
            if (Test-Path -LiteralPath $direct -PathType Container) {
                $direct
            } else {
                Join-Path (Join-Path $manifestDir 'projects') $currentName
            }
        }
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $dirs.Add((Resolve-Path -LiteralPath $candidate).ProviderPath)
        }
    }

    foreach ($line in $lines) {
        if ($line -match '^[A-Za-z_]+\s*:') {
            & $emit; $currentName = $null; $currentPath = $null
            $inProjects = ($line -match '^\s*projects\s*:')
            continue
        }
        if (-not $inProjects) { continue }
        if ($line -match '^\s*-\s*name\s*:\s*(\S+)') {
            & $emit
            $currentName = $Matches[1].Trim('"').Trim("'")
            $currentPath = $null
            continue
        }
        if ($line -match '^\s*path\s*:\s*(\S+)') {
            $currentPath = $Matches[1].Trim('"').Trim("'")
        }
    }
    & $emit

    return ,$dirs.ToArray()
}

function Get-WorkspaceHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath
    )

    # Stable hash over the manifest plus every file under every project
    # directory it references. This is the bag of bytes Monaco will read
    # at deploy time; binding the dry-run artifact to this hash means a
    # post-dry-run edit to ANY config.yaml or template.json invalidates
    # the deploy — not just an edit to manifest.yaml.
    $files = New-Object System.Collections.Generic.List[string]
    $files.Add((Resolve-Path -LiteralPath $ManifestPath).ProviderPath)

    foreach ($dir in (Get-ManifestProjectDirs -ManifestPath $ManifestPath)) {
        foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File | Sort-Object FullName)) {
            $files.Add($f.FullName)
        }
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($f in ($files | Sort-Object)) {
        $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        # Use the manifest-relative path so the hash is stable across
        # clones at different absolute locations.
        $manifestRoot = Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath).ProviderPath
        $rel = $f.Substring($manifestRoot.Length).TrimStart('\','/')
        [void]$sb.Append($rel).Append('|').Append($h).Append("`n")
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes) -replace '-','').ToLowerInvariant()
    } finally {
        $sha.Dispose()
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

    $manifestHash  = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
    $workspaceHash = Get-WorkspaceHash -ManifestPath $ManifestPath
    $createdAt     = (Get-Date).ToUniversalTime().ToString('o')

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
        schema         = 'dt-pilot.dryrun/v1'
        createdAtUtc   = $createdAt
        environment    = $Environment
        manifestPath   = $ManifestPath
        manifestSha256 = $manifestHash
        workspaceHash  = $workspaceHash
        monacoExe      = $MonacoExe
        exitCode       = $ExitCode
        summary        = [ordered]@{
            wouldCreate = $created
            wouldUpdate = $updated
            wouldDelete = $deleted
        }
        rawOutput      = $RawOutput
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
