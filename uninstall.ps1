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

# Remove via the .NET registry API: the all-files ProgID key is literally named
# "*", which the PowerShell registry provider would treat as a wildcard.
foreach ($sk in @(
    'Software\Classes\*\shell\CuroProtectWithPassword',
    'Software\Classes\*\shell\CuroProtectAndEmail',
    'Software\Classes\Directory\shell\CuroProtectFolder'
)) {
    try { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($sk, $false) } catch { }
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
