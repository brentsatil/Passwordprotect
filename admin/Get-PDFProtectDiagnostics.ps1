#Requires -Version 5.1
<#
.SYNOPSIS
    Produce a single-shot diagnostics report for a support ticket.
.DESCRIPTION
    One-stop health check. Staff run this, copy the output, and paste it
    into their ticket. Covers tool version, dependency hashes, CSV and
    escrow-share reachability, last audit events, PowerShell/OS version,
    and AD security-group membership.

    Never reveals any password, escrow private key, or audit row that
    contains secret-derived data (the audit log does not record such data
    by design, but this script filters defensively anyway).
#>

[CmdletBinding()]
param([switch] $Copy)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root = Split-Path -Parent $here
Import-Module (Join-Path $root 'src\Config.psm1')  -Force
Import-Module (Join-Path $root 'src\Logging.psm1') -Force

$report = @()
$report += "=========================================================="
$report += "Curo PDF Protector — Diagnostics"
$report += "Generated: $((Get-Date).ToString('o'))"
$report += "Host:      $env:COMPUTERNAME"
$report += "User:      $env:USERDOMAIN\$env:USERNAME"
$report += "----------------------------------------------------------"

try {
    $config = Get-CuroConfig
    $report += "Config load:        OK"
    $report += "Config schema:      $($config.schema_version)"
    $report += "Tool version pin:   $($config.tool_version_pin)"
    $report += "Install dir:        $($config.install_dir)"
} catch {
    $report += "Config load:        FAIL — $($_.Exception.Message)"
    $report -join "`n" | Write-Output
    return
}

# PowerShell / OS
$report += "PS Edition:         $($PSVersionTable.PSEdition)"
$report += "PS Version:         $($PSVersionTable.PSVersion)"
$report += "OS:                 $((Get-CimInstance Win32_OperatingSystem).Caption) ($((Get-CimInstance Win32_OperatingSystem).Version))"
$report += "----------------------------------------------------------"

# Dependencies
foreach ($dep in @(
    @{ Name='qpdf'; Path=$config.qpdf_path },
    @{ Name='7z';   Path=$config.sevenzip_path })) {
    if (Test-Path -LiteralPath $dep.Path) {
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $dep.Path).Hash
        $report += "$($dep.Name.PadRight(18)): OK   SHA256=$h"
    } else {
        $report += "$($dep.Name.PadRight(18)): MISSING at $($dep.Path)"
    }
}
$report += "----------------------------------------------------------"

# Client CSV reachability and age
$primary = $config.client_lookup_file
$cache   = [Environment]::ExpandEnvironmentVariables($config.client_lookup_cache_path)
if (Test-Path -LiteralPath $primary) {
    $ageD = [math]::Floor(((Get-Date) - (Get-Item $primary).LastWriteTime).TotalDays)
    $report += "Client CSV primary: OK  age=${ageD}d  ($primary)"
} else {
    $report += "Client CSV primary: UNREACHABLE  ($primary)"
}
if (Test-Path -LiteralPath $cache) {
    $ageD = [math]::Floor(((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays)
    $report += "Client CSV cache:   present  age=${ageD}d"
} else {
    $report += "Client CSV cache:   absent"
}
$report += "----------------------------------------------------------"

# Escrow reachability
$escDir = $config.escrow_dir
if (Test-Path -LiteralPath $escDir) {
    $cnt = (Get-ChildItem -Path $escDir -Filter '*.escrow.json' -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count
    $report += "Escrow share:       OK   sidecars=$cnt  ($escDir)"
} else {
    $report += "Escrow share:       UNREACHABLE  ($escDir)"
}
$pubPath = [Environment]::ExpandEnvironmentVariables($config.escrow_pubkey_path)
if (Test-Path -LiteralPath $pubPath) {
    $report += "Escrow pubkey:      OK  ($pubPath)"
} else {
    $report += "Escrow pubkey:      MISSING  ($pubPath)"
}
$report += "----------------------------------------------------------"

# Audit log size + tail
$auditPath = [Environment]::ExpandEnvironmentVariables($config.audit_log_path)
if (Test-Path -LiteralPath $auditPath) {
    $sz = (Get-Item $auditPath).Length
    $report += "Audit log:          OK  size=$sz bytes"
    $report += "Last 5 audit events (password fields redacted):"
    $tail = Get-Content -LiteralPath $auditPath -Tail 5
    foreach ($line in $tail) {
        # Defensive redaction — any key containing 'password' or 'pw'.
        $report += "  $($line -replace '("(?:[^"]*(?:password|pw|secret)[^"]*)")\s*:\s*"[^"]*"', '$1:"[REDACTED]"')"
    }
} else {
    $report += "Audit log:          not yet created"
}
$report += "----------------------------------------------------------"

# AD group membership (diagnostic for ring rollout)
try {
    $groups = (& whoami /groups 2>$null) -match 'CuroPDFProtect'
    $report += "Curo AD groups:     $($groups -join ', ')"
} catch { }

# Context-menu registry
$hklm = 'HKLM:\Software\Classes\*\shell\CuroProtectWithPassword'
$report += "HKLM context entry: $(if (Test-Path $hklm) {'present'} else {'MISSING'})"

$out = $report -join "`n"
Write-Output $out
if ($Copy) { $out | Set-Clipboard; Write-Host "Report copied to clipboard." -ForegroundColor Green }
