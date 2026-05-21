<#
.SYNOPSIS
    Destroy Terraform-managed Dynatrace resources. Refuses to run
    without an explicit -Confirm.

.DESCRIPTION
    Wraps `terraform destroy`. Two safety gates:
      1. Mandatory -Confirm switch; refuses to run without it.
      2. Prints a `terraform plan -destroy` summary before invoking
         destroy so the operator can Ctrl-C if anything looks wrong.

    Beyond the wrapper, the agent persona (agents/terraform.agent.md)
    requires an explicit destroy authorization in the chat conversation
    before invoking this script -- that's conversational discipline,
    not enforceable in code, but the -Confirm gate is.

.PARAMETER Path
    Directory containing the .tf files.

.PARAMETER Environment
    Environment label used for the destroy plan envelope (matches the
    Plan/Apply naming).

.PARAMETER VarFile
    Optional -var-file (e.g. 'envs/dev.tfvars').

.PARAMETER Confirm
    Required. Must be explicitly $true. The mandatory switch is the
    primary safety gate; chat-level destroy authorization is the
    secondary gate enforced by the agent persona.

.PARAMETER TerraformExe
    Override the Terraform executable lookup.

.EXAMPLE
    ./scripts/terraform/Invoke-TerraformDestroy.ps1 -Path examples/terraform-baseline -Environment dev -Confirm
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Environment,
    [string] $VarFile,
    [Parameter(Mandatory)] [switch] $Confirm,
    [string] $TerraformExe
)

. "$PSScriptRoot/_Common.ps1"

if (-not $Confirm) {
    throw "Refusing to destroy: -Confirm was not specified. Pass -Confirm to acknowledge that destroy is irreversible."
}

$exe     = Resolve-TerraformExe -TerraformExe $TerraformExe
$workDir = Resolve-TerraformWorkingDir -Path $Path

Set-TerraformProviderEnv

# Show the destroy plan first so the operator gets one last preview.
$planArgs = @('plan','-destroy','-input=false')
if ($VarFile) { $planArgs += @('-var-file', $VarFile) }

Write-Host "Destroy preview (terraform plan -destroy)..." -ForegroundColor Yellow
$preview = Invoke-TerraformCommand -TerraformExe $exe -Arguments $planArgs -WorkingDirectory $workDir -CaptureOutput
if ($preview.StdOut) { Write-Host $preview.StdOut.TrimEnd() }
if ($preview.StdErr) { Write-Host $preview.StdErr.TrimEnd() }
if ($preview.ExitCode -ne 0) {
    Write-Host "Destroy preview FAILED (exit $($preview.ExitCode)); refusing to destroy." -ForegroundColor Red
    exit $preview.ExitCode
}

Write-Host ""
Write-Host "About to destroy the resources above in $workDir -> environment '$Environment'." -ForegroundColor Yellow
Write-Host "Proceeding (the -Confirm switch was supplied)." -ForegroundColor Yellow
Write-Host ""

$destroyArgs = @('destroy','-input=false','-auto-approve')
if ($VarFile) { $destroyArgs += @('-var-file', $VarFile) }

$result = Invoke-TerraformCommand -TerraformExe $exe -Arguments $destroyArgs -WorkingDirectory $workDir -CaptureOutput
if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }
if ($result.ExitCode -ne 0) {
    Write-Host "Destroy FAILED (exit $($result.ExitCode))" -ForegroundColor Red
    exit $result.ExitCode
}
Write-Host "Destroy completed." -ForegroundColor Green
exit 0
