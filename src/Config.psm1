# Config.psm1
# Loads and validates settings.json for the Curo PDF Protector.
# Never reads from %APPDATA% or user profile.

$script:CurrentSchemaVersion = 1

function Get-CuroConfigPath {
    <#
    .SYNOPSIS
        Resolve which settings.json to load. Probe order:
          1. $env:CURO_SETTINGS_PATH  (explicit override; test/CI seam)
          2. %ProgramData%\CuroPDFProtect\settings.json  (machine-wide install)
          3. <tool root>\config\settings.json  (no-admin launcher deployment,
             written by setup.ps1 -Mode Launcher)
        Returns the first that exists. If none exist, returns the machine-wide
        path so "not found" errors name the location setup.ps1/install.ps1
        create. An explicit CURO_SETTINGS_PATH is always honoured, even if the
        file is missing, so the error names what the operator pointed at.
    #>
    [CmdletBinding()]
    param()
    if ($env:CURO_SETTINGS_PATH) { return $env:CURO_SETTINGS_PATH }
    $machine = Join-Path $env:ProgramData 'CuroPDFProtect\settings.json'
    if (Test-Path -LiteralPath $machine) { return $machine }
    $toolRoot = Split-Path -Parent $PSScriptRoot   # src\ -> install/repo root
    $launcher = Join-Path (Join-Path $toolRoot 'config') 'settings.json'
    if (Test-Path -LiteralPath $launcher) { return $launcher }
    return $machine
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

Export-ModuleMember -Function Get-CuroConfig, Test-CuroHealth, Get-CuroConfigPath, Test-CuroBinaryIntegrity
