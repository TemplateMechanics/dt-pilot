<#
.SYNOPSIS
    Run `terraform plan` against a single environment and persist the
    result as a reviewable dt-pilot.tfplan/v1 plan envelope alongside
    the binary plan file.

.DESCRIPTION
    Produces TWO artifacts that travel together:
      1. The binary plan file (-Out, default 'tfplan') that
         `terraform apply <planfile>` consumes directly.
      2. The dt-pilot envelope JSON (default 'dryrun/<env>.json') that
         records: environment, working directory, workspace hash,
         Terraform version + binary path, exit code, add/change/destroy
         summary, the binary plan path, and a `terraform show -json`
         summary string.

    Invoke-TerraformApply.ps1 requires the envelope via -PlanFile (and
    re-verifies the binary plan exists at the path the envelope names).
    Hand-edited or stale artifacts are rejected.

.PARAMETER Path
    Directory containing the .tf files.

.PARAMETER Environment
    Required. The environment name (also used to construct the default
    envelope path: dryrun/<env>.json).

.PARAMETER Out
    Path to the binary plan file Terraform writes. Default 'tfplan'
    inside the working directory.

.PARAMETER EnvelopeOut
    Path to the JSON envelope. Default 'dryrun/<env>.json' relative to
    the current working directory.

.PARAMETER VarFile
    Optional -var-file argument (e.g. 'envs/dev.tfvars'). Path is
    relative to the Terraform working directory.

.PARAMETER TerraformExe
    Override the Terraform executable lookup.

.EXAMPLE
    ./scripts/terraform/Invoke-TerraformPlan.ps1 -Path examples/terraform-baseline -Environment dev -VarFile envs/dev.tfvars

.EXAMPLE
    ./scripts/terraform/Invoke-TerraformPlan.ps1 -Path . -Environment prod -VarFile envs/prod.tfvars -Out prod.tfplan
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Environment,
    [string] $Out,
    [string] $EnvelopeOut,
    [string] $VarFile,
    [string] $TerraformExe
)

. "$PSScriptRoot/_Common.ps1"

$exe     = Resolve-TerraformExe -TerraformExe $TerraformExe
$workDir = Resolve-TerraformWorkingDir -Path $Path

if (-not $Out)         { $Out         = 'tfplan' }
if (-not $EnvelopeOut) { $EnvelopeOut = Join-Path 'dryrun' ("{0}.json" -f $Environment) }

# Translate dt-pilot canonical env vars to provider-specific names. The
# resulting hashtable is passed to Invoke-TerraformCommand -ExtraEnv so
# the child terraform process sees the provider-specific names but the
# parent PowerShell session's $env: is NOT mutated.
$providerEnv = Get-TerraformProviderEnv

$args = @('plan','-input=false','-out',$Out)
if ($VarFile) {
    $args += @('-var-file', $VarFile)
}

# Validate $Out shape BEFORE invoking terraform (the planBinary
# computation farther down also does this for the envelope; doing it
# up front means malformed values fail fast with a clear message
# instead of after a useless terraform invocation). Same rules:
# rooted -Out must resolve under $workDir; relative -Out must not
# contain '..'.
if ([System.IO.Path]::IsPathRooted($Out)) {
    $isWin = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $IsWindows } else { [System.Environment]::OSVersion.Platform -eq 'Win32NT' }
    $outPathCmp = if ($isWin) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $outRootedFull = [System.IO.Path]::GetFullPath($Out)
    $outWorkFull   = [System.IO.Path]::GetFullPath($workDir).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $outRootedFull.StartsWith($outWorkFull, $outPathCmp)) {
        throw "-Out '$Out' resolves to a path outside the working directory '$workDir'. The binary plan must live inside the workspace it was produced for; pass a workdir-relative -Out (e.g. 'tfplan' or 'plans/dev.tfplan') or omit -Out to use the default."
    }
} elseif ($Out -match '(^|[\\/])\.\.([\\/]|$)') {
    throw "-Out '$Out' contains a '..' traversal that would escape the working directory. Pass a path that stays under '$workDir'."
}

# Ensure the parent directory of $Out exists before invoking terraform.
# Advertised paths like `-Out plans/dev.tfplan` would otherwise fail
# with a filesystem error from terraform itself ("no such file or
# directory"). For relative $Out, resolve under $workDir (where the
# child terraform process runs); for rooted $Out the validation above
# confirmed it sits under $workDir, so its parent is also under workdir.
$planParentDir = if ([System.IO.Path]::IsPathRooted($Out)) {
    [System.IO.Path]::GetDirectoryName($Out)
} else {
    [System.IO.Path]::GetDirectoryName((Join-Path $workDir $Out))
}
if ($planParentDir -and -not (Test-Path -LiteralPath $planParentDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $planParentDir -Force
}

Write-Host "Plan: $workDir -> environment '$Environment' -> $Out"
$planResult = Invoke-TerraformCommand -TerraformExe $exe -Arguments $args -WorkingDirectory $workDir -CaptureOutput -ExtraEnv $providerEnv
if ($planResult.StdOut) { Write-Host $planResult.StdOut.TrimEnd() }
if ($planResult.StdErr) { Write-Host $planResult.StdErr.TrimEnd() }

# Even on failure, we still want to write the envelope so the reviewer
# can inspect why -- the deploy wrapper enforces exitCode == 0. On
# SUCCESS the envelope's planJsonSummary holds the (truncated)
# `terraform show -json` output. On FAILURE there is no binary plan to
# show, so capture the plan command's stdout / stderr into the same
# field instead -- otherwise the envelope just says "exit 1" with no
# clue why and the operator has to dig CI logs back out. The CI / chat
# transcript is the canonical source, but the artifact alone should be
# enough to diagnose the immediate failure.
$showJson    = ''
$wouldAdd    = 0
$wouldChange = 0
$wouldDestroy = 0
if ($planResult.ExitCode -eq 0) {
    $show = Invoke-TerraformCommand -TerraformExe $exe -Arguments @('show','-json',$Out) -WorkingDirectory $workDir -CaptureOutput
    if ($show.ExitCode -eq 0 -and $show.StdOut) {
        # Counts from the full JSON; same parsing logic as
        # Write-TfPlanMetadata so the envelope summary is accurate even
        # when the stored planJsonSummary is truncated.
        try {
            $parsed = $show.StdOut | ConvertFrom-Json
            if ($parsed.PSObject.Properties['resource_changes']) {
                foreach ($rc in @($parsed.resource_changes)) {
                    $actions = @($rc.change.actions)
                    if ($actions -contains 'create') { $wouldAdd     += 1 }
                    if ($actions -contains 'update') { $wouldChange  += 1 }
                    if ($actions -contains 'delete') { $wouldDestroy += 1 }
                }
            }
        } catch {
            # Leave counts at zero; reviewer reads the raw envelope.
        }
        $maxBytes = 64KB
        $raw = $show.StdOut
        if ([System.Text.Encoding]::UTF8.GetByteCount($raw) -gt $maxBytes) {
            # Truncate by BYTES, not characters. The previous version
            # used $raw.Substring(0, $maxBytes), but a single .NET char
            # can encode to up to 4 UTF-8 bytes; for terraform's JSON
            # that's mostly ASCII so the difference was small but real.
            #
            # Algorithm: encode the full string, choose an initial cutoff
            # at $maxBytes (meaning bytes [0..$cutoff-1] are included,
            # [$cutoff..end] excluded), then walk the cutoff BACKWARD
            # until $bytes[$cutoff] is at a UTF-8 character boundary
            # (i.e. NOT a continuation byte) -- because if the FIRST
            # EXCLUDED byte is a continuation, we'd be cutting between a
            # multi-byte leader (included) and its continuation (excluded)
            # and the decoded prefix would have a partial codepoint at
            # the end. The check is on $bytes[$cutoff] (first excluded
            # byte), NOT $bytes[$cutoff-1] (last included byte): a
            # legitimate complete multi-byte char ENDS with a continuation
            # byte (e.g. "ä" is 0xC3 0xA4 where 0xA4 is a continuation
            # AND a valid end-of-character), so checking the last included
            # byte for "is continuation" would wrongly back up past
            # complete characters.
            #
            # Bit pattern reference: leading bytes are 0xxxxxxx (ASCII) /
            # 110xxxxx (2-byte) / 1110xxxx (3-byte) / 11110xxx (4-byte);
            # continuation bytes are 10xxxxxx (high two bits == 10, i.e.
            # (b & 0xC0) == 0x80). Worst case the loop decrements 3 times
            # (the maximum continuation-byte count for a 4-byte sequence).
            $bytes  = [System.Text.Encoding]::UTF8.GetBytes($raw)
            $cutoff = $maxBytes
            # Defensive bounds: $cutoff < $bytes.Length is guaranteed by
            # the GetByteCount > $maxBytes check above, but keep the
            # explicit guard for the cold-read reader.
            while ($cutoff -gt 0 -and $cutoff -lt $bytes.Length -and (($bytes[$cutoff] -band 0xC0) -eq 0x80)) {
                $cutoff--
            }
            $safePrefix = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $cutoff)
            $showJson = $safePrefix + "`n/* truncated -- full terraform show -json output exceeded 64 KiB; envelope summary counts came from the full payload */"
        } else {
            $showJson = $raw
        }
    }
} else {
    # Plan failed -- no binary plan to `terraform show`. Capture the
    # plan command's own stdout + stderr (truncated) into the envelope
    # so the artifact is diagnosable on its own. Same 64 KiB byte cap
    # as the success path; same UTF-8-safe truncation (here implemented
    # inline because the inputs are typically <1 KiB).
    $planMaxBytes = 64KB
    $stdoutText = if ($planResult.StdOut) { $planResult.StdOut } else { '' }
    $stderrText = if ($planResult.StdErr) { $planResult.StdErr } else { '' }
    $combined = "terraform plan exit $($planResult.ExitCode)`n--- stdout ---`n$stdoutText`n--- stderr ---`n$stderrText"
    if ([System.Text.Encoding]::UTF8.GetByteCount($combined) -gt $planMaxBytes) {
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($combined)
        $cutoff = $planMaxBytes
        while ($cutoff -gt 0 -and $cutoff -lt $bytes.Length -and (($bytes[$cutoff] -band 0xC0) -eq 0x80)) {
            $cutoff--
        }
        $showJson = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $cutoff) + "`n/* truncated -- combined plan stdout + stderr exceeded 64 KiB */"
    } else {
        $showJson = $combined
    }
}

$envelopePath = if ([System.IO.Path]::IsPathRooted($EnvelopeOut)) { $EnvelopeOut } else { (Join-Path (Get-Location).Path $EnvelopeOut) }

# Store planBinary as the workdir-relative path so the envelope is
# portable across checkouts / agents / docker mounts. The apply wrapper
# re-roots against the workdir it was invoked with. $Out has already
# been validated above (rooted -> must be under $workDir; relative ->
# no '..' traversal), so the only remaining work here is the relative-
# path conversion.
$planBinRelative = if ([System.IO.Path]::IsPathRooted($Out)) {
    [System.IO.Path]::GetRelativePath($workDir, $Out).Replace('\','/')
} else {
    $Out.Replace('\','/')
}

Write-TfPlanMetadata `
    -OutPath          $envelopePath `
    -WorkingDir       $workDir `
    -Environment      $Environment `
    -TerraformExe     $exe `
    -ExitCode         $planResult.ExitCode `
    -PlanBinaryPath   $planBinRelative `
    -PlanJsonSummary  $showJson `
    -WouldAdd         $wouldAdd `
    -WouldChange      $wouldChange `
    -WouldDestroy     $wouldDestroy

Write-Host "Plan envelope written: $envelopePath"

if ($planResult.ExitCode -ne 0) {
    Write-Host "Plan FAILED (exit $($planResult.ExitCode)). See raw output and the envelope's planJsonSummary." -ForegroundColor Red
    exit $planResult.ExitCode
}

$meta = Get-Content -LiteralPath $envelopePath -Raw | ConvertFrom-Json
Write-Host ("Summary: wouldAdd={0}, wouldChange={1}, wouldDestroy={2}" -f `
    $meta.summary.wouldAdd, $meta.summary.wouldChange, $meta.summary.wouldDestroy) -ForegroundColor Green
exit 0
