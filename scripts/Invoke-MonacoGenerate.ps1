# Compatibility shim. See scripts/Get-MonacoVersion.ps1 for the removal policy.
[Console]::Error.WriteLine("[deprecation] scripts/Invoke-MonacoGenerate.ps1 moved to scripts/monaco/Invoke-MonacoGenerate.ps1. Update your invocation; this shim will be removed in the next release.")
& "$PSScriptRoot/monaco/Invoke-MonacoGenerate.ps1" @args
exit $LASTEXITCODE
