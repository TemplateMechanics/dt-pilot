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
            # Console.Error API, Write-Error, or a redirection operator
            # (`1>&2`, `2>&1` paired with -ErrorAction Stop, etc.).
            # Source-text matching is intentionally permissive; behavior
            # is what matters.
            $body | Should -Match '(?i)(Console.*Error.*WriteLine|Write-Error|1>&2|2>&1)' `
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
