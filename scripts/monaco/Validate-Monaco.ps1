<#
.SYNOPSIS
    Validate a Monaco workspace by running 'monaco deploy --dry-run' and
    surfacing the result. Use this as the fast feedback loop after any edit.

.DESCRIPTION
    Validation is a Monaco-internal concept: there is no separate
    'monaco validate' command. The CLI's --dry-run flag renders templates,
    resolves references, and validates the request shape against the live
    Dynatrace API without performing any writes. Validate-Monaco.ps1 wraps
    that with a tighter scope (no environment-specific output capture) so
    it is cheap to run in pre-commit and in CI.

    For a dry-run intended for human review before deploy, use
    Invoke-MonacoDryRun.ps1 instead -- it persists the structured output.

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).

.PARAMETER Environment
    Restrict validation to a single environment from the manifest. If
    omitted, Monaco validates all environments in all groups.

.PARAMETER Group
    Restrict validation to a single environment group from the manifest.

.PARAMETER Project
    Restrict validation to a single project.

.PARAMETER MonacoExe
    Override the Monaco executable lookup.

.EXAMPLE
    ./scripts/monaco/Validate-Monaco.ps1 -Path examples/baseline-stack

.EXAMPLE
    ./scripts/monaco/Validate-Monaco.ps1 -Path . -Environment dev
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $Environment,
    [string] $Group,
    [string] $Project,
    [string] $MonacoExe
)

. "$PSScriptRoot/_Common.ps1"

$exe = Resolve-MonacoExe -MonacoExe $MonacoExe
$manifest = Resolve-ManifestPath -Path $Path
$workDir = Split-Path -Parent $manifest

$args = @('deploy', '--dry-run', (Split-Path -Leaf $manifest))
if ($Environment) { $args += @('--environment', $Environment) }
if ($Group)       { $args += @('--group', $Group) }
if ($Project)     { $args += @('--project', $Project) }

Write-Host "Validating Monaco workspace: $manifest"
$result = Invoke-MonacoCommand -MonacoExe $exe -Arguments $args -WorkingDirectory $workDir -CaptureOutput

if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }

if ($result.ExitCode -ne 0) {
    Write-Host "Validation FAILED (exit code $($result.ExitCode))" -ForegroundColor Red
    exit $result.ExitCode
}

Write-Host "Validation passed." -ForegroundColor Green
exit 0
