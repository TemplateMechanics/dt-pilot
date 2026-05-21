# Compatibility shim. See scripts/Get-MonacoVersion.ps1 for the removal policy.
[Console]::Error.WriteLine("[deprecation] scripts/Sync-ConfigCatalog.ps1 moved to scripts/monaco/Sync-ConfigCatalog.ps1. Update your invocation; this shim will be removed in the next release.")
& "$PSScriptRoot/monaco/Sync-ConfigCatalog.ps1" @args
exit $LASTEXITCODE
