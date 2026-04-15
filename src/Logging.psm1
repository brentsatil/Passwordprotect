# Logging.psm1
# Heartbeat + structured error helpers. NEVER log passwords, SecureStrings,
# or any derived password material.

$script:ToolVersion = '1.0.0'

function Write-Heartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] $Config
    )
    $entry = [ordered]@{
        ts        = (Get-Date).ToUniversalTime().ToString("o")
        v         = $script:ToolVersion
        host      = $env:COMPUTERNAME
        user      = "$env:USERDOMAIN\$env:USERNAME"
        op        = $Operation
        event     = 'heartbeat'
        ps_edition = $PSVersionTable.PSEdition
        ps_version = $PSVersionTable.PSVersion.ToString()
    }
    Append-JsonLine -Path $Config.audit_log_path -Entry $entry
}

function Write-AuditEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [hashtable] $Fields
    )
    $base = [ordered]@{
        ts   = (Get-Date).ToUniversalTime().ToString("o")
        v    = $script:ToolVersion
        host = $env:COMPUTERNAME
        user = "$env:USERDOMAIN\$env:USERNAME"
    }
    foreach ($k in $Fields.Keys) { $base[$k] = $Fields[$k] }
    Append-JsonLine -Path $Config.audit_log_path -Entry $base
}

function Append-JsonLine {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Entry
    )
    $dir = Split-Path -LiteralPath $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Entry | ConvertTo-Json -Compress -Depth 6
    # Use .NET directly to get an atomic append with explicit UTF-8 encoding
    # (Add-Content can drop BOM mid-file on PowerShell 5.1).
    $sw = New-Object System.IO.StreamWriter($Path, $true, [System.Text.UTF8Encoding]::new($false))
    try { $sw.WriteLine($json) } finally { $sw.Dispose() }
}

function Get-ToolVersion { return $script:ToolVersion }

Export-ModuleMember -Function Write-Heartbeat, Write-AuditEvent, Get-ToolVersion
