#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the Windows 11 modern context-menu entry.
.DESCRIPTION
    Unregisters the sparse package. The files in the package folder are left
    alone (a sparse package never owned them) and the legacy registry verbs
    written by install.ps1 are untouched - uninstall.ps1 removes those.
.PARAMETER RemoveTrustedCert
    Also remove the self-signed certificate from LocalMachine\TrustedPeople.
    Needs elevation. Skip it if other in-house tools share the certificate.
#>

[CmdletBinding()]
param(
    [switch] $RemoveTrustedCert,
    [switch] $NoExplorerRestart
)

$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function Note($m) { Write-Host "       $m" }

$pkg = Get-AppxPackage -Name 'CuroFinancialServices.PDFProtector' -ErrorAction SilentlyContinue
if ($pkg) {
    Remove-AppxPackage -Package $pkg.PackageFullName
    Step "Removed $($pkg.PackageFullName)"
} else {
    Step 'Modern context-menu package was not installed.'
}

if ($RemoveTrustedCert) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Note 'Skipping certificate removal - needs an elevated PowerShell.'
    } else {
        $found = Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
                 Where-Object { $_.Subject -eq 'CN=Curo Financial Services' }
        foreach ($c in $found) {
            Remove-Item -LiteralPath $c.PSPath -Force
            Step "Removed trusted certificate $($c.Thumbprint)"
        }
        if (-not $found) { Note 'No matching certificate in TrustedPeople.' }
    }
}

if (-not $NoExplorerRestart) {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Step 'Explorer restarted.'
} else {
    Note 'Explorer NOT restarted - the entry disappears after the next sign-in.'
}

Note ''
Note 'The legacy "Show more options" entries, if installed, remain. Remove them'
Note 'with uninstall.ps1.'
