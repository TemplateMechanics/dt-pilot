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

Describe 'Monaco wrapper paths (post-shim-removal invariant)' {
    # The compatibility shims at scripts/Invoke-Monaco*.ps1 etc. were
    # removed in chore/remove-monaco-shims (issue #11). This Describe
    # block locks in the inverse invariant: the Monaco wrappers MUST live
    # under scripts/monaco/, and the legacy shim paths MUST NOT exist.
    BeforeAll {
        $script:MonacoWrapperNames = @(
            'Get-MonacoVersion.ps1','Initialize-MonacoWorkspace.ps1','Invoke-MonacoDelete.ps1',
            'Invoke-MonacoDeploy.ps1','Invoke-MonacoDownload.ps1','Invoke-MonacoDryRun.ps1',
            'Invoke-MonacoGenerate.ps1','Sync-ConfigCatalog.ps1','Test-MonacoManifest.ps1','Validate-Monaco.ps1'
        )
    }

    It 'every Monaco wrapper lives under scripts/monaco/' {
        foreach ($name in $script:MonacoWrapperNames) {
            $target = Join-Path $script:MonacoDir $name
            (Test-Path -LiteralPath $target -PathType Leaf) | Should -BeTrue -Because "$name must live at scripts/monaco/$name"
        }
    }

    It 'no legacy shim files remain at scripts/ root' {
        foreach ($name in $script:MonacoWrapperNames) {
            $legacy = Join-Path $script:ScriptDir $name
            (Test-Path -LiteralPath $legacy -PathType Leaf) | Should -BeFalse -Because "legacy shim scripts/$name must NOT exist after issue #11"
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
            # would have escaped them to the JSON unicode-escape form
            # '<' / '>'. The assertions below lock in the
            # strict-serializer behavior: the raw brackets MUST be
            # present, and the '<' escaped form MUST NOT be. If
            # the second assertion ever fires, a ConvertTo-Json call
            # snuck back into the JSON serialization path.
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
        # Regression test: a brand-new schema ID added to schemas.txt
        # that the cron cannot resolve must produce a placeholder
        # catalog entry (family: misc, summary TODO, liveFields: [])
        # rather than disappearing. Without the placeholder, the
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
        # Regression test for the Format-CatalogJson null-handling
        # path: existing catalog entries authored before liveFields
        # existed don't have that key. When the refresh re-emits such
        # an entry (because the schema was unresolvable upstream),
        # the formatter must coerce the missing array to [] instead
        # of serializing as [null]. Asserts both the parsed shape
        # AND a regex against the raw bytes for '\[null\]'.
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

# ======================================================================
# Terraform backend (Design 003)
# ======================================================================

Describe 'Terraform backend (Design 003)' {
    BeforeAll {
        $script:TerraformDir = Join-Path $script:ScriptDir 'terraform'
        . (Join-Path $script:TerraformDir '_Common.ps1')

        function New-TempTfWorkspace {
            param([hashtable] $Files)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tf-" + [System.Guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $root -Force
            if ($Files) {
                foreach ($rel in $Files.Keys) {
                    $full = Join-Path $root $rel
                    $dir  = Split-Path -Parent $full
                    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
                    Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8
                }
            }
            return $root
        }

        # Pester scopes functions defined in a Context's BeforeAll to that
        # Context only; defining here at the Describe scope makes them
        # visible to every It block under any Context.
        function New-TfPlanArtifacts {
            param(
                [string] $WorkingDir,
                [string] $Environment,
                [string] $Schema = 'dt-pilot.tfplan/v1',
                [int]    $ExitCode = 0,
                [string] $CreatedAtUtc,
                [string] $WorkspaceHash,
                [switch] $SkipBinary
            )
            if (-not $CreatedAtUtc)  { $CreatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o') }
            if (-not $WorkspaceHash) { $WorkspaceHash = Get-TerraformWorkspaceHash -WorkingDir $WorkingDir }
            $planRel = 'tfplan'
            $planBin = Join-Path $WorkingDir $planRel
            if (-not $SkipBinary) {
                Set-Content -LiteralPath $planBin -Value 'fake binary plan' -Encoding utf8
            }
            $envelope = [ordered]@{
                schema           = $Schema
                createdAtUtc     = $CreatedAtUtc
                environment      = $Environment
                workingDir       = $WorkingDir
                workspaceHash    = $WorkspaceHash
                terraformVersion = '1.10.0'
                terraformExe     = $script:FakeTfExe
                exitCode         = $ExitCode
                summary          = [ordered]@{ wouldAdd = 0; wouldChange = 0; wouldDestroy = 0 }
                planBinary       = $planRel
                planJsonSummary  = ''
            }
            $envPath = Join-Path $WorkingDir 'dryrun.json'
            $dir = Split-Path -Parent $envPath
            if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            $envelope | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $envPath -Encoding utf8
            return @{ Envelope = $envPath; Binary = $planBin }
        }

        # Fake terraform binary path -- _Common.Resolve-TerraformExe checks
        # the file exists but the wrappers' rejection paths all fire before
        # we'd actually launch it. Re-use the Pester test file itself,
        # which definitely exists.
        $script:FakeTfExe = (Get-Item -LiteralPath $PSCommandPath).FullName
    }

    Context '_Common.Resolve-TerraformWorkingDir' {
        It 'returns the resolved path when the dir contains .tf files' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                (Resolve-TerraformWorkingDir -Path $root) | Should -Be (Resolve-Path -LiteralPath $root).ProviderPath
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'throws on a directory with no .tf files' {
            $root = New-TempTfWorkspace -Files @{ 'readme.md' = 'no terraform here' }
            try {
                { Resolve-TerraformWorkingDir -Path $root } | Should -Throw -ExpectedMessage '*No .tf files*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'throws when -Path is a file instead of a directory' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                { Resolve-TerraformWorkingDir -Path (Join-Path $root 'main.tf') } | Should -Throw -ExpectedMessage '*must be a directory*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }

    Context '_Common.Get-TerraformProviderEnv' {
        It 'returns DT_ENVIRONMENT -> DT_ENV_URL and DT_PLATFORM_TOKEN -> DT_API_TOKEN' {
            # Save and restore so we don't pollute the test runner env.
            $origs = @{}
            foreach ($n in @('DT_ENVIRONMENT','DT_PLATFORM_TOKEN','OAUTH_CLIENT_ID','OAUTH_CLIENT_SECRET','DT_ACCOUNT_ID')) {
                $origs[$n] = [System.Environment]::GetEnvironmentVariable($n)
            }
            try {
                $env:DT_ENVIRONMENT    = 'https://example.test.dynatrace.com'
                $env:DT_PLATFORM_TOKEN = 'dt-pilot-test-platform-token'
                $extra = Get-TerraformProviderEnv
                $extra['DT_ENV_URL']   | Should -Be 'https://example.test.dynatrace.com'
                $extra['DT_API_TOKEN'] | Should -Be 'dt-pilot-test-platform-token'
            } finally {
                foreach ($k in $origs.Keys) {
                    if ($null -eq $origs[$k]) {
                        Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue
                    } else {
                        Set-Item -Path "env:$k" -Value $origs[$k]
                    }
                }
            }
        }

        It 'returns OAUTH_CLIENT_ID/SECRET -> DT_CLIENT_ID/SECRET' {
            $origs = @{}
            foreach ($n in @('OAUTH_CLIENT_ID','OAUTH_CLIENT_SECRET','DT_ENVIRONMENT','DT_PLATFORM_TOKEN','DT_ACCOUNT_ID')) {
                $origs[$n] = [System.Environment]::GetEnvironmentVariable($n)
            }
            try {
                $env:OAUTH_CLIENT_ID     = 'tf-test-client-id'
                $env:OAUTH_CLIENT_SECRET = 'tf-test-client-secret'
                $extra = Get-TerraformProviderEnv
                $extra['DT_CLIENT_ID']     | Should -Be 'tf-test-client-id'
                $extra['DT_CLIENT_SECRET'] | Should -Be 'tf-test-client-secret'
            } finally {
                foreach ($k in $origs.Keys) {
                    if ($null -eq $origs[$k]) {
                        Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue
                    } else {
                        Set-Item -Path "env:$k" -Value $origs[$k]
                    }
                }
            }
        }

        It 'does NOT mutate the parent process env (returns dict only)' {
            $origDtUrl = [System.Environment]::GetEnvironmentVariable('DT_ENV_URL')
            try {
                $env:DT_ENV_URL     = $null
                $env:DT_ENVIRONMENT = 'https://parent-shell-test.dynatrace.com'
                $null = Get-TerraformProviderEnv
                # The function returned a dict; it must NOT have set $env:DT_ENV_URL.
                $env:DT_ENV_URL | Should -BeNullOrEmpty
            } finally {
                if ($null -eq $origDtUrl) { Remove-Item -Path 'env:DT_ENV_URL' -ErrorAction SilentlyContinue }
                else                       { Set-Item   -Path 'env:DT_ENV_URL' -Value $origDtUrl }
            }
        }
    }

    Context '_Common.Get-TerraformWorkspaceHash' {
        It 'changes when a .tf file changes' {
            $root = New-TempTfWorkspace -Files @{
                'main.tf'     = 'resource "null_resource" "x" {}'
                'variables.tf'= 'variable "y" { type = string }'
            }
            try {
                $before = Get-TerraformWorkspaceHash -WorkingDir $root
                Set-Content -LiteralPath (Join-Path $root 'main.tf') -Value 'resource "null_resource" "z" {}' -Encoding utf8
                $after  = Get-TerraformWorkspaceHash -WorkingDir $root
                $before | Should -Not -Be $after
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'is stable across re-reads when nothing changes' {
            $root = New-TempTfWorkspace -Files @{
                'main.tf'      = 'resource "null_resource" "x" {}'
                'dev.tfvars'   = 'foo = "bar"'
            }
            try {
                (Get-TerraformWorkspaceHash -WorkingDir $root) | Should -Be (Get-TerraformWorkspaceHash -WorkingDir $root)
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'ignores files under .terraform/ (provider cache)' {
            $root = New-TempTfWorkspace -Files @{
                'main.tf' = 'resource "null_resource" "x" {}'
                '.terraform/providers/registry/example.tf' = 'cached provider data; not source'
            }
            try {
                $hash = Get-TerraformWorkspaceHash -WorkingDir $root
                # If .terraform/ files were included, changing one would
                # change the hash; the cache changing should NOT.
                Set-Content -LiteralPath (Join-Path $root '.terraform/providers/registry/example.tf') -Value 'cached provider data CHANGED' -Encoding utf8
                $hash2 = Get-TerraformWorkspaceHash -WorkingDir $root
                $hash | Should -Be $hash2
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'changes when .terraform.lock.hcl changes (provider version drift)' {
            # Pass-7 fix: the lockfile pattern was 'terraform.lock.hcl'
            # (no leading dot) so it never matched the real Terraform
            # file name '.terraform.lock.hcl' and a provider version pin
            # change between plan and apply slipped past the gate. This
            # test asserts the lockfile is now part of the hash.
            $root = New-TempTfWorkspace -Files @{
                'main.tf'              = 'resource "null_resource" "x" {}'
                '.terraform.lock.hcl'  = 'provider "registry.terraform.io/dynatrace-oss/dynatrace" { version = "1.78.0" }'
            }
            try {
                $before = Get-TerraformWorkspaceHash -WorkingDir $root
                Set-Content -LiteralPath (Join-Path $root '.terraform.lock.hcl') -Value 'provider "registry.terraform.io/dynatrace-oss/dynatrace" { version = "1.79.0" }' -Encoding utf8
                $after  = Get-TerraformWorkspaceHash -WorkingDir $root
                $before | Should -Not -Be $after
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }

    Context '_Common.Read-TfPlanMetadata' {
        It 'rejects a wrong-schema artifact' {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfbad-" + [System.Guid]::NewGuid().ToString('N') + ".json")
            '{"schema":"other/v9","environment":"dev","exitCode":0}' | Set-Content -LiteralPath $tmp -Encoding utf8
            try {
                { Read-TfPlanMetadata -PlanFile $tmp } | Should -Throw -ExpectedMessage '*not a dt-pilot tfplan/v1*'
            } finally {
                Remove-Item -LiteralPath $tmp -Force
            }
        }

        It 'rejects a failed plan (exitCode != 0)' {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfbad-" + [System.Guid]::NewGuid().ToString('N') + ".json")
            '{"schema":"dt-pilot.tfplan/v1","environment":"dev","exitCode":7}' | Set-Content -LiteralPath $tmp -Encoding utf8
            try {
                { Read-TfPlanMetadata -PlanFile $tmp } | Should -Throw -ExpectedMessage '*non-zero exit*'
            } finally {
                Remove-Item -LiteralPath $tmp -Force
            }
        }

        It 'rejects a missing file' {
            $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfgone-" + [System.Guid]::NewGuid().ToString('N') + ".json")
            { Read-TfPlanMetadata -PlanFile $missing } | Should -Throw -ExpectedMessage '*does not exist*'
        }

        It "rejects an envelope missing the 'exitCode' field with a distinct error message" {
            # Pass-8 fix: previously, a missing exitCode field compared
            # $null -ne 0 -> $true and threw "non-zero exit code ()",
            # confusing the operator who can't tell whether the plan
            # failed or the envelope was malformed. Now those are two
            # explicitly different error paths.
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfnoexit-" + [System.Guid]::NewGuid().ToString('N') + ".json")
            '{"schema":"dt-pilot.tfplan/v1","environment":"dev"}' | Set-Content -LiteralPath $tmp -Encoding utf8
            try {
                { Read-TfPlanMetadata -PlanFile $tmp } | Should -Throw -ExpectedMessage "*missing the 'exitCode' field*"
            } finally {
                Remove-Item -LiteralPath $tmp -Force
            }
        }

        It "rejects an envelope whose 'exitCode' is not an integer" {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfbadexit-" + [System.Guid]::NewGuid().ToString('N') + ".json")
            '{"schema":"dt-pilot.tfplan/v1","environment":"dev","exitCode":"zero"}' | Set-Content -LiteralPath $tmp -Encoding utf8
            try {
                { Read-TfPlanMetadata -PlanFile $tmp } | Should -Throw -ExpectedMessage "*'exitCode' is not an integer*"
            } finally {
                Remove-Item -LiteralPath $tmp -Force
            }
        }
    }

    Context 'Invoke-TerraformApply.ps1 rejection paths' {
        # Uses New-TfPlanArtifacts defined in the Describe-level BeforeAll
        # so the function is visible to every It block here.

        It 'rejects a missing PlanFile' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile (Join-Path $root 'does-not-exist.json') `
                    -TerraformExe $script:FakeTfExe } | Should -Throw -ExpectedMessage '*does not exist*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'rejects an environment mismatch' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'staging'
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage "*environment 'staging'*"
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'rejects a stale envelope (older than -MaxAgeMinutes)' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $stale = (Get-Date).AddMinutes(-90).ToUniversalTime().ToString('o')
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev' -CreatedAtUtc $stale
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -MaxAgeMinutes 30 -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage '*minute(s) old*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'rejects a workspace edit after plan (workspaceHash mismatch)' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev'
                # Edit AFTER the envelope captured the hash.
                Set-Content -LiteralPath (Join-Path $root 'main.tf') -Value 'resource "null_resource" "edited" {}' -Encoding utf8
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage '*workspaceHash mismatch*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'rejects when the binary plan file no longer exists' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev'
                Remove-Item -LiteralPath $art.Binary -Force
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage '*Binary plan file*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'rejects a workingDir mismatch (envelope produced for a different workspace path)' {
            # Two same-content workspaces in different temp dirs. Same hash,
            # different paths -- the workingDir gate should fire even when
            # the envelope's recorded path doesn't exist on this machine,
            # which is the silent-skip Copilot flagged in pass 4.
            $rootA = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            $rootB = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $hash = Get-TerraformWorkspaceHash -WorkingDir $rootA
                # Envelope produced "for" rootA, applied against rootB. We
                # pass workspaceHash explicitly so the hash gate matches,
                # forcing the workingDir gate to be the one that fires.
                $art = New-TfPlanArtifacts -WorkingDir $rootA -Environment 'dev' -WorkspaceHash $hash
                # Now write the plan binary into rootB too so the binary
                # check doesn't beat us to the throw.
                Set-Content -LiteralPath (Join-Path $rootB 'tfplan') -Value 'fake binary plan' -Encoding utf8
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $rootB -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage "*workingDir*"
            } finally {
                Remove-Item -LiteralPath $rootA -Recurse -Force
                Remove-Item -LiteralPath $rootB -Recurse -Force
            }
        }

        It "rejects an envelope missing the 'createdAtUtc' field" {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev'
                $obj = Get-Content -LiteralPath $art.Envelope -Raw | ConvertFrom-Json
                $obj.PSObject.Properties.Remove('createdAtUtc')
                $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $art.Envelope -Encoding utf8
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage "*'createdAtUtc' field*"
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It "rejects an envelope whose 'createdAtUtc' is not a parseable timestamp" {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev'
                $obj = Get-Content -LiteralPath $art.Envelope -Raw | ConvertFrom-Json
                $obj.createdAtUtc = 'not-a-real-timestamp'
                $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $art.Envelope -Encoding utf8
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage "*not a parseable ISO-8601 timestamp*"
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It "rejects an envelope missing the 'planBinary' field" {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev'
                # Strip planBinary -- simulates a hand-edited envelope.
                $obj = Get-Content -LiteralPath $art.Envelope -Raw | ConvertFrom-Json
                $obj.PSObject.Properties.Remove('planBinary')
                $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $art.Envelope -Encoding utf8
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage "*'planBinary' field*"
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It "rejects an envelope whose 'planBinary' is an absolute path outside the workdir" {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            $elsewhere = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-otherwhere-" + [System.Guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $elsewhere
            $outsidePlan = Join-Path $elsewhere 'tfplan'
            Set-Content -LiteralPath $outsidePlan -Value 'fake binary plan' -Encoding utf8
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev'
                $obj = Get-Content -LiteralPath $art.Envelope -Raw | ConvertFrom-Json
                # Rooted path that exists but is NOT under $root. Must
                # be rejected even though the file is there.
                $obj.planBinary = $outsidePlan
                $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $art.Envelope -Encoding utf8
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage '*absolute path outside the working directory*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
                Remove-Item -LiteralPath $elsewhere -Recurse -Force
            }
        }

        It "rejects an envelope whose 'planBinary' contains a path traversal" {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev'
                # Inject '..' into planBinary.
                $obj = Get-Content -LiteralPath $art.Envelope -Raw | ConvertFrom-Json
                $obj.planBinary = '../../etc/passwd'
                $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $art.Envelope -Encoding utf8
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage '*path traversal*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It "rejects an envelope missing the 'workingDir' field" {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                $art = New-TfPlanArtifacts -WorkingDir $root -Environment 'dev'
                # Strip workingDir from the envelope -- simulates a hand-
                # edited or malformed artifact. The gate must refuse rather
                # than silently skip the path check.
                $obj = Get-Content -LiteralPath $art.Envelope -Raw | ConvertFrom-Json
                $obj.PSObject.Properties.Remove('workingDir')
                $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $art.Envelope -Encoding utf8
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformApply.ps1') `
                    -Path $root -Environment dev `
                    -PlanFile $art.Envelope -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage "*'workingDir' field*"
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }

    Context 'Invoke-TerraformDestroy.ps1 rejection paths' {
        It 'refuses without -Confirm' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                # No Mandatory attribute: the runtime check fires because
                # $Confirm defaults to $false when the switch is omitted.
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformDestroy.ps1') `
                    -Path $root -Environment dev -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage '*Refusing to destroy*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }

        It 'refuses with explicit -Confirm:$false' {
            $root = New-TempTfWorkspace -Files @{ 'main.tf' = 'resource "null_resource" "x" {}' }
            try {
                # The previously-redundant Mandatory + runtime gate could
                # not distinguish this case from "switch omitted". Now the
                # runtime check is the single source of truth and rejects
                # both.
                { & (Join-Path $script:TerraformDir 'Invoke-TerraformDestroy.ps1') `
                    -Path $root -Environment dev -Confirm:$false -TerraformExe $script:FakeTfExe } |
                    Should -Throw -ExpectedMessage '*Refusing to destroy*'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }
}

Describe 'Test-McpConfigSecrets.ps1 extended to .tf scanning' {
    It 'flags an inline url = "https://*.live.dynatrace.com/" in a .tf file' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfsec-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpDir
        $bad = @'
provider "dynatrace" {
  url       = "https://abc12345.live.dynatrace.com"
  api_token = "dt0c01.ABCDEFGHIJKLMNOPQRSTUVWX.YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY"
}
'@
        Set-Content -LiteralPath (Join-Path $tmpDir 'providers.tf') -Value $bad -Encoding utf8

        # Override $PSScriptRoot via string substitution so the scanner
        # treats $tmpDir as the repo root.
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

    It "does NOT flag a non-provider 'url = ...' literal (webhook / HTTP data source)" {
        # Pass-6 false-positive that motivated dropping 'url' from the
        # inline-arg regex. A webhook URL pointing at a non-Dynatrace
        # endpoint inside a non-provider block must NOT block the commit
        # -- those are legitimate.
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfwebhook-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpDir
        $good = @'
resource "dynatrace_notification" "webhook" {
  name             = "ops-webhook"
  alerting_profile = dynatrace_alerting.x.id
  webhook {
    url = "https://hooks.example.com/dt-pilot-ops"
  }
}
'@
        Set-Content -LiteralPath (Join-Path $tmpDir 'main.tf') -Value $good -Encoding utf8

        $scannerSrc = Get-Content -LiteralPath (Join-Path $script:ScriptDir 'Test-McpConfigSecrets.ps1') -Raw
        $copy = Join-Path $tmpDir 'scan.ps1'
        $injected = $scannerSrc.Replace('$PSScriptRoot', "'$tmpDir/scripts'")
        Set-Content -LiteralPath $copy -Value $injected -Encoding utf8
        $null = New-Item -ItemType Directory -Path (Join-Path $tmpDir 'scripts')

        try {
            & pwsh -NoProfile -File $copy *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force
        }
    }

    It "STILL flags a hardcoded *.live.dynatrace.com url even without the inline-arg rule" {
        # Even though 'url' is no longer in $tfArgRegex, the live-tenant
        # URL regex must still catch a hardcoded Dynatrace tenant URL.
        # This is the load-bearing leak case.
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tftenant-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpDir
        $bad = @'
provider "dynatrace" {
  url = "https://xyz98765.live.dynatrace.com"
}
'@
        Set-Content -LiteralPath (Join-Path $tmpDir 'providers.tf') -Value $bad -Encoding utf8

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

    It 'does NOT flag a .tf file that reads everything via var. references' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfok-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpDir
        $good = @'
provider "dynatrace" {}

resource "dynatrace_management_zone_v2" "x" {
  name = var.zone_name
}
'@
        Set-Content -LiteralPath (Join-Path $tmpDir 'main.tf') -Value $good -Encoding utf8

        $scannerSrc = Get-Content -LiteralPath (Join-Path $script:ScriptDir 'Test-McpConfigSecrets.ps1') -Raw
        $copy = Join-Path $tmpDir 'scan.ps1'
        $injected = $scannerSrc.Replace('$PSScriptRoot', "'$tmpDir/scripts'")
        Set-Content -LiteralPath $copy -Value $injected -Encoding utf8
        $null = New-Item -ItemType Directory -Path (Join-Path $tmpDir 'scripts')

        try {
            & pwsh -NoProfile -File $copy *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force
        }
    }
}

Describe 'Test-McpConfigSecrets.ps1 extended to .tfvars scanning' {
    It 'flags an inline api_token = "dt0c01...." in a .tfvars file' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfvars-bad-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpDir
        # This is the "I'll just put it in dev.tfvars for now" mistake
        # Copilot flagged in pass 5. Same patterns the scanner runs on
        # .tf files must catch it here too.
        $bad = @'
api_token = "dt0c01.ABCDEFGHIJKLMNOPQRSTUVWX.YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY"
dt_env_url = "https://abc12345.live.dynatrace.com"
'@
        Set-Content -LiteralPath (Join-Path $tmpDir 'dev.tfvars') -Value $bad -Encoding utf8

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

    It "flags an inline credential field in a .tfvars.json file (JSON syntax, not HCL)" {
        # Pass-7 fix: the HCL inline-arg regex matches `key = "value"`
        # so JSON tfvars (`"key": "value"`) bypassed it. The scanner
        # now parses .tfvars.json files separately and checks the same
        # credential field names.
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfvars-json-bad-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpDir
        $bad = @'
{
  "client_secret": "abc-definitely-a-real-secret-not-a-placeholder",
  "owner": "platform@example.test"
}
'@
        Set-Content -LiteralPath (Join-Path $tmpDir 'dev.tfvars.json') -Value $bad -Encoding utf8

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

    It 'does NOT flag a .tfvars file that only contains harmless values' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-pilot-tfvars-ok-" + [System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpDir
        $good = @'
zone_name  = "Baseline-Dev"
target_pct = 99.5
owner      = "platform@example.test"
'@
        Set-Content -LiteralPath (Join-Path $tmpDir 'dev.tfvars') -Value $good -Encoding utf8

        $scannerSrc = Get-Content -LiteralPath (Join-Path $script:ScriptDir 'Test-McpConfigSecrets.ps1') -Raw
        $copy = Join-Path $tmpDir 'scan.ps1'
        $injected = $scannerSrc.Replace('$PSScriptRoot', "'$tmpDir/scripts'")
        Set-Content -LiteralPath $copy -Value $injected -Encoding utf8
        $null = New-Item -ItemType Directory -Path (Join-Path $tmpDir 'scripts')

        try {
            & pwsh -NoProfile -File $copy *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force
        }
    }
}

Describe 'Sync-TerraformCatalog.ps1' {
    It '-Check passes against the committed modules/terraform/configs/' {
        & (Join-Path $script:ScriptDir 'terraform/Sync-TerraformCatalog.ps1') -Check *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'renders the providerArgument LHS when the catalog specifies one' {
        # zone_name -> name for dynatrace_management_zone_v2 is the
        # canonical case Copilot called out in pass 5. The generated
        # scaffold must emit `name = var.zone_name`, not
        # `zone_name = var.zone_name`, so copying it verbatim is valid HCL.
        $mzScaffold = Join-Path $script:RepoRoot 'modules/terraform/configs/topology/management_zone_v2/main.tf.example'
        $mzScaffold | Should -Exist
        $content = Get-Content -LiteralPath $mzScaffold -Raw
        $content | Should -Match 'name\s*=\s*var\.zone_name'
        # And NOT the old fall-back shape.
        $content | Should -Not -Match 'zone_name\s*=\s*var\.zone_name'
    }

    It 'falls back to var-name LHS with a TODO marker when no providerArgument is set' {
        # SLO's management_zone_id intentionally has no providerArgument
        # (it feeds the filter string, not a top-level arg). The scaffold
        # must keep the fall-back shape with the TODO so the operator
        # knows to move it into the right place before applying.
        $sloScaffold = Join-Path $script:RepoRoot 'modules/terraform/configs/alerting/slo_v2/main.tf.example'
        $sloScaffold | Should -Exist
        $content = Get-Content -LiteralPath $sloScaffold -Raw
        $content | Should -Match 'management_zone_id\s*=\s*var\.management_zone_id\s*#\s*TODO'
    }
}
