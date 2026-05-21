# Compatibility shim. The implementation moved to scripts/monaco/Get-MonacoVersion.ps1
# as part of the multi-backend skeleton (design 001). This shim forwards every
# argument verbatim and returns the underlying script's exit code.
#
# REMOVAL: this shim will be removed in the release after the one that introduces
# scripts/monaco/. See the deprecation-removal issue linked from CHANGELOG.md.
[Console]::Error.WriteLine("[deprecation] scripts/Get-MonacoVersion.ps1 moved to scripts/monaco/Get-MonacoVersion.ps1. Update your invocation; this shim will be removed in the next release.")
& "$PSScriptRoot/monaco/Get-MonacoVersion.ps1" @args
exit $LASTEXITCODE
