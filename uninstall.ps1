#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remove the Curo PDF Protector from this machine.
.DESCRIPTION
    - Removes HKLM context-menu entries.
    - Removes C:\Program Files\CuroPDFProtect\.
    - LEAVES the audit log at C:\ProgramData\CuroPDFProtect\audit.log alone by
      default (7-year retention under Corps Act). Pass -PurgeAuditLog to also
      remove it (normally only at machine decommission after backup).
#>
[CmdletBinding()]
param(
    [switch] $PurgeAuditLog,
    [string] $InstallDir = 'C:\Program Files\CuroPDFProtect',
    [switch] $NoExplorerRestart
)

foreach ($k in @(
    'HKLM:\Software\Classes\*\shell\CuroProtectWithPassword',
    'HKLM:\Software\Classes\*\shell\CuroProtectAndEmail',
    'HKLM:\Software\Classes\Directory\shell\CuroProtectFolder'
)) {
    if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force }
}

if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }

if ($PurgeAuditLog) {
    $pd = 'C:\ProgramData\CuroPDFProtect'
    if (Test-Path $pd) { Remove-Item -Path $pd -Recurse -Force }
}

if (-not $NoExplorerRestart) {
    try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Process explorer } catch { }
}
Write-Host "Curo PDF Protector removed."
