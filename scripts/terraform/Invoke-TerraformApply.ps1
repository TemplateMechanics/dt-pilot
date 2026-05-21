<#
.SYNOPSIS
    Apply a previously reviewed Terraform plan. Refuses to run without
    -PlanFile (the dt-pilot envelope) AND the binary plan file the
    envelope names.

.DESCRIPTION
    Five consistency checks before invoking `terraform apply`:
      1. Schema match: envelope is dt-pilot.tfplan/v1.
      2. Environment match: envelope's environment matches -Environment.
      3. Workspace-content hash match: SHA-256 over the current .tf /
         .tfvars / lockfile matches what the envelope recorded.
      4. Freshness: envelope no older than -MaxAgeMinutes (default 30).
      5. Binary plan file at the envelope's planBinary path still exists.

    These are consistency checks, not cryptographic integrity proof
    (the envelope is unsigned JSON). They defend against honest drift
    (post-plan edits, environment swaps, stale reviews, missing binary)
    rather than against an adversarial author who edits the envelope.

.PARAMETER Path
    Directory containing the .tf files. Must match the working dir the
    envelope was produced for.

.PARAMETER Environment
    Required. Must match the envelope.

.PARAMETER PlanFile
    Required. Path to the dt-pilot envelope JSON written by
    Invoke-TerraformPlan.ps1.

.PARAMETER MaxAgeMinutes
    Maximum envelope age in minutes. Default 30.

.PARAMETER TerraformExe
    Override the Terraform executable lookup.

.EXAMPLE
    ./scripts/terraform/Invoke-TerraformApply.ps1 -Path examples/terraform-baseline -Environment dev -PlanFile dryrun/dev.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Environment,
    [Parameter(Mandatory)] [string] $PlanFile,
    [int] $MaxAgeMinutes = 30,
    [string] $TerraformExe
)

. "$PSScriptRoot/_Common.ps1"

$exe     = Resolve-TerraformExe -TerraformExe $TerraformExe
$workDir = Resolve-TerraformWorkingDir -Path $Path

$meta = Read-TfPlanMetadata -PlanFile $PlanFile

if ($meta.environment -ne $Environment) {
    throw "Plan envelope was produced for environment '$($meta.environment)' but -Environment is '$Environment'. Re-run Invoke-TerraformPlan.ps1 for the intended environment."
}

$currentHash = Get-TerraformWorkspaceHash -WorkingDir $workDir
if ($meta.workspaceHash -ne $currentHash) {
    throw "Workspace contents have changed since the plan was produced (workspaceHash mismatch). One or more .tf / .tfvars / lockfile entries was edited. Re-run Invoke-TerraformPlan.ps1."
}

$createdAt   = [datetime]::Parse($meta.createdAtUtc).ToUniversalTime()
$ageMinExact = ([datetime]::UtcNow - $createdAt).TotalMinutes
if ($ageMinExact -gt $MaxAgeMinutes) {
    $ageMinDisplay = [Math]::Round($ageMinExact, 1)
    throw "Plan envelope is $ageMinDisplay minute(s) old; max permitted is $MaxAgeMinutes minute(s). Re-run Invoke-TerraformPlan.ps1."
}
$ageMin = [Math]::Round($ageMinExact, 1)

# Working-directory match: enforce what the docstring promises. If the
# envelope was produced for a different workspace path, the workspaceHash
# check would also catch it -- but a clear up-front check produces a
# better error message and protects against the rare same-content,
# different-path case.
if ($meta.workingDir) {
    $envelopeWorkDir = (Resolve-Path -LiteralPath $meta.workingDir -ErrorAction SilentlyContinue)
    if ($envelopeWorkDir -and ($envelopeWorkDir.ProviderPath -ne $workDir)) {
        throw "Plan envelope was produced for workingDir '$($envelopeWorkDir.ProviderPath)' but -Path resolves to '$workDir'. Re-run Invoke-TerraformPlan.ps1 from the intended workspace, or run apply against the right -Path."
    }
}

# Binary plan file must still exist at the (workdir-relative) path the
# envelope names. Without it, `terraform apply <planfile>` has nothing
# to apply.
$planBin = $meta.planBinary
if (-not [System.IO.Path]::IsPathRooted($planBin)) {
    $planBin = Join-Path $workDir $planBin
}
if (-not (Test-Path -LiteralPath $planBin -PathType Leaf)) {
    throw "Binary plan file recorded by the envelope no longer exists: $planBin. The plan and envelope must travel together; re-run Invoke-TerraformPlan.ps1."
}

# Build the provider-specific env dict (passed to the child process
# via -ExtraEnv; the parent shell's $env: stays untouched).
$providerEnv = Get-TerraformProviderEnv

Write-Host "Plan envelope verified:"
Write-Host "  environment:      $($meta.environment)"
Write-Host "  age:              $ageMin minute(s)"
Write-Host "  workspaceHash:    $($meta.workspaceHash.Substring(0, [Math]::Min(16, $meta.workspaceHash.Length)))..."
Write-Host "  summary:          wouldAdd=$($meta.summary.wouldAdd), wouldChange=$($meta.summary.wouldChange), wouldDestroy=$($meta.summary.wouldDestroy)"
Write-Host "  binary plan:      $planBin"
Write-Host ""
Write-Host "Applying $workDir -> environment '$Environment'..." -ForegroundColor Cyan

# terraform apply takes the binary plan path as a positional argument.
# The envelope stores the workdir-relative path, which Terraform
# resolves from $workDir.
$planArg = $meta.planBinary
$result = Invoke-TerraformCommand -TerraformExe $exe -Arguments @('apply','-input=false', $planArg) -WorkingDirectory $workDir -CaptureOutput -ExtraEnv $providerEnv
if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }
if ($result.ExitCode -ne 0) {
    Write-Host "Apply FAILED (exit $($result.ExitCode))" -ForegroundColor Red
    exit $result.ExitCode
}
Write-Host "Apply completed." -ForegroundColor Green
exit 0
