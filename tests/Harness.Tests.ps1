# tests/Harness.Tests.ps1
# Pester 5+ suite exercising the dt-pilot wrapper scripts WITHOUT requiring
# Monaco itself, Node.js, or a live Dynatrace tenant. Live integration is
# out of scope here — those workflows are exercised in soak/example jobs
# downstream of this gate.

#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ScriptDir  = Join-Path $script:RepoRoot 'scripts'         # repo-wide scripts (Pre-Commit, MCP helpers)
    $script:MonacoDir  = Join-Path $script:ScriptDir 'monaco'         # Monaco backend wrappers (PR 'multi-backend skeleton')
    . (Join-Path $script:MonacoDir '_Common.ps1')

    function New-TempWorkspace {
        param([string] $ManifestBody, [hashtable] $ProjectFiles)
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tests-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        $manifest = Join-Path $root 'manifest.yaml'
        Set-Content -LiteralPath $manifest -Value $ManifestBody -Encoding utf8
        if ($ProjectFiles) {
            foreach ($rel in $ProjectFiles.Keys) {
                $full = Join-Path $root $rel
                $dir = Split-Path -Parent $full
                if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
                Set-Content -LiteralPath $full -Value $ProjectFiles[$rel] -Encoding utf8
            }
        }
        return $root
    }

    $script:MinimalManifest = @'
manifestVersion: 1.0

projects:
  - name: alpha
  - name: beta
    path: custom-beta

environmentGroups:
  - name: dev
    environments:
      - name: dev
        url:
          type: environment
          value: DT_URL_DEV
        auth:
          token:
            name: DT_TOKEN_DEV
'@
}

Describe '_Common.Resolve-ManifestPath' {
    It 'accepts a directory and returns the contained manifest.yaml' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/keep.txt' = 'x'
            'custom-beta/keep.txt' = 'x'
        }
        try {
            $result = Resolve-ManifestPath -Path $root
            (Split-Path -Leaf $result) | Should -Be 'manifest.yaml'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'accepts a manifest file path directly' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/keep.txt' = 'x'; 'custom-beta/keep.txt' = 'x'
        }
        try {
            $m = Join-Path $root 'manifest.yaml'
            (Resolve-ManifestPath -Path $m) | Should -Be (Resolve-Path -LiteralPath $m).ProviderPath
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'throws on a directory without manifest.yaml' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-empty-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        try {
            { Resolve-ManifestPath -Path $dir } | Should -Throw -ExpectedMessage '*No manifest.yaml*'
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
}

Describe '_Common.Get-ManifestProjectDirs' {
    It 'honors projects[].path overrides' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/keep.txt' = 'x'
            'custom-beta/keep.txt' = 'x'
        }
        try {
            $dirs = Get-ManifestProjectDirs -ManifestPath (Join-Path $root 'manifest.yaml')
            $dirs.Count | Should -Be 2
            ($dirs | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'alpha'
            ($dirs | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'custom-beta'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Describe '_Common.Get-WorkspaceHash' {
    It 'changes when a project file changes' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/config.yaml' = "configs: []`n"
            'custom-beta/config.yaml' = "configs: []`n"
        }
        try {
            $manifest = Join-Path $root 'manifest.yaml'
            $before = Get-WorkspaceHash -ManifestPath $manifest
            Set-Content -LiteralPath (Join-Path $root 'alpha/config.yaml') -Value "configs: [ { id: new } ]`n" -Encoding utf8
            $after = Get-WorkspaceHash -ManifestPath $manifest
            $before | Should -Not -Be $after
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'is stable across re-reads when nothing changes' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/config.yaml' = "configs: []`n"
            'custom-beta/config.yaml' = "configs: []`n"
        }
        try {
            $manifest = Join-Path $root 'manifest.yaml'
            (Get-WorkspaceHash -ManifestPath $manifest) | Should -Be (Get-WorkspaceHash -ManifestPath $manifest)
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Describe '_Common.Write-DryRunMetadata + Read-DryRunMetadata round-trip' {
    It 'round-trips schema, environment, hashes, exit code, and summary' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/config.yaml' = "configs: []`n"
            'custom-beta/config.yaml' = "configs: []`n"
        }
        try {
            $manifest = Join-Path $root 'manifest.yaml'
            $out = Join-Path $root 'dryrun/dev.json'
            Write-DryRunMetadata -OutPath $out -ManifestPath $manifest -Environment 'dev' `
                                  -MonacoExe 'C:\fake\monaco.exe' -ExitCode 0 `
                                  -RawOutput "would create x`nwould update y`n"
            $meta = Read-DryRunMetadata -DryRunFile $out
            $meta.schema      | Should -Be 'dt-pilot.dryrun/v1'
            $meta.environment | Should -Be 'dev'
            $meta.exitCode    | Should -Be 0
            $meta.summary.wouldCreate | Should -Be 1
            $meta.summary.wouldUpdate | Should -Be 1
            $meta.summary.wouldDelete | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'Read-DryRunMetadata rejects a failed dry-run' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/config.yaml' = "configs: []`n"
            'custom-beta/config.yaml' = "configs: []`n"
        }
        try {
            $manifest = Join-Path $root 'manifest.yaml'
            $out = Join-Path $root 'dryrun/dev.json'
            Write-DryRunMetadata -OutPath $out -ManifestPath $manifest -Environment 'dev' `
                                  -MonacoExe 'C:\fake\monaco.exe' -ExitCode 7 -RawOutput "boom"
            { Read-DryRunMetadata -DryRunFile $out } | Should -Throw -ExpectedMessage '*non-zero exit*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'Read-DryRunMetadata rejects a wrong-schema artifact' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-baddry-" + [System.Guid]::NewGuid().ToString('N') + ".json")
        '{"schema":"other/v9","environment":"dev","exitCode":0}' | Set-Content -LiteralPath $tmp -Encoding utf8
        try {
            { Read-DryRunMetadata -DryRunFile $tmp } | Should -Throw -ExpectedMessage '*not a dt-pilot dry-run*'
        } finally {
            Remove-Item -LiteralPath $tmp -Force
        }
    }
}

Describe 'Test-MonacoManifest.ps1' {
    It 'passes a healthy manifest' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/keep.txt' = 'x'; 'custom-beta/keep.txt' = 'x'
        }
        try {
            & (Join-Path $script:MonacoDir 'Test-MonacoManifest.ps1') -Path $root *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'fails on a manifest missing manifestVersion' {
        $bad = @'
projects:
  - name: alpha
environmentGroups:
  - name: dev
    environments:
      - name: dev
        url: { type: environment, value: X }
        auth: { token: { name: Y } }
'@
        $root = New-TempWorkspace -ManifestBody $bad -ProjectFiles @{ 'alpha/keep.txt' = 'x' }
        try {
            & (Join-Path $script:MonacoDir 'Test-MonacoManifest.ps1') -Path $root *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'flags a literal URL in a value field' {
        $bad = @'
manifestVersion: 1.0
projects:
  - name: alpha
environmentGroups:
  - name: dev
    environments:
      - name: dev
        url:
          type: value
          value: https://abc12345.live.dynatrace.com
        auth:
          token:
            name: DT_TOKEN_DEV
'@
        $root = New-TempWorkspace -ManifestBody $bad -ProjectFiles @{ 'alpha/keep.txt' = 'x' }
        try {
            & (Join-Path $script:MonacoDir 'Test-MonacoManifest.ps1') -Path $root *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'honors projects[].path so an explicit override does not false-fail' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/keep.txt' = 'x'
            'custom-beta/keep.txt' = 'x'
        }
        try {
            & (Join-Path $script:MonacoDir 'Test-MonacoManifest.ps1') -Path $root *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Describe 'Test-McpConfigSecrets.ps1' {
    It 'passes on the committed .vscode/mcp.json (gate must not false-fail on its own template)' {
        & (Join-Path $script:ScriptDir 'Test-McpConfigSecrets.ps1') *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'flags a token literal inside an env value' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-mcp-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $tmpDir '.vscode')
        $bad = @'
{
  "servers": {
    "x": {
      "type": "stdio",
      "command": "true",
      "env": {
        "DT_PLATFORM_TOKEN": "dt0c01.ABCDEFGHIJKLMNOPQRSTUVWX.YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY"
      }
    }
  }
}
'@
        $target = Join-Path $tmpDir '.vscode/mcp.json'
        Set-Content -LiteralPath $target -Value $bad -Encoding utf8

        # Build a temp script that invokes the scanner against our temp
        # file by string-replacing $PSScriptRoot with our temp path.
        # Use .Replace() (literal substring), NOT -replace, because
        # -replace runs the second arg through .NET regex replacement
        # rules and a Windows path containing backslashes would be
        # mangled into escape sequences (\t, \n, etc).
        $scannerSrc = Get-Content -LiteralPath (Join-Path $script:ScriptDir 'Test-McpConfigSecrets.ps1') -Raw
        $copy = Join-Path $tmpDir 'scan.ps1'
        $injected = $scannerSrc.Replace('$PSScriptRoot', "'$tmpDir/scripts'")
        Set-Content -LiteralPath $copy -Value $injected -Encoding utf8
        $null = New-Item -ItemType Directory -Path (Join-Path $tmpDir 'scripts')

        try {
            & pwsh -NoProfile -File $copy *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force
        }
    }
}

Describe 'Invoke-MonacoDeploy.ps1 rejection paths' {
    BeforeAll {
        # We need the deploy script to fail BEFORE calling monaco, so we
        # never actually need monaco installed for these tests. We set
        # MONACO_EXE to this test file itself — a real file path that
        # exists — so Resolve-MonacoExe is satisfied. The rejection
        # checks all fire before any monaco invocation would happen.
        $script:fakeMonaco = (Get-Item -LiteralPath $PSCommandPath).FullName
    }

    It 'rejects a missing DryRunFile' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/config.yaml' = "configs: []`n"
            'custom-beta/config.yaml' = "configs: []`n"
        }
        try {
            { & (Join-Path $script:MonacoDir 'Invoke-MonacoDeploy.ps1') `
                -Path $root -Environment dev `
                -DryRunFile (Join-Path $root 'does-not-exist.json') `
                -MonacoExe $script:fakeMonaco } | Should -Throw -ExpectedMessage '*does not exist*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'rejects a dry-run from a different environment' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/config.yaml' = "configs: []`n"
            'custom-beta/config.yaml' = "configs: []`n"
        }
        try {
            $manifest = Join-Path $root 'manifest.yaml'
            $out = Join-Path $root 'dryrun/staging.json'
            Write-DryRunMetadata -OutPath $out -ManifestPath $manifest -Environment 'staging' `
                                  -MonacoExe $script:fakeMonaco -ExitCode 0 -RawOutput ''
            { & (Join-Path $script:MonacoDir 'Invoke-MonacoDeploy.ps1') `
                -Path $root -Environment dev -DryRunFile $out -MonacoExe $script:fakeMonaco } |
                Should -Throw -ExpectedMessage "*environment 'staging'*"
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'rejects a stale dry-run (older than -MaxAgeMinutes)' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/config.yaml' = "configs: []`n"
            'custom-beta/config.yaml' = "configs: []`n"
        }
        try {
            $manifest = Join-Path $root 'manifest.yaml'
            $out = Join-Path $root 'dryrun/dev.json'
            Write-DryRunMetadata -OutPath $out -ManifestPath $manifest -Environment 'dev' `
                                  -MonacoExe $script:fakeMonaco -ExitCode 0 -RawOutput ''
            # Backdate createdAtUtc in the artifact.
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $obj.createdAtUtc = (Get-Date).AddMinutes(-99).ToUniversalTime().ToString('o')
            $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $out -Encoding utf8
            { & (Join-Path $script:MonacoDir 'Invoke-MonacoDeploy.ps1') `
                -Path $root -Environment dev -DryRunFile $out `
                -MaxAgeMinutes 30 -MonacoExe $script:fakeMonaco } |
                Should -Throw -ExpectedMessage '*minute(s) old*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'rejects a workspace edit after dry-run (workspaceHash mismatch)' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/config.yaml' = "configs: []`n"
            'custom-beta/config.yaml' = "configs: []`n"
        }
        try {
            $manifest = Join-Path $root 'manifest.yaml'
            $out = Join-Path $root 'dryrun/dev.json'
            Write-DryRunMetadata -OutPath $out -ManifestPath $manifest -Environment 'dev' `
                                  -MonacoExe $script:fakeMonaco -ExitCode 0 -RawOutput ''
            # Edit a project file AFTER the dry-run.
            Set-Content -LiteralPath (Join-Path $root 'alpha/config.yaml') -Value "configs: [ { id: new } ]`n" -Encoding utf8
            { & (Join-Path $script:MonacoDir 'Invoke-MonacoDeploy.ps1') `
                -Path $root -Environment dev -DryRunFile $out -MonacoExe $script:fakeMonaco } |
                Should -Throw -ExpectedMessage '*workspaceHash mismatch*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Describe 'Compatibility shims at scripts/ root' {
    BeforeAll {
        $script:ExpectedShims = @(
            'Get-MonacoVersion.ps1','Initialize-MonacoWorkspace.ps1','Invoke-MonacoDelete.ps1',
            'Invoke-MonacoDeploy.ps1','Invoke-MonacoDownload.ps1','Invoke-MonacoDryRun.ps1',
            'Invoke-MonacoGenerate.ps1','Sync-ConfigCatalog.ps1','Test-MonacoManifest.ps1','Validate-Monaco.ps1'
        )
    }

    It 'every Monaco wrapper has a shim at scripts/ root and a target under scripts/monaco/' {
        foreach ($name in $script:ExpectedShims) {
            $shim = Join-Path $script:ScriptDir $name
            (Test-Path -LiteralPath $shim -PathType Leaf) | Should -BeTrue -Because "shim $name must exist at scripts/ root"
            $target = Join-Path $script:MonacoDir $name
            (Test-Path -LiteralPath $target -PathType Leaf) | Should -BeTrue -Because "target $name must exist at scripts/monaco/"
        }
    }

    It 'every shim writes a deprecation marker to stderr, forwards to scripts/monaco/, and preserves the exit code' {
        # Intent-level assertions only -- formatting (single vs double
        # quotes, Join-Path vs literal, forward vs backslash) is not the
        # contract. The contract is: deprecation -> stderr, invocation of
        # the monaco target with @args, exit code passthrough.
        foreach ($name in $script:ExpectedShims) {
            $shim = Join-Path $script:ScriptDir $name
            $body = Get-Content -LiteralPath $shim -Raw

            # Accept any common PS stderr emission shape: the .NET
            # Console.Error API, Write-Error, or the `1>&2` redirection
            # operator. (`2>&1` does the opposite -- it folds stderr
            # into stdout -- so it is intentionally NOT accepted.)
            # Source-text matching is permissive; runtime behavior is
            # what matters.
            $body | Should -Match '(?i)(Console.*Error.*WriteLine|Write-Error|1>&2)' `
                -Because "shim $name must emit its deprecation marker to stderr by some means"

            $body | Should -Match ('\[deprecation\][^\n]*' + [regex]::Escape($name)) `
                -Because "shim $name must name itself in the deprecation marker"

            $body | Should -Match ('monaco[\\/]' + [regex]::Escape($name)) `
                -Because "shim $name must reference scripts/monaco/$name as its target"

            $body | Should -Match '@args' `
                -Because "shim $name must forward arguments via splat"

            $body | Should -Match '\$LASTEXITCODE' `
                -Because "shim $name must propagate the underlying exit code"
        }
    }
}

Describe 'config/catalog/backends.json' {
    It 'parses as JSON and declares at least one backend' {
        $path = Join-Path $script:RepoRoot 'config/catalog/backends.json'
        (Test-Path -LiteralPath $path -PathType Leaf) | Should -BeTrue
        $reg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($reg.backends).Count | Should -BeGreaterOrEqual 1
    }

    It 'every backend.scriptsDir, skill, catalogSyncScript, and manifestValidator exists on disk' {
        $reg = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config/catalog/backends.json') -Raw | ConvertFrom-Json
        foreach ($b in $reg.backends) {
            (Test-Path -LiteralPath (Join-Path $script:RepoRoot $b.scriptsDir) -PathType Container) | Should -BeTrue -Because "scriptsDir for $($b.id)"
            (Test-Path -LiteralPath (Join-Path $script:RepoRoot $b.skill)       -PathType Leaf)      | Should -BeTrue -Because "skill for $($b.id)"
            if ($b.PSObject.Properties['catalogSyncScript']) {
                (Test-Path -LiteralPath (Join-Path $script:RepoRoot $b.catalogSyncScript) -PathType Leaf) | Should -BeTrue -Because "catalogSyncScript for $($b.id)"
            }
            if ($b.PSObject.Properties['manifestValidator']) {
                (Test-Path -LiteralPath (Join-Path $script:RepoRoot $b.manifestValidator) -PathType Leaf) | Should -BeTrue -Because "manifestValidator for $($b.id)"
            }
        }
    }
}

Describe 'Sync-CatalogFromSchemas.ps1 (Design 002)' {
    BeforeAll {
        $script:RefreshScript = Join-Path $script:MonacoDir 'Sync-CatalogFromSchemas.ps1'
        $script:StubFetcher = {
            param([string] $SchemaId)
            return [pscustomobject]@{
                description = "Stubbed description for $SchemaId."
                properties = [pscustomobject]@{
                    name           = @{ type = 'string' }
                    managementZone = @{ type = 'string' }
                    enabled        = @{ type = 'boolean' }
                }
            }
        }

        function New-TempInputsFile {
            param([string[]] $Ids)
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-inputs-" + [System.Guid]::NewGuid().ToString('N') + ".txt")
            $lines = @('# test inputs') + $Ids + @('')
            [System.IO.File]::WriteAllLines($p, $lines)
            return $p
        }

        function New-TempOutputPath {
            return (Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-out-" + [System.Guid]::NewGuid().ToString('N') + ".json"))
        }
    }

    It 'writes a catalog and the output round-trips through ConvertFrom-Json' {
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones','builtin:alerting.profile')
        $out    = New-TempOutputPath
        try {
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out -FetchSchemaScript $script:StubFetcher *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Test-Path -LiteralPath $out) | Should -BeTrue
            $parsed = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            @($parsed.schemas).Count | Should -Be 2
            $parsed.schemas[0].id     | Should -Be 'builtin:management-zones'
            $parsed.schemas[1].id     | Should -Be 'builtin:alerting.profile'
            $parsed.schemas[0].family | Should -Be 'misc'   # new schema -> family: misc
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves curated family and commonParameters from the existing catalog' {
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones')
        $out    = New-TempOutputPath
        try {
            # Seed an existing catalog with a curated entry.
            $seed = @'
{
  "$schema": "./schema.json",
  "version": "1.0",
  "schemas": [
    {
      "id": "builtin:management-zones",
      "family": "topology",
      "displayName": "Management Zone",
      "scope": "environment",
      "summary": "Hand-curated summary that should be overwritten by the refresh.",
      "commonParameters": ["zoneName"]
    }
  ]
}
'@
            [System.IO.File]::WriteAllText($out, $seed, [System.Text.UTF8Encoding]::new($false))
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out -FetchSchemaScript $script:StubFetcher *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $parsed = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $parsed.schemas[0].family            | Should -Be 'topology'
            $parsed.schemas[0].displayName       | Should -Be 'Management Zone'
            @($parsed.schemas[0].commonParameters) | Should -Be @('zoneName')
            # Summary refreshed from the stub:
            $parsed.schemas[0].summary | Should -Be 'Stubbed description for builtin:management-zones.'
            # liveFields populated from the stub's properties:
            @($parsed.schemas[0].liveFields) -join ',' | Should -Be 'enabled,managementZone,name'
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }

    It 'is byte-deterministic: same inputs -> same output across two runs' {
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones','builtin:alerting.profile','builtin:slo')
        $out1   = New-TempOutputPath
        $out2   = New-TempOutputPath
        try {
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out1 -FetchSchemaScript $script:StubFetcher *>&1 | Out-Null
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out2 -FetchSchemaScript $script:StubFetcher *>&1 | Out-Null
            (Get-FileHash -LiteralPath $out1 -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $out2 -Algorithm SHA256).Hash
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out1   -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out2   -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits raw <> characters (no HTML escapes) in the output' {
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones')
        $out    = New-TempOutputPath
        try {
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out -FetchSchemaScript $script:StubFetcher *>&1 | Out-Null
            $body = [System.IO.File]::ReadAllText($out)
            # The _comment string in the formatted catalog contains the
            # literal path templates '<family>' and '<safe-id>'. The
            # strict serializer (ConvertTo-StrictJsonString) emits the
            # raw '<' / '>' bytes; PowerShell's built-in ConvertTo-Json
            # would have escaped them to the JSON-unicode form
            # '<' / '>'. The assertions below lock in the
            # strict-serializer behavior: the raw brackets MUST be
            # present and the escaped form MUST NOT be. If the second
            # assertion ever fires, a ConvertTo-Json call snuck back
            # into the JSON serialization path.
            $body | Should -Match '<family>'
            $body | Should -Match '<safe-id>'
            $body | Should -Not -Match '\\u003c'
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }

    It '-WhatIf does not write the output file' {
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones')
        $out    = New-TempOutputPath
        try {
            & $script:RefreshScript -WhatIf -InputsPath $inputs -OutputPath $out -FetchSchemaScript $script:StubFetcher *>&1 | Out-Null
            (Test-Path -LiteralPath $out) | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an inputs file with an invalid schema ID' {
        $bad = New-TempInputsFile -Ids @('builtin:management-zones','INVALID UPPER CASE','builtin:slo')
        $out = New-TempOutputPath
        try {
            { & $script:RefreshScript -InputsPath $bad -OutputPath $out -FetchSchemaScript $script:StubFetcher } |
                Should -Throw -ExpectedMessage '*invalid schema ID*'
        } finally {
            Remove-Item -LiteralPath $bad -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an inputs file with a duplicate schema ID' {
        $dup = New-TempInputsFile -Ids @('builtin:management-zones','builtin:slo','builtin:management-zones')
        $out = New-TempOutputPath
        try {
            { & $script:RefreshScript -InputsPath $dup -OutputPath $out -FetchSchemaScript $script:StubFetcher } |
                Should -Throw -ExpectedMessage '*duplicate schema ID*'
        } finally {
            Remove-Item -LiteralPath $dup -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an empty inputs file' {
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-inputs-" + [System.Guid]::NewGuid().ToString('N') + ".txt")
        [System.IO.File]::WriteAllText($empty, "# only comments`n`n# nothing else`n")
        $out = New-TempOutputPath
        try {
            { & $script:RefreshScript -InputsPath $empty -OutputPath $out -FetchSchemaScript $script:StubFetcher } |
                Should -Throw -ExpectedMessage '*declares zero schema IDs*'
        } finally {
            Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out   -Force -ErrorAction SilentlyContinue
        }
    }

    It 'continues past per-schema failures and lists them as unresolvable' {
        # Stub that returns $null for one specific ID (simulating
        # "schema not resolvable upstream") and a valid schema for others.
        $partialStub = {
            param([string] $SchemaId)
            if ($SchemaId -eq 'builtin:slo') { return $null }
            return [pscustomobject]@{
                description = "ok"
                properties  = [pscustomobject]@{ x = @{ type = 'string' } }
            }
        }
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones','builtin:slo','builtin:alerting.profile')
        $out    = New-TempOutputPath
        try {
            $output = & $script:RefreshScript -InputsPath $inputs -OutputPath $out -FetchSchemaScript $partialStub *>&1
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'unresolvable: 1'
            ($output -join "`n") | Should -Match 'builtin:slo'
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits a placeholder entry when an unresolvable schema has no existing entry (no silent drop)' {
        # Regression for Copilot PR #13 pass 3: a brand-new schema added
        # to schemas.txt that the cron cannot resolve must produce a
        # placeholder catalog entry (family: misc, summary TODO,
        # liveFields: []) rather than disappearing. Otherwise the
        # downstream Sync-ConfigCatalog wipe+regen would silently drop
        # the scaffold dir on the first transient upstream failure.
        $unresolvableStub = { param([string] $SchemaId) return $null }
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones','builtin:new-schema')
        $out    = New-TempOutputPath
        # Seed only the management-zones entry; the new-schema id is brand new.
        $seed = @'
{
  "$schema": "./schema.json",
  "version": "1.0",
  "schemas": [
    { "id": "builtin:management-zones", "family": "topology", "displayName": "Management Zone", "scope": "environment", "summary": "Curated.", "commonParameters": ["zoneName"] }
  ]
}
'@
        [System.IO.File]::WriteAllText($out, $seed, [System.Text.UTF8Encoding]::new($false))
        try {
            # All schemas unresolvable; resolvedCount=0 means whole-env-unreachable
            # bail-out fires. To exercise the placeholder path, mix resolvable and
            # unresolvable. We override the stub:
            $mixedStub = {
                param([string] $SchemaId)
                if ($SchemaId -eq 'builtin:new-schema') { return $null }
                return [pscustomobject]@{ description = "ok"; properties = [pscustomobject]@{ x = @{ type = 'string' } } }
            }
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out -FetchSchemaScript $mixedStub *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $parsed = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            @($parsed.schemas).Count | Should -Be 2
            $new = $parsed.schemas | Where-Object { $_.id -eq 'builtin:new-schema' }
            $new                       | Should -Not -BeNullOrEmpty
            $new.family                | Should -Be 'misc'
            $new.summary               | Should -Match '^TODO:'
            @($new.commonParameters).Count | Should -Be 0
            @($new.liveFields).Count       | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still bails out when ZERO schemas resolved and fatal failures observed (whole-env-unreachable)' {
        # The placeholder behavior MUST NOT mask whole-environment-unreachable.
        # If nothing resolved AND we caught a fatal exception, the cron path
        # exits 0 with no PR opened. This keeps a Dynatrace incident from
        # paging weekly via a refresh-PR full of TODOs.
        $explosiveStub = { param([string] $SchemaId) throw "simulated transport failure" }
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones','builtin:slo')
        $out    = New-TempOutputPath
        try {
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out -FetchSchemaScript $explosiveStub *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            # No file written -- the bail-out exits before ShouldProcess.
            (Test-Path -LiteralPath $out) | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }

    It 'serializes an unresolvable existing entry as [] (not [null]) when the seed lacks liveFields' {
        # Models the realistic case: the committed catalog today has NO
        # liveFields field (it lands with this PR), so re-emitting an
        # unresolvable existing entry must coerce missing arrays to []
        # rather than [null]. Regression for the Format-CatalogJson
        # null-handling bug Copilot caught on PR #13 pass 2.
        $partialStub = {
            param([string] $SchemaId)
            if ($SchemaId -eq 'builtin:slo') { return $null }
            return [pscustomobject]@{
                description = "ok"
                properties  = [pscustomobject]@{ x = @{ type = 'string' } }
            }
        }
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones','builtin:slo')
        $out    = New-TempOutputPath
        # Note: no 'liveFields' key in the SLO entry below.
        $seed = @'
{
  "$schema": "./schema.json",
  "version": "1.0",
  "schemas": [
    {
      "id": "builtin:management-zones",
      "family": "topology",
      "displayName": "Management Zone",
      "scope": "environment",
      "summary": "Old summary.",
      "commonParameters": ["zoneName"]
    },
    {
      "id": "builtin:slo",
      "family": "alerting",
      "displayName": "Service Level Objective",
      "scope": "environment",
      "summary": "Curated SLO summary without any liveFields field.",
      "commonParameters": ["sloName"]
    }
  ]
}
'@
        [System.IO.File]::WriteAllText($out, $seed, [System.Text.UTF8Encoding]::new($false))
        try {
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out -FetchSchemaScript $partialStub *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $body = [System.IO.File]::ReadAllText($out)
            $body | Should -Not -Match '\[null\]'
            $body | Should -Not -Match '"liveFields":\s*null'
            # Parse and confirm the unresolvable entry has an empty liveFields array.
            $parsed = $body | ConvertFrom-Json
            $slo = $parsed.schemas | Where-Object { $_.id -eq 'builtin:slo' }
            @($slo.liveFields).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves an existing entry intact when its schema is unresolvable upstream' {
        # Seed an existing catalog with a curated entry for an ID that
        # the stub will say is unresolvable. The entry must survive the
        # refresh untouched (curated fields preserved, no liveFields
        # corruption, no [null] in the arrays).
        $partialStub = {
            param([string] $SchemaId)
            if ($SchemaId -eq 'builtin:slo') { return $null }
            return [pscustomobject]@{
                description = "ok"
                properties  = [pscustomobject]@{ x = @{ type = 'string' } }
            }
        }
        $inputs = New-TempInputsFile -Ids @('builtin:management-zones','builtin:slo')
        $out    = New-TempOutputPath
        $seed = @'
{
  "$schema": "./schema.json",
  "version": "1.0",
  "schemas": [
    {
      "id": "builtin:management-zones",
      "family": "topology",
      "displayName": "Management Zone",
      "scope": "environment",
      "summary": "Stale curated summary.",
      "commonParameters": ["zoneName"]
    },
    {
      "id": "builtin:slo",
      "family": "alerting",
      "displayName": "Service Level Objective",
      "scope": "environment",
      "summary": "Pre-existing curated SLO summary that must survive an unresolvable refresh.",
      "commonParameters": ["sloName","targetPct","warningPct"],
      "liveFields": ["enabled","name","target","warning"]
    }
  ]
}
'@
        [System.IO.File]::WriteAllText($out, $seed, [System.Text.UTF8Encoding]::new($false))
        try {
            & $script:RefreshScript -InputsPath $inputs -OutputPath $out -FetchSchemaScript $partialStub *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $parsed = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            @($parsed.schemas).Count | Should -Be 2

            # The resolvable entry has refreshed summary + liveFields.
            $mz = $parsed.schemas | Where-Object { $_.id -eq 'builtin:management-zones' }
            $mz.family             | Should -Be 'topology'
            $mz.summary            | Should -Be 'ok'   # refreshed from the stub

            # The UNresolvable entry survives byte-for-byte from the seed.
            $slo = $parsed.schemas | Where-Object { $_.id -eq 'builtin:slo' }
            $slo.family                                    | Should -Be 'alerting'
            $slo.displayName                               | Should -Be 'Service Level Objective'
            $slo.summary                                   | Should -Be 'Pre-existing curated SLO summary that must survive an unresolvable refresh.'
            @($slo.commonParameters) -join ','             | Should -Be 'sloName,targetPct,warningPct'
            @($slo.liveFields)       -join ','             | Should -Be 'enabled,name,target,warning'

            # No literal [null] / null entries in arrays anywhere in the file.
            $body = [System.IO.File]::ReadAllText($out)
            $body | Should -Not -Match '\[null\]'
            $body | Should -Not -Match '"liveFields":\s*null'
        } finally {
            Remove-Item -LiteralPath $inputs -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out    -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Sync-ConfigCatalog.ps1' {
    It '-Check passes against the committed modules/configs/' {
        & (Join-Path $script:MonacoDir 'Sync-ConfigCatalog.ps1') -Check *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Invoke-MonacoDelete.ps1 rejection paths' {
    It 'refuses without -Confirm' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/keep.txt' = 'x'; 'custom-beta/keep.txt' = 'x'
        }
        try {
            # Mandatory -Confirm:switch fails parameter binding when omitted;
            # we assert the failure surfaces as an exception.
            { & (Join-Path $script:MonacoDir 'Invoke-MonacoDelete.ps1') `
                -Path $root -Environment dev `
                -DeleteFile (Join-Path $root 'nonexistent.yaml') } | Should -Throw
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }

    It 'refuses on a missing deletefile' {
        $root = New-TempWorkspace -ManifestBody $script:MinimalManifest -ProjectFiles @{
            'alpha/keep.txt' = 'x'; 'custom-beta/keep.txt' = 'x'
        }
        try {
            { & (Join-Path $script:MonacoDir 'Invoke-MonacoDelete.ps1') `
                -Path $root -Environment dev `
                -DeleteFile (Join-Path $root 'nonexistent.yaml') -Confirm } |
                Should -Throw -ExpectedMessage '*does not exist*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}
