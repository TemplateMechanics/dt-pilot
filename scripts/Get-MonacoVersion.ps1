<#
.SYNOPSIS
    Print the installed Monaco CLI version (and the resolved executable path).

.DESCRIPTION
    Repo-wide diagnostic. Does not take -Path because it operates on the
    Monaco binary, not on a specific manifest or project. Use this as the
    first sanity check when the harness reports trouble finding Monaco.

.PARAMETER MonacoExe
    Explicit path to the Monaco executable. Resolution precedence is:
    explicit -MonacoExe > MONACO_EXE environment variable > first 'monaco'
    application on PATH. CI typically pins via MONACO_EXE; local dev uses
    PATH.

.EXAMPLE
    ./scripts/Get-MonacoVersion.ps1

.EXAMPLE
    ./scripts/Get-MonacoVersion.ps1 -MonacoExe C:\tools\monaco.exe
#>

[CmdletBinding()]
param(
    [string] $MonacoExe
)

. "$PSScriptRoot/_Common.ps1"

$exe = Resolve-MonacoExe -MonacoExe $MonacoExe
Write-Host "Monaco executable: $exe"

$result = Invoke-MonacoCommand -MonacoExe $exe -Arguments @('version') -CaptureOutput
if ($result.ExitCode -ne 0) {
    Write-Host $result.StdErr
    throw "monaco version exited with code $($result.ExitCode)"
}
Write-Host $result.StdOut.TrimEnd()
exit 0
