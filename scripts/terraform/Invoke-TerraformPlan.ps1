<#
.SYNOPSIS
    Run `terraform plan` against a single environment and persist the
    result as a reviewable dt-pilot.tfplan/v1 plan envelope alongside
    the binary plan file.

.DESCRIPTION
    Produces TWO artifacts that travel together:
      1. The binary plan file (-Out, default 'tfplan') that
         `terraform apply <planfile>` consumes directly.
      2. The dt-pilot envelope JSON (default 'dryrun/<env>.json') that
         records: environment, working directory, workspace hash,
         Terraform version + binary path, exit code, add/change/destroy
         summary, the binary plan path, and a `terraform show -json`
         summary string.

    Invoke-TerraformApply.ps1 requires the envelope via -PlanFile (and
    re-verifies the binary plan exists at the path the envelope names).
    Hand-edited or stale artifacts are rejected.

.PARAMETER Path
    Directory containing the .tf files.

.PARAMETER Environment
    Required. The environment name (also used to construct the default
    envelope path: dryrun/<env>.json).

.PARAMETER Out
    Path to the binary plan file Terraform writes. Default 'tfplan'
    inside the working directory.

.PARAMETER EnvelopeOut
    Path to the JSON envelope. Default 'dryrun/<env>.json' relative to
    the current working directory.

.PARAMETER VarFile
    Optional -var-file argument (e.g. 'envs/dev.tfvars'). Path is
    relative to the Terraform working directory.

.PARAMETER TerraformExe
    Override the Terraform executable lookup.

.EXAMPLE
    ./scripts/terraform/Invoke-TerraformPlan.ps1 -Path examples/terraform-baseline -Environment dev -VarFile envs/dev.tfvars

.EXAMPLE
    ./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment prod -VarFile envs/prod.tfvars -Out prod.tfplan
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Environment,
    [string] $Out,
    [string] $EnvelopeOut,
    [string] $VarFile,
    [string] $TerraformExe
)

. "$PSScriptRoot/_Common.ps1"

$exe     = Resolve-TerraformExe -TerraformExe $TerraformExe
$workDir = Resolve-TerraformWorkingDir -Path $Path

if (-not $Out)         { $Out         = 'tfplan' }
if (-not $EnvelopeOut) { $EnvelopeOut = Join-Path 'dryrun' ("{0}.json" -f $Environment) }

# Translate dt-pilot canonical env vars to provider-specific names. The
# resulting hashtable is passed to Invoke-TerraformCommand -ExtraEnv so
# the child terraform process sees the provider-specific names but the
# parent PowerShell session's $env: is NOT mutated.
$providerEnv = Get-TerraformProviderEnv

$args = @('plan','-input=false','-out',$Out)
if ($VarFile) {
    $args += @('-var-file', $VarFile)
}

Write-Host "Plan: $workDir -> environment '$Environment' -> $Out"
$planResult = Invoke-TerraformCommand -TerraformExe $exe -Arguments $args -WorkingDirectory $workDir -CaptureOutput -ExtraEnv $providerEnv
if ($planResult.StdOut) { Write-Host $planResult.StdOut.TrimEnd() }
if ($planResult.StdErr) { Write-Host $planResult.StdErr.TrimEnd() }

# Even on failure, we still want to write the envelope so the reviewer
# can inspect why -- the deploy wrapper enforces exitCode == 0.
$showJson = ''
if ($planResult.ExitCode -eq 0) {
    $show = Invoke-TerraformCommand -TerraformExe $exe -Arguments @('show','-json',$Out) -WorkingDirectory $workDir -CaptureOutput
    if ($show.ExitCode -eq 0 -and $show.StdOut) {
        $showJson = $show.StdOut
    }
}

$envelopePath = if ([System.IO.Path]::IsPathRooted($EnvelopeOut)) { $EnvelopeOut } else { (Join-Path (Get-Location).Path $EnvelopeOut) }
# Store planBinary as the workdir-relative path so the envelope is
# portable across checkouts / agents / docker mounts. The apply wrapper
# re-roots against the workdir it was invoked with.
$planBinRelative = if ([System.IO.Path]::IsPathRooted($Out)) {
    [System.IO.Path]::GetRelativePath($workDir, $Out).Replace('\','/')
} else {
    $Out.Replace('\','/')
}

Write-TfPlanMetadata `
    -OutPath          $envelopePath `
    -WorkingDir       $workDir `
    -Environment      $Environment `
    -TerraformExe     $exe `
    -ExitCode         $planResult.ExitCode `
    -PlanBinaryPath   $planBinRelative `
    -PlanJsonSummary  $showJson

Write-Host "Plan envelope written: $envelopePath"

if ($planResult.ExitCode -ne 0) {
    Write-Host "Plan FAILED (exit $($planResult.ExitCode)). See raw output and the envelope's planJsonSummary." -ForegroundColor Red
    exit $planResult.ExitCode
}

$meta = Get-Content -LiteralPath $envelopePath -Raw | ConvertFrom-Json
Write-Host ("Summary: wouldAdd={0}, wouldChange={1}, wouldDestroy={2}" -f `
    $meta.summary.wouldAdd, $meta.summary.wouldChange, $meta.summary.wouldDestroy) -ForegroundColor Green
exit 0
