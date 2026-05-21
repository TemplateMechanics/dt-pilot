<#
.SYNOPSIS
    Print the installed Terraform CLI version (and the resolved
    executable path).

.DESCRIPTION
    Repo-wide diagnostic. Does not take -Path because it operates on the
    Terraform binary, not on a specific Terraform working directory.
    Use this as the first sanity check when the harness reports trouble
    finding Terraform.

.PARAMETER TerraformExe
    Explicit path to the Terraform executable. Resolution precedence:
    explicit -TerraformExe > TERRAFORM_EXE / TF_EXE env > first
    'terraform' application on PATH. CI typically pins via
    TERRAFORM_EXE; local dev uses PATH.

.EXAMPLE
    ./scripts/terraform/Get-TerraformVersion.ps1

.EXAMPLE
    ./scripts/terraform/Get-TerraformVersion.ps1 -TerraformExe C:\tools\terraform.exe
#>

[CmdletBinding()]
param([string] $TerraformExe)

. "$PSScriptRoot/_Common.ps1"

$exe = Resolve-TerraformExe -TerraformExe $TerraformExe
Write-Host "Terraform executable: $exe"
# We need a working directory for terraform version, even though the
# command doesn't actually need one. Use the script's own dir as a
# benign default; terraform version doesn't read any local config.
$result = Invoke-TerraformCommand -TerraformExe $exe -Arguments @('version') -WorkingDirectory $PSScriptRoot -CaptureOutput
if ($result.ExitCode -ne 0) {
    Write-Host $result.StdErr
    throw "terraform version exited with code $($result.ExitCode)"
}
Write-Host $result.StdOut.TrimEnd()
exit 0
