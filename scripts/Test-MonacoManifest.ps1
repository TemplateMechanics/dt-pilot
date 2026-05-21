# Compatibility shim. See scripts/Get-MonacoVersion.ps1 for the removal policy.
[Console]::Error.WriteLine("[deprecation] scripts/Test-MonacoManifest.ps1 moved to scripts/monaco/Test-MonacoManifest.ps1. Update your invocation; this shim will be removed in the next release.")
& "$PSScriptRoot/monaco/Test-MonacoManifest.ps1" @args
exit $LASTEXITCODE
