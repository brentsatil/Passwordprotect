# Config.psm1
# Loads and validates settings.json for the Curo PDF Protector.
# Machine-wide only — never reads from %APPDATA% or user profile.

$script:ConfigPath = Join-Path $env:ProgramData 'CuroPDFProtect\settings.json'
$script:CurrentSchemaVersion = 1

function Get-CuroConfig {
    [CmdletBinding()]
    param(
        [string]$Path = $script:ConfigPath
    )

    if (-not (Test-Path $Path)) {
        throw "Config file not found at '$Path'. Re-run install.ps1."
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try {
        $cfg = $raw | ConvertFrom-Json
    } catch {
        throw "Config at '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    # Schema version gate — refuse to run on unknown schema.
    if (-not $cfg.schema_version) {
        throw "Config at '$Path' missing schema_version."
    }
    if ([int]$cfg.schema_version -ne $script:CurrentSchemaVersion) {
        throw "Config schema_version $($cfg.schema_version) not supported by this tool version (expected $script:CurrentSchemaVersion)."
    }

    # Expand %EnvVar% tokens in path-like string values.
    $pathKeys = @(
        'client_lookup_cache_path',
        'escrow_pubkey_path',
        'audit_log_path',
        'install_dir',
        'qpdf_path',
        'sevenzip_path'
    )
    foreach ($k in $pathKeys) {
        if ($cfg.PSObject.Properties[$k] -and $cfg.$k) {
            $cfg.$k = [Environment]::ExpandEnvironmentVariables($cfg.$k)
        }
    }

    # Minimum-sanity checks — fail closed on misconfiguration.
    Assert-ConfigField $cfg 'client_lookup_file' { param($v) $v -match '^[\\a-zA-Z]' }
    Assert-ConfigField $cfg 'escrow_dir'          { param($v) $v -match '^\\\\' -or $v -match '^[A-Za-z]:' }
    Assert-ConfigField $cfg 'dob_password_digits' { param($v) [int]$v -ge 6 -and [int]$v -le 12 }
    Assert-ConfigField $cfg 'manual_password_min_length' { param($v) [int]$v -ge 8 }
    Assert-ConfigField $cfg 'audit_log_retention_days'   { param($v) [int]$v -ge 30 }

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

Export-ModuleMember -Function Get-CuroConfig
