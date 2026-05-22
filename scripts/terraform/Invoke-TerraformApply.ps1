<#
.SYNOPSIS
    Apply a previously reviewed Terraform plan. Refuses to run without
    -PlanFile (the dt-pilot envelope) AND the binary plan file the
    envelope names.

.DESCRIPTION
    Consistency checks before invoking `terraform apply`, in the order
    they fire (first failure short-circuits with a targeted message):

      1. Schema match: envelope's `schema` is `dt-pilot.tfplan/v1`.
      2. exitCode validation: field is present, is an integer, and is 0
         (rejects malformed envelopes AND failed plans separately).
      3. Environment match: envelope's `environment` matches -Environment.
      4. Workspace-content hash match: SHA-256 over the current .tf /
         .tfvars / .terraform.lock.hcl matches the envelope's `workspaceHash`.
      5. Freshness: envelope is no older than -MaxAgeMinutes (default 30).
      6. workingDir match: envelope's `workingDir` field is present and
         normalizes (case-insensitive on Windows, case-sensitive on
         Linux/macOS) to the resolved -Path; a missing field is a hard
         failure rather than a silent skip.
      7. planBinary shape: field is present, is a string, contains no
         `..` path traversal, and (if rooted) resolves under -Path.
      8. planBinary exists: the binary plan file the envelope names is
         still on disk at the resolved location.

    These are consistency checks, not cryptographic integrity proof
    (the envelope is unsigned JSON). They defend against honest drift
    (post-plan edits, environment swaps, stale reviews, missing binary,
    cross-workspace mistakes, malformed/hand-edited envelopes) rather
    than against an adversarial author who edits the envelope.

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

# Working-directory match: enforce what the docstring promises. The
# workspaceHash check would also catch most cross-workspace cases, but
# a clear up-front path check produces a better error message and
# protects against the rare same-content, different-path case.
#
# Compare normalized string forms, not Resolve-Path output, so an
# envelope produced in a different checkout (where the recorded path
# does not exist on THIS machine) becomes an explicit "wrong workspace"
# failure rather than silently passing. Both sides are normalized
# (trailing separators stripped, backslashes -> forward slashes), and
# the comparison's case-sensitivity matches the filesystem: case-
# insensitive on Windows (where 'C:\Foo' and 'C:\foo' name the same
# directory), case-sensitive on Linux/macOS (where they don't, and
# treating them as equal would weaken the cross-workspace protection).
function Format-PathForCompare {
    param([string] $P)
    if (-not $P) { return '' }
    return $P.TrimEnd('\','/').Replace('\','/')
}
# $IsWindows is a PS 6+ automatic; on PS 5.1 it's undefined but PS 5.1
# only runs on Windows, so fall back to the platform check.
$isWin = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $IsWindows } else { [System.Environment]::OSVersion.Platform -eq 'Win32NT' }
$pathCmp = if ($isWin) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

# Strict mode rejects accessing a missing property, so guard via
# PSObject.Properties before reading $meta.workingDir.
$hasWorkingDir = [bool]($meta.PSObject.Properties['workingDir']) -and $meta.workingDir
if (-not $hasWorkingDir) {
    # Envelope without a workingDir field is malformed (Write-TfPlanMetadata
    # always sets it). Refuse rather than silently skip the gate.
    throw "Plan envelope is missing the 'workingDir' field; refusing to apply. Re-run Invoke-TerraformPlan.ps1 to produce a valid envelope."
}
$envelopeNorm = Format-PathForCompare $meta.workingDir
$currentNorm  = Format-PathForCompare $workDir
if (-not $envelopeNorm.Equals($currentNorm, $pathCmp)) {
    throw "Plan envelope was produced for workingDir '$($meta.workingDir)' but -Path resolves to '$workDir'. Re-run Invoke-TerraformPlan.ps1 from the intended workspace, or run apply against the right -Path."
}

# Binary plan file must still exist at the (workdir-relative) path the
# envelope names. Without it, `terraform apply <planfile>` has nothing
# to apply. Validate presence + shape of the field BEFORE calling
# IsPathRooted, which throws an ArgumentNullException on $null and is
# a poor diagnostic when the real problem is a malformed envelope.
$hasPlanBinary = [bool]($meta.PSObject.Properties['planBinary']) -and $meta.planBinary
if (-not $hasPlanBinary) {
    throw "Plan envelope is missing the 'planBinary' field; refusing to apply. Re-run Invoke-TerraformPlan.ps1 to produce a valid envelope."
}
if ($meta.planBinary -isnot [string]) {
    throw "Plan envelope's 'planBinary' is not a string (got type $($meta.planBinary.GetType().FullName)); refusing to apply from a malformed envelope."
}
# Reject path traversal explicitly. The envelope contract is that
# planBinary is a path RELATIVE to workingDir and stays inside it;
# Write-TfPlanMetadata enforces that when producing the envelope. A
# `../../` in the recorded value either means someone hand-edited the
# envelope or `-Out` was given an out-of-workspace absolute path at
# plan time (which Invoke-TerraformPlan.ps1 now also refuses). Either
# way the apply step shouldn't reach outside the workdir to find its
# plan -- those don't "travel together inside the workspace" any more.
$planBinRaw = $meta.planBinary
if ($planBinRaw -match '(^|[\\/])\.\.([\\/]|$)') {
    throw "Plan envelope's 'planBinary' contains a path traversal ('..'): $planBinRaw. Plans must live inside the workspace they were produced for; re-run Invoke-TerraformPlan.ps1 with -Out under the working directory."
}
# Likewise reject a rooted (absolute) planBinary unless it resolves
# under $workDir. The envelope's planBinary is meant to be workdir-
# relative for portability; a rooted value points to a specific path
# on whoever-ran-plan's machine, which both breaks portability AND
# (combined with a hand-edited envelope) could direct `terraform apply`
# at a plan file completely outside the workspace.
if ([System.IO.Path]::IsPathRooted($planBinRaw)) {
    $rootedFull = [System.IO.Path]::GetFullPath($planBinRaw)
    $workFull   = [System.IO.Path]::GetFullPath($workDir).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $rootedFull.StartsWith($workFull, $pathCmp)) {
        throw "Plan envelope's 'planBinary' is an absolute path outside the working directory: '$planBinRaw' is not under '$workDir'. Plans must live inside the workspace; re-run Invoke-TerraformPlan.ps1 with a workdir-relative -Out."
    }
}
$planBin = $planBinRaw
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
