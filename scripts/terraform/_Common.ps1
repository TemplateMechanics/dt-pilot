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

function Get-TerraformProviderEnv {
    [CmdletBinding()]
    param()
    # Build the canonical -> provider-specific env-var translation as a
    # hashtable. Caller passes the result to Invoke-TerraformCommand
    # -ExtraEnv so the child terraform process sees the provider names,
    # but the parent PowerShell session's $env: is NOT mutated. (The
    # earlier version mutated $env: directly, which leaked the
    # provider-name vars back into the interactive shell after the
    # wrapper returned -- a real source of cross-invocation contamination.)
    $extra = @{}
    if ($env:DT_ENVIRONMENT)      { $extra['DT_ENV_URL']       = $env:DT_ENVIRONMENT }
    if ($env:DT_PLATFORM_TOKEN)   { $extra['DT_API_TOKEN']     = $env:DT_PLATFORM_TOKEN }
    if ($env:OAUTH_CLIENT_ID)     { $extra['DT_CLIENT_ID']     = $env:OAUTH_CLIENT_ID }
    if ($env:OAUTH_CLIENT_SECRET) { $extra['DT_CLIENT_SECRET'] = $env:OAUTH_CLIENT_SECRET }
    # DT_ACCOUNT_ID has no canonical equivalent; pass through if set.
    if ($env:DT_ACCOUNT_ID)       { $extra['DT_ACCOUNT_ID']    = $env:DT_ACCOUNT_ID }
    return $extra
}

function Invoke-TerraformCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TerraformExe,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [switch] $CaptureOutput,
        # Optional name->value hashtable of extra env vars to set in the
        # child terraform process WITHOUT mutating the parent
        # PowerShell session's $env:. Callers pass the output of
        # Get-TerraformProviderEnv here.
        [hashtable] $ExtraEnv
    )
    Write-Verbose ("terraform {0}" -f ($Arguments -join ' '))
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $TerraformExe
    foreach ($a in $Arguments) { $null = $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = [bool]$CaptureOutput
    $psi.RedirectStandardError  = [bool]$CaptureOutput
    if ($ExtraEnv) {
        # psi.Environment is pre-populated from the parent process; add
        # / override the extras into THAT collection so the child sees
        # them, but the parent's $env: is unchanged.
        foreach ($k in $ExtraEnv.Keys) {
            $psi.Environment[$k] = [string]$ExtraEnv[$k]
        }
    }
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
        # Truncated terraform show -json text stored verbatim in the envelope.
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PlanJsonSummary,
        # Pre-computed add/change/destroy counts from the FULL (not the
        # truncated) terraform show -json output. The caller computes
        # these because once the JSON is truncated for storage it's no
        # longer parseable.
        [int] $WouldAdd     = 0,
        [int] $WouldChange  = 0,
        [int] $WouldDestroy = 0
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

    # Use the pre-computed counts (caller already parsed the full JSON
    # before truncating). If the caller didn't supply them, leave at
    # zero; the reviewer reads the raw envelope.
    $wouldAdd     = $WouldAdd
    $wouldChange  = $WouldChange
    $wouldDestroy = $WouldDestroy

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
