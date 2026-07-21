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

function New-AuditMutex {
    # Machine-wide lock so concurrent writers (a folder batch and a right-click,
    # say) serialise their appends. Global\ so it spans sessions; grant
    # Authenticated Users so different logged-on users can open the same mutex.
    # Best-effort: if it can't be created, the caller's retry loop still copes.
    try {
        $sec = New-Object System.Security.AccessControl.MutexSecurity
        $sid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid, $null)
        $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule(
            $sid,
            ([System.Security.AccessControl.MutexRights]::Synchronize -bor [System.Security.AccessControl.MutexRights]::Modify),
            [System.Security.AccessControl.AccessControlType]::Allow)))
        $createdNew = $false
        return New-Object System.Threading.Mutex($false, 'Global\CuroPDFProtect.AuditLog', [ref]$createdNew, $sec)
    } catch {
        try { return New-Object System.Threading.Mutex($false, 'Local\CuroPDFProtect.AuditLog') } catch { return $null }
    }
}

function Append-JsonLine {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Entry
    )
    $dir = [IO.Path]::GetDirectoryName($Path)   # -LiteralPath can't take -Parent in PS 5.1
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Entry | ConvertTo-Json -Compress -Depth 6

    # Serialise appends across processes. Without this the StreamWriter opens the
    # log with FileShare.Read, so a concurrent writer hits an IOException (sharing
    # violation) and crashes mid-protect. On mutex timeout we still write (a rare
    # interleave beats dropping a compliance event); IOExceptions retry briefly.
    $mutex = $null; $held = $false
    try {
        $mutex = New-AuditMutex
        if ($mutex) {
            try { $held = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        }
        $lastErr = $null
        for ($i = 0; $i -lt 5; $i++) {
            try {
                # Explicit UTF-8 (no BOM); Add-Content can drop BOM mid-file on PS 5.1.
                $sw = New-Object System.IO.StreamWriter($Path, $true, [System.Text.UTF8Encoding]::new($false))
                try { $sw.WriteLine($json) } finally { $sw.Dispose() }
                $lastErr = $null; break
            } catch [System.IO.IOException] {
                $lastErr = $_; Start-Sleep -Milliseconds 200
            }
        }
        if ($lastErr) { throw $lastErr }
    } finally {
        if ($mutex) {
            if ($held) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
    }
}

function Get-ToolVersion { return $script:ToolVersion }

Export-ModuleMember -Function Write-Heartbeat, Write-AuditEvent, Get-ToolVersion
