# Config.psm1
# Loads and validates settings.json for the Curo PDF Protector.
# Never reads from %APPDATA% or user profile.

$script:CurrentSchemaVersion = 1

function Get-CuroConfigPath {
    <#
    .SYNOPSIS
        Resolve which settings.json to load. Probe order:
          1. $env:CURO_SETTINGS_PATH  (explicit override; test/CI seam)
          2. %LOCALAPPDATA%\CuroPDFProtect\settings.json  (per-user launcher /
             portable-exe setup)
          3. %ProgramData%\CuroPDFProtect\settings.json   (machine-wide install)
          4. <tool root>\config\settings.json  (legacy launcher location, kept
             so folder-based deployments set up before the move keep working)
        Returns the first that exists, else the machine-wide path so "not found"
        errors name what setup.ps1/install.ps1 create. An explicit
        CURO_SETTINGS_PATH is always honoured even if missing, so the error
        names what the operator pointed at.
    .NOTES
        Per-user beats machine-wide on purpose. The portable exe extracts to a
        payload-hash folder that CHANGES with every new build, so config kept
        under the tool root is orphaned by an update and the whole team is told
        "not set up" - the per-user path is stable across versions. It also
        breaks the trap where a PC that once ran Install mode kept loading a
        stale ProgramData config (pointing at a Program Files qpdf that
        uninstall.ps1 had deleted) that re-running --setup could never repair.
    #>
    [CmdletBinding()]
    param()
    if ($env:CURO_SETTINGS_PATH) { return $env:CURO_SETTINGS_PATH }
    $user = Join-Path $env:LOCALAPPDATA 'CuroPDFProtect\settings.json'
    if (Test-Path -LiteralPath $user) { return $user }
    $machine = Join-Path $env:ProgramData 'CuroPDFProtect\settings.json'
    if (Test-Path -LiteralPath $machine) { return $machine }
    $toolRoot = Split-Path -Parent $PSScriptRoot   # src\ -> install/repo root
    $launcher = Join-Path (Join-Path $toolRoot 'config') 'settings.json'
    if (Test-Path -LiteralPath $launcher) { return $launcher }
    return $machine
}

function Get-CuroUserConfigPath {
    <#
    .SYNOPSIS
        The stable per-user config location written by setup.ps1 -Mode Launcher.
        Deliberately NOT under the payload cache, which is keyed by a hash of
        the exe's contents and therefore changes on every update.
    #>
    [CmdletBinding()]
    param()
    return (Join-Path $env:LOCALAPPDATA 'CuroPDFProtect\settings.json')
}

function Get-CuroConfig {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-CuroConfigPath)
    )

    if (-not (Test-Path $Path)) {
        throw "Config file not found at '$Path'. Run setup.ps1 on this machine (or install.ps1 from the deploy share) to create it."
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try {
        $cfg = $raw | ConvertFrom-Json
    } catch {
        throw "Config at '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    # Schema version gate - refuse to run on unknown schema.
    if (-not $cfg.schema_version) {
        throw "Config at '$Path' missing schema_version."
    }
    if ([int]$cfg.schema_version -ne $script:CurrentSchemaVersion) {
        throw "Config schema_version $($cfg.schema_version) not supported by this tool version (expected $script:CurrentSchemaVersion)."
    }

    # Expand %EnvVar% tokens in path-like string values.
    $pathKeys = @(
        'client_lookup_file',
        'client_lookup_cache_path',
        'escrow_dir',
        'escrow_pubkey_path',
        'escrow_cert_path',
        'audit_log_path',
        'install_dir',
        'qpdf_path'
    )
    foreach ($k in $pathKeys) {
        if ($cfg.PSObject.Properties[$k] -and $cfg.$k) {
            $cfg.$k = [Environment]::ExpandEnvironmentVariables($cfg.$k)
        }
    }

    # Minimum-sanity checks - fail closed on misconfiguration.
    Assert-ConfigField $cfg 'client_lookup_file' { param($v) $v -match '^[\\a-zA-Z]' }
    Assert-ConfigField $cfg 'escrow_dir'          { param($v) $v -match '^\\\\' -or $v -match '^[A-Za-z]:' }
    Assert-ConfigField $cfg 'dob_password_digits' { param($v) [int]$v -ge 6 -and [int]$v -le 12 }
    Assert-ConfigField $cfg 'manual_password_min_length' { param($v) [int]$v -ge 8 }
    Assert-ConfigField $cfg 'audit_log_retention_days'   { param($v) [int]$v -ge 30 }
    Assert-ConfigField $cfg 'qpdf_path' { param($v) -not [string]::IsNullOrWhiteSpace([string]$v) }

    return $cfg
}

function Assert-ConfigField {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Validator
    )
    $v = $Config.$Name
    if ($null -eq $v) {
        throw "Config missing required field '$Name'."
    }
    if (-not (& $Validator $v)) {
        throw "Config field '$Name' has invalid value '$v'."
    }
}


function Test-CuroBinaryIntegrity {
    <#
    .SYNOPSIS
        Verify every SHA-256-pinned binary next to qpdf.exe. Returns $null when
        all match, or a human-readable reason string on the first problem.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$QpdfPath)
    $binDir = [IO.Path]::GetDirectoryName($QpdfPath)
    $hashes = Join-Path $binDir 'HASHES.txt'
    if (-not (Test-Path -LiteralPath $hashes)) { return "HASHES.txt missing next to qpdf.exe ($hashes)." }
    $expected = @{}
    Get-Content -LiteralPath $hashes | ForEach-Object {
        if ($_ -match '^\s*([a-fA-F0-9]{64})\s+\*?(.+?)\s*$') { $expected[$Matches[2].Trim().ToLowerInvariant()] = $Matches[1].ToLowerInvariant() }
    }
    if ($expected.Count -eq 0) { return 'HASHES.txt lists no pinned hashes.' }
    foreach ($name in $expected.Keys) {
        $p = Join-Path $binDir $name
        if (-not (Test-Path -LiteralPath $p)) { return "Pinned binary missing: $name" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant()
        if ($actual -ne $expected[$name]) { return "SHA-256 mismatch for $name (bundled binary modified)." }
    }
    return $null
}

function Get-CuroDeploymentCertPath {
    <#
    .SYNOPSIS
        Where the ONE escrow certificate for this whole deployment lives.
    .DESCRIPTION
        Every machine must wrap under the same escrow key. If a second PC mints
        its own, the sidecars it writes cannot be recovered with the office .pfx
        and nothing notices until a client actually needs a password back - so
        the certificate is published once, beside the escrow records, and every
        later machine adopts it from here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EscrowDir)
    return (Join-Path (Join-Path $EscrowDir '_deployment') 'escrow.cer')
}

function Get-CuroCertFingerprint {
    <#
    .SYNOPSIS
        Lowercase SHA-1 thumbprint of a .cer, matching the escrow sidecar's
        public_key_fingerprint field (src\Write-Escrow.ps1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path)
    try { return $c.Thumbprint.Replace(' ', '').ToLowerInvariant() } finally { $c.Dispose() }
}

function Test-CuroHealth {
    [CmdletBinding()]
    param([string]$Path = (Get-CuroConfigPath))
    $issues = New-Object System.Collections.Generic.List[object]
    $cfg = $null
    try { $cfg = Get-CuroConfig -Path $Path } catch { $issues.Add([pscustomobject]@{ Component='settings.json'; Healthy=$false; Message=$_.Exception.Message; NextStep="Run setup.ps1 on this machine to create $Path (guided), or install.ps1 -SourcePath <deploy folder> for a GPO install." }) | Out-Null }
    if ($cfg) {
        foreach ($check in @(
            @{Name='qpdf'; Path=$cfg.qpdf_path; Step='Install qpdf.exe or fix qpdf_path in settings.json.'},
            @{Name='client list'; Path=$cfg.client_lookup_file; Step='Run admin\Publish-Clients.ps1 or fix client_lookup_file.'},
            @{Name='escrow certificate'; Path=$(if ($cfg.escrow_cert_path) { $cfg.escrow_cert_path } else { $cfg.escrow_pubkey_path }); Step='Deploy the escrow public certificate to ProgramData or fix escrow_cert_path.'}
        )) { if (-not $check.Path -or -not (Test-Path -LiteralPath $check.Path)) { $issues.Add([pscustomobject]@{ Component=$check.Name; Healthy=$false; Message="Missing or unreachable: $($check.Path)"; NextStep=$check.Step }) | Out-Null } }
        if ($cfg.qpdf_path -and (Test-Path -LiteralPath $cfg.qpdf_path)) {
            $integrity = Test-CuroBinaryIntegrity -QpdfPath $cfg.qpdf_path
            if ($integrity) { $issues.Add([pscustomobject]@{ Component='binary integrity'; Healthy=$false; Message=$integrity; NextStep='Reinstall from a trusted source - a bundled binary is missing, unpinned, or modified.' }) | Out-Null }
        }
        # Probe audit writability by opening the log for append - the way logging
        # actually writes, and what works under the append-friendly Users grant
        # (a temp file in the folder would need write access the root now denies).
        try { $auditDir = Split-Path $cfg.audit_log_path -Parent; if (-not (Test-Path -LiteralPath $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force -ErrorAction Stop | Out-Null }; $probe = New-Object System.IO.StreamWriter($cfg.audit_log_path, $true, [System.Text.UTF8Encoding]::new($false)); $probe.Dispose() }
        catch { $issues.Add([pscustomobject]@{ Component='audit log'; Healthy=$false; Message=$_.Exception.Message; NextStep='Fix audit_log_path permissions or create the configured audit folder.' }) | Out-Null }
        try { if (-not (Test-Path -LiteralPath $cfg.escrow_dir)) { New-Item -ItemType Directory -Path $cfg.escrow_dir -Force -ErrorAction Stop | Out-Null } }
        catch { $issues.Add([pscustomobject]@{ Component='escrow directory'; Healthy=$false; Message=$_.Exception.Message; NextStep='Restore access to escrow_dir before protecting PDFs.' }) | Out-Null }
        # One deployment = one escrow key. A machine wrapping under a different
        # key than the rest of the team writes sidecars the office .pfx cannot
        # recover, and that is invisible until a real recovery is attempted -
        # so compare this machine's cert against the published deployment cert.
        # Silent when the published cert is absent: an escrow share that is
        # unreachable is already reported by the check above, and a deployment
        # predating publication should not be branded unhealthy for it.
        $localCert = if ($cfg.escrow_cert_path) { $cfg.escrow_cert_path } else { $cfg.escrow_pubkey_path }
        if ($cfg.escrow_dir -and $localCert -and (Test-Path -LiteralPath $localCert)) {
            $publishedCert = Get-CuroDeploymentCertPath -EscrowDir $cfg.escrow_dir
            if (Test-Path -LiteralPath $publishedCert) {
                try {
                    $localFp     = Get-CuroCertFingerprint -Path $localCert
                    $publishedFp = Get-CuroCertFingerprint -Path $publishedCert
                    if ($localFp -ne $publishedFp) {
                        $issues.Add([pscustomobject]@{
                            Component = 'escrow key'
                            Healthy   = $false
                            Message   = "This machine wraps under $localFp but the deployment key is $publishedFp. Files protected here would NOT be recoverable with the team's recovery PFX."
                            NextStep  = "Replace '$localCert' with '$publishedCert', or re-run setup.ps1. If this machine's key is the correct one, rotate deliberately with admin\Rotate-EscrowKey.ps1."
                        }) | Out-Null
                    }
                } catch {
                    $issues.Add([pscustomobject]@{ Component='escrow key'; Healthy=$false; Message="Could not compare escrow certificates: $($_.Exception.Message)"; NextStep='Check that both the local and published escrow.cer are readable.' }) | Out-Null
                }
            }
        }
    }
    # Build the result with Add-Member rather than [pscustomobject]@{...}: the
    # cast form intermittently throws "Argument types do not match" on Windows
    # PowerShell 5.1 when a value is an array (Issues) alongside the config
    # object, which would make callers see a null health result.
    $result = New-Object -TypeName psobject
    $result | Add-Member -MemberType NoteProperty -Name Healthy -Value ([bool]($issues.Count -eq 0))
    $result | Add-Member -MemberType NoteProperty -Name Issues  -Value ([object[]]$issues.ToArray())
    $result | Add-Member -MemberType NoteProperty -Name Config  -Value $cfg
    return $result
}

Export-ModuleMember -Function Get-CuroConfig, Test-CuroHealth, Get-CuroConfigPath, Get-CuroUserConfigPath, Test-CuroBinaryIntegrity, Get-CuroDeploymentCertPath, Get-CuroCertFingerprint
