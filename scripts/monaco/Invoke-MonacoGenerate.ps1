<#
.SYNOPSIS
    Wrap 'monaco generate' to produce a deletefile, a JSON schema for a
    settings 2.0 type, or a deploy-DAG visualization.

.DESCRIPTION
    Three subtypes:

      - deletefile: enumerates every config currently referenced by the
        manifest into a deletefile.yaml. Use this as the starting point
        for a curated deletion (prune it to the subset you intend to
        remove, commit, then invoke Invoke-MonacoDelete.ps1).

      - schema: dumps the JSON schema for a settings 2.0 schema ID, useful
        for discovering valid fields before authoring a template.json.
        Requires -Schema.

      - graph: renders the cross-config dependency DAG. Output format
        defaults to DOT (Graphviz).

.PARAMETER Path
    Directory containing manifest.yaml (or the explicit manifest file path).
    Required for the 'deletefile' and 'graph' subtypes.

.PARAMETER Type
    One of: deletefile, schema, graph.

.PARAMETER Schema
    The settings 2.0 schema ID (e.g. 'builtin:alerting.profile') for the
    'schema' subtype.

.PARAMETER Output
    Output file or directory. Defaults are subtype-specific.

.PARAMETER MonacoExe
    Override the Monaco executable lookup.

.EXAMPLE
    ./scripts/monaco/Invoke-MonacoGenerate.ps1 -Path . -Type deletefile -Output deletefile.yaml

.EXAMPLE
    ./scripts/monaco/Invoke-MonacoGenerate.ps1 -Type schema -Schema builtin:alerting.profile

.EXAMPLE
    ./scripts/monaco/Invoke-MonacoGenerate.ps1 -Path . -Type graph -Output graph.dot
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('deletefile','schema','graph')] [string] $Type,
    [string] $Path,
    [string] $Schema,
    [string] $Output,
    [string] $MonacoExe
)

. "$PSScriptRoot/_Common.ps1"

$exe = Resolve-MonacoExe -MonacoExe $MonacoExe

switch ($Type) {
    'deletefile' {
        if (-not $Path) { throw "-Path is required for 'deletefile' generation." }
        if (-not $Output) { $Output = 'deletefile.yaml' }
        $manifest = Resolve-ManifestPath -Path $Path
        $workDir = Split-Path -Parent $manifest
        $args = @('generate', 'deletefile', '--manifest', (Split-Path -Leaf $manifest), '--file', $Output)
        Write-Host "Generating deletefile from $manifest -> $Output"
    }
    'schema' {
        if (-not $Schema) { throw "-Schema (e.g. 'builtin:alerting.profile') is required for 'schema' generation." }
        $workDir = (Get-Location).Path
        $args = @('generate', 'schema', '--schema', $Schema)
        if ($Output) { $args += @('--output', $Output) }
        Write-Host "Generating schema for $Schema"
    }
    'graph' {
        if (-not $Path) { throw "-Path is required for 'graph' generation." }
        if (-not $Output) { $Output = 'graph.dot' }
        $manifest = Resolve-ManifestPath -Path $Path
        $workDir = Split-Path -Parent $manifest
        $args = @('generate', 'graph', '--manifest', (Split-Path -Leaf $manifest), '--output', $Output)
        Write-Host "Generating dependency graph from $manifest -> $Output"
    }
}

$result = Invoke-MonacoCommand -MonacoExe $exe -Arguments $args -WorkingDirectory $workDir -CaptureOutput

if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }

if ($result.ExitCode -ne 0) {
    Write-Host "Generate FAILED (exit code $($result.ExitCode))" -ForegroundColor Red
    exit $result.ExitCode
}

Write-Host "Generate completed." -ForegroundColor Green
exit 0
