# scripts/terraform/_Common.ps1
# Shared helpers for the Terraform wrapper scripts. Dot-source this from
# each wrapper:  . "$PSScriptRoot/_Common.ps1"
#
# Mirrors scripts/monaco/_Common.ps1 in spirit; the auth-env-translation,
# workspace-hash, and dt-pilot.tfplan/v1 helpers are Terraform-specific.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-TerraformExe {
    [CmdletBinding()]
    param(
        [string] $TerraformExe
    )
    # Precedence: explicit -TerraformExe > TERRAFORM_EXE / TF_EXE env > PATH.
    # The env-var pin beats PATH so a CI pin deterministically overrides
    # a stray binary on the runner.
    if ($TerraformExe) {
        if (-not (Test-Path -LiteralPath $TerraformExe -PathType Leaf)) {
            throw "Terraform executable not found at the explicit -TerraformExe path: $TerraformExe"
        }
        return (Resolve-Path -LiteralPath $TerraformExe).ProviderPath
    }
    foreach ($envName in @('TERRAFORM_EXE','TF_EXE')) {
        $envVal = [System.Environment]::GetEnvironmentVariable($envName)
        if ($envVal) {
            if (-not (Test-Path -LiteralPath $envVal -PathType Leaf)) {
                throw "Environment variable $envName points to a non-existent file: $envVal"
            }
            return (Resolve-Path -LiteralPath $envVal).ProviderPath
        }
    }
    $cmd = Get-Command -Name terraform -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Path }
    throw "Terraform CLI not found. Install from https://developer.hashicorp.com/terraform/downloads and ensure 'terraform' is on PATH, or set TERRAFORM_EXE / TF_EXE, or pass -TerraformExe."
}

function Resolve-TerraformWorkingDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Terraform working directory must be a directory: $Path"
    }
    # A Terraform workspace needs at least one .tf file. Catch the
    # 'pointed at the wrong dir' case early.
    $tfFiles = Get-ChildItem -LiteralPath $resolved -Filter '*.tf' -File -ErrorAction SilentlyContinue
    if (-not $tfFiles) {
        throw "No .tf files found in $resolved -- is this the right Terraform working directory?"
    }
    return $resolved
}

function Set-TerraformProviderEnv {
    [CmdletBinding()]
    param()
    # Translate dt-pilot's canonical auth env vars to the names the
    # dynatrace-oss/dynatrace provider expects. The user sets the
    # canonical names once (DT_ENVIRONMENT / DT_PLATFORM_TOKEN /
    # OAUTH_CLIENT_*) and the wrapper exports the provider-specific
    # names into the child terraform process here.
    #
    # This is process-local: we mutate $env: which only persists for
    # this PowerShell process and its children. No state leaks back to
    # the shell that invoked the wrapper.
    if ($env:DT_ENVIRONMENT)      { $env:DT_ENV_URL      = $env:DT_ENVIRONMENT }
    if ($env:DT_PLATFORM_TOKEN)   { $env:DT_API_TOKEN    = $env:DT_PLATFORM_TOKEN }
    if ($env:OAUTH_CLIENT_ID)     { $env:DT_CLIENT_ID    = $env:OAUTH_CLIENT_ID }
    if ($env:OAUTH_CLIENT_SECRET) { $env:DT_CLIENT_SECRET= $env:OAUTH_CLIENT_SECRET }
    # DT_ACCOUNT_ID has no canonical equivalent today; pass through if set.
    # (Reserved for account-management workflows.)
}

function Invoke-TerraformCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TerraformExe,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [switch] $CaptureOutput
    )
    Write-Verbose ("terraform {0}" -f ($Arguments -join ' '))
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $TerraformExe
    foreach ($a in $Arguments) { $null = $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = [bool]$CaptureOutput
    $psi.RedirectStandardError  = [bool]$CaptureOutput
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($CaptureOutput) {
        # Async reads to avoid the stream-buffer deadlock that bit Monaco
        # in PR #4 review.
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
    [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Get-TerraformWorkspaceHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkingDir)
    # Stable SHA-256 over every Terraform source file the apply step
    # would read: *.tf, *.tfvars, terraform.lock.hcl. Sorted by
    # workspace-relative path so the hash is reproducible across clones.
    # State files (terraform.tfstate*) are deliberately excluded -- state
    # is server-side / runtime, not source; including it would invalidate
    # every plan as soon as state evolves.
    $files = New-Object System.Collections.Generic.List[string]
    $patterns = @('*.tf','*.tfvars','*.tfvars.json','terraform.lock.hcl')
    foreach ($pat in $patterns) {
        $matches = Get-ChildItem -LiteralPath $WorkingDir -Filter $pat -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $matches) { $files.Add($f.FullName) }
    }
    # Skip anything inside .terraform/ -- it's provider-cache, not source.
    $files = @($files | Where-Object { $_ -notmatch '[\\/]\.terraform[\\/]' })
    if ($files.Count -eq 0) {
        # Should not happen because Resolve-TerraformWorkingDir already
        # checked for *.tf; defensive guard for direct callers.
        return ''
    }
    $sb = New-Object System.Text.StringBuilder
    $root = (Resolve-Path -LiteralPath $WorkingDir).ProviderPath
    foreach ($f in ($files | Sort-Object)) {
        $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        $rel = [System.IO.Path]::GetRelativePath($root, $f).Replace('\','/')
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

function Write-TfPlanMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutPath,
        [Parameter(Mandatory)] [string] $WorkingDir,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $TerraformExe,
        [Parameter(Mandatory)] [int]    $ExitCode,
        [Parameter(Mandatory)] [string] $PlanBinaryPath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PlanJsonSummary
    )
    $createdAt    = (Get-Date).ToUniversalTime().ToString('o')
    $tfVersion    = ''
    try {
        $verResult = Invoke-TerraformCommand -TerraformExe $TerraformExe -Arguments @('version','-json') -WorkingDirectory $WorkingDir -CaptureOutput
        if ($verResult.ExitCode -eq 0 -and $verResult.StdOut) {
            $tfVersion = ([string](($verResult.StdOut | ConvertFrom-Json).terraform_version))
        }
    } catch {
        $tfVersion = ''
    }
    $hash = Get-TerraformWorkspaceHash -WorkingDir $WorkingDir

    # Best-effort summary from `terraform show -json tfplan` output.
    # Same defensive [regex]::Matches pattern Monaco uses.
    $wouldAdd     = 0
    $wouldChange  = 0
    $wouldDestroy = 0
    try {
        if ($PlanJsonSummary) {
            $parsed = $PlanJsonSummary | ConvertFrom-Json
            if ($parsed.PSObject.Properties['resource_changes']) {
                foreach ($rc in @($parsed.resource_changes)) {
                    $actions = @($rc.change.actions)
                    if ($actions -contains 'create') { $wouldAdd     += 1 }
                    if ($actions -contains 'update') { $wouldChange  += 1 }
                    if ($actions -contains 'delete') { $wouldDestroy += 1 }
                }
            }
        }
    } catch {
        # Leave counts at zero; reviewer reads the raw envelope.
    }

    $meta = [ordered]@{
        schema           = 'dt-pilot.tfplan/v1'
        createdAtUtc     = $createdAt
        environment      = $Environment
        workingDir       = $WorkingDir
        workspaceHash    = $hash
        terraformVersion = $tfVersion
        terraformExe     = $TerraformExe
        exitCode         = $ExitCode
        summary          = [ordered]@{
            wouldAdd     = $wouldAdd
            wouldChange  = $wouldChange
            wouldDestroy = $wouldDestroy
        }
        planBinary       = $PlanBinaryPath
        planJsonSummary  = $PlanJsonSummary
    }

    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetFullPath($dir)) -Force
    }
    $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutPath -Encoding utf8
}

function Read-TfPlanMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $PlanFile)
    if (-not (Test-Path -LiteralPath $PlanFile -PathType Leaf)) {
        throw "Plan envelope does not exist: $PlanFile"
    }
    try {
        $obj = Get-Content -LiteralPath $PlanFile -Raw | ConvertFrom-Json
    } catch {
        throw "Plan envelope is not valid JSON: $PlanFile ($_)"
    }
    if (-not $obj.PSObject.Properties['schema'] -or $obj.schema -ne 'dt-pilot.tfplan/v1') {
        throw "Plan envelope is not a dt-pilot tfplan/v1 artifact (missing or wrong 'schema'): $PlanFile"
    }
    if ($obj.exitCode -ne 0) {
        throw "Plan envelope recorded a non-zero exit code ($($obj.exitCode)); refusing to apply from a failed plan: $PlanFile"
    }
    return $obj
}
