<#
.SYNOPSIS
    Run `terraform init` on a working directory. Use this on first
    clone, after editing versions.tf / required_providers, or when the
    .terraform.lock.hcl needs refreshing.

.PARAMETER Path
    Directory containing the .tf files (the Terraform working directory).

.PARAMETER Upgrade
    Pass `-upgrade` to terraform init. Use after relaxing a version
    constraint or after a deliberate provider bump.

.PARAMETER TerraformExe
    Override the Terraform executable lookup.

.EXAMPLE
    ./scripts/terraform/Initialize-TerraformWorkspace.ps1 -Path examples/terraform-baseline

.EXAMPLE
    ./scripts/terraform/Initialize-TerraformWorkspace.ps1 -Path . -Upgrade
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [switch] $Upgrade,
    [string] $TerraformExe
)

. "$PSScriptRoot/_Common.ps1"

$exe     = Resolve-TerraformExe -TerraformExe $TerraformExe
$workDir = Resolve-TerraformWorkingDir -Path $Path

Write-Host "Terraform: $exe"
Write-Host "Workdir:   $workDir"

# Pre-init: no auth env required (init pulls providers from the
# registry, not from Dynatrace). Subsequent plan/apply will need creds.
$args = @('init', '-input=false')
if ($Upgrade) { $args += '-upgrade' }

$result = Invoke-TerraformCommand -TerraformExe $exe -Arguments $args -WorkingDirectory $workDir
if ($result.ExitCode -ne 0) {
    Write-Host "terraform init FAILED (exit $($result.ExitCode))" -ForegroundColor Red
    exit $result.ExitCode
}
Write-Host "Workspace initialized." -ForegroundColor Green
exit 0
