<#
.SYNOPSIS
    Run `terraform fmt -check` and `terraform validate` on a working
    directory. Fast feedback loop after editing .tf files; intended for
    operator-driven invocation before opening a PR.

    NOTE: this script is NOT wired into scripts/Pre-Commit.ps1 because
    it requires a working `terraform` binary (and `terraform validate`
    additionally requires an initialized workspace with provider
    downloads). The pre-commit gate stays hermetic -- it runs manifest
    checks, the MCP secret scanner, the catalog sync check, and Pester
    only. Validate-Terraform should be run locally before pushing, and
    in any CI workflow that already has terraform installed and inited.

.DESCRIPTION
    Two-step structural check:
      1. `terraform fmt -check -recursive` -- non-zero if any .tf file
         isn't canonically formatted.
      2. `terraform validate` -- non-zero if the configuration is
         syntactically invalid or references unknown providers /
         resources / variables.

    Neither step talks to Dynatrace. To exercise the full path against
    a live tenant, use Invoke-TerraformPlan.ps1.

.PARAMETER Path
    Directory containing the .tf files.

.PARAMETER TerraformExe
    Override the Terraform executable lookup.

.PARAMETER SkipFmt
    Skip the fmt check (e.g. during a deliberately mid-formatting
    refactor). Use sparingly; CI does NOT honor this flag.

.EXAMPLE
    ./scripts/terraform/Validate-Terraform.ps1 -Path examples/terraform-baseline
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $TerraformExe,
    [switch] $SkipFmt
)

. "$PSScriptRoot/_Common.ps1"

$exe     = Resolve-TerraformExe -TerraformExe $TerraformExe
$workDir = Resolve-TerraformWorkingDir -Path $Path

# Build the canonical -> provider-specific env-var translation. fmt
# alone doesn't need provider env, but `terraform validate` does any
# provider-configuration-time checks the dynatrace provider performs
# (and any module that uses `data` sources during validate) -- pass
# the same -ExtraEnv every other wrapper uses so behaviour stays
# consistent and users who only set the canonical dt-pilot names get
# the same translation here. The parent shell's $env: stays untouched.
$providerEnv = Get-TerraformProviderEnv

$failed = $false

if (-not $SkipFmt) {
    Write-Host "terraform fmt -check"
    $fmt = Invoke-TerraformCommand -TerraformExe $exe -Arguments @('fmt','-check','-recursive') -WorkingDirectory $workDir -CaptureOutput -ExtraEnv $providerEnv
    if ($fmt.StdOut) { Write-Host $fmt.StdOut.TrimEnd() }
    # Print StdErr too -- terraform fmt often emits the actual
    # "couldn't read file" / "invalid HCL" details to stderr and hiding
    # it leaves the operator with just an exit code and no diagnostic.
    if ($fmt.StdErr) { Write-Host $fmt.StdErr.TrimEnd() }
    if ($fmt.ExitCode -ne 0) {
        Write-Host "fmt FAILED (run 'terraform fmt -recursive' to fix)" -ForegroundColor Red
        $failed = $true
    }
} else {
    Write-Host "fmt check skipped via -SkipFmt" -ForegroundColor DarkGray
}

Write-Host "terraform validate"
$val = Invoke-TerraformCommand -TerraformExe $exe -Arguments @('validate') -WorkingDirectory $workDir -CaptureOutput -ExtraEnv $providerEnv
if ($val.StdOut) { Write-Host $val.StdOut.TrimEnd() }
if ($val.StdErr) { Write-Host $val.StdErr.TrimEnd() }
if ($val.ExitCode -ne 0) {
    Write-Host "validate FAILED (exit $($val.ExitCode))" -ForegroundColor Red
    $failed = $true
}

if ($failed) { exit 1 }
Write-Host "Validation passed." -ForegroundColor Green
exit 0
