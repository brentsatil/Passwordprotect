#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install the Curo PDF Protector for all users on this machine.
.DESCRIPTION
    Intended to be invoked by a GPO startup script with:
        -SourcePath         \\server\deploy$\CuroPDFProtect
        -NetworkConfigPath  \\server\shared\PDFProtect\settings.json
        -ClientLookupPath   \\server\shared\PDFProtect\clients.csv
        -Silent

    Actions:
      1. Compare version.txt on deploy share vs local install - skip if current.
      2. Copy src\, admin\, bin\, config\ into C:\Program Files\CuroPDFProtect\.
      3. Verify SHA-256 of bundled qpdf.exe against pinned hashes.
      4. Write C:\ProgramData\CuroPDFProtect\settings.json (from network config
         if supplied, otherwise from config\settings.default.json).
      5. Fetch escrow.cer from the share and place in ProgramData.
      6. Register HKLM context-menu entries.
      7. Create and ACL the audit log directory.
      8. Record version.txt.
      9. Emit a heartbeat audit row.
#>

[CmdletBinding()]
param(
    [string] $SourcePath,
    [string] $NetworkConfigPath,
    [string] $ClientLookupPath,
    [string] $InstallDir = 'C:\Program Files\CuroPDFProtect',
    [switch] $Silent,
    [switch] $NoExplorerRestart
)

$ErrorActionPreference = 'Stop'

# Default the source to this script's own folder so a fresh clone installs
# without a deploy share (GPO usage still passes -SourcePath explicitly).
if (-not $SourcePath) {
    $SourcePath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
}

function Write-Log { param($m) if (-not $Silent) { Write-Host "[install] $m" } }

# --- Version check -----------------------------------------------------------
$shareVersion = $null
$localVersion = $null
$versionFile = Join-Path $SourcePath 'VERSION'
if (Test-Path $versionFile) { $shareVersion = (Get-Content $versionFile -Raw).Trim() }
$localVersionFile = Join-Path $InstallDir 'VERSION'
if (Test-Path $localVersionFile) { $localVersion = (Get-Content $localVersionFile -Raw).Trim() }

if ($shareVersion -and $localVersion -and $shareVersion -eq $localVersion) {
    Write-Log "Already at $localVersion. Nothing to do."
    exit 0
}

Write-Log "Installing from $SourcePath to $InstallDir (share: $shareVersion, local: $localVersion)"

# --- Copy payload ------------------------------------------------------------
foreach ($sub in 'src','admin','bin','config') {
    $src = Join-Path $SourcePath $sub
    $dst = Join-Path $InstallDir $sub
    if (-not (Test-Path $src)) { throw "Missing expected folder in deploy share: $src" }
    if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
}
Copy-Item -Path $versionFile -Destination $localVersionFile -Force

# --- Verify binary hashes (bidirectional) ------------------------------------
# Refuse to install unverified binaries: every pinned file must be present and
# match, AND every .exe/.dll in bin\ must be pinned (so a smuggled DLL - e.g.
# a tampered qpdf29.dll, which holds the actual crypto - cannot slip through).
$hashesPath = Join-Path $SourcePath 'bin\HASHES.txt'
if (-not (Test-Path $hashesPath)) {
    throw "bin\HASHES.txt is missing - refusing to install unverified binaries."
}
$expected = @{}
Get-Content $hashesPath | ForEach-Object {
    if ($_ -match '^\s*([a-fA-F0-9]{64})\s+\*?(.+?)\s*$') {
        $expected[$Matches[2].Trim().ToLowerInvariant()] = $Matches[1].ToLowerInvariant()
    }
}
if ($expected.Count -eq 0) { throw "bin\HASHES.txt contains no pinned hashes." }
foreach ($name in $expected.Keys) {
    $p = Join-Path $InstallDir "bin\$name"
    if (-not (Test-Path -LiteralPath $p)) { throw "Pinned binary missing after copy: bin\$name" }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant()
    if ($actual -ne $expected[$name]) { throw "SHA-256 mismatch for bin\${name}: expected $($expected[$name]), got $actual" }
}
Get-ChildItem -LiteralPath (Join-Path $InstallDir 'bin') -File |
    Where-Object { $_.Extension -in '.exe','.dll' } | ForEach-Object {
        if (-not $expected.ContainsKey($_.Name.ToLowerInvariant())) {
            throw "Unpinned binary in bin\: $($_.Name). Add it to HASHES.txt or remove it."
        }
    }
Write-Log "SHA-256 verified: $($expected.Count) pinned binaries, no unpinned .exe/.dll."

# --- Place settings.json -----------------------------------------------------
$programData = 'C:\ProgramData\CuroPDFProtect'
if (-not (Test-Path $programData)) { New-Item -ItemType Directory -Path $programData -Force | Out-Null }
$settingsDst = Join-Path $programData 'settings.json'
if ($NetworkConfigPath -and (Test-Path $NetworkConfigPath)) {
    Copy-Item -LiteralPath $NetworkConfigPath -Destination $settingsDst -Force
    Write-Log "settings.json from network: $NetworkConfigPath"
} else {
    Copy-Item -LiteralPath (Join-Path $InstallDir 'config\settings.default.json') -Destination $settingsDst -Force
    Write-Log "settings.json from bundled default"
}

# --- Escrow pubkey -----------------------------------------------------------
$pubSrc = Join-Path $SourcePath 'escrow.cer'
$pubDst = Join-Path $programData 'escrow.cer'
if (Test-Path $pubSrc) {
    Copy-Item -LiteralPath $pubSrc -Destination $pubDst -Force
    Write-Log "escrow.cer deployed"
} else {
    Write-Warning "No escrow.cer on deploy share - Rotate-EscrowKey.ps1 has not been run."
}

# --- ACL ProgramData ---------------------------------------------------------
# Break inheritance and make the root read-only for Users, so settings.json and
# escrow.cer (which the tool trusts) cannot be tampered with by a standard user.
# The cache folder and the audit log stay writable so the tool keeps working.
$cacheDir  = Join-Path $programData 'cache'
if (-not (Test-Path $cacheDir))  { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
$auditFile = Join-Path $programData 'audit.log'
if (-not (Test-Path $auditFile)) { New-Item -ItemType File -Path $auditFile -Force | Out-Null }

$acl = Get-Acl $programData
$acl.SetAccessRuleProtection($true, $false)   # break inheritance, drop inherited ACEs
foreach ($id in 'NT AUTHORITY\SYSTEM','BUILTIN\Administrators') {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $id,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
}
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Users','ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
Set-Acl $programData $acl

# cache\: Users Modify (client-list cache refresh writes here).
$cacheAcl = Get-Acl $cacheDir
$cacheAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Users','Modify','ContainerInherit,ObjectInherit','None','Allow')))
Set-Acl $cacheDir $cacheAcl

# audit.log: Users Modify on the file (append audit rows). Tightening this to
# append-only (tamper-evident) is a documented future step in docs/DECISIONS.md.
$auditAcl = Get-Acl $auditFile
$auditAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Users','Modify','Allow')))
Set-Acl $auditFile $auditAcl

# --- Register context menu (HKLM, per-machine) -------------------------------
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$protectScript = Join-Path $InstallDir 'src\Protect-File.ps1'

function Register-ContextMenu {
    # SubKey is relative to HKLM, e.g. 'Software\Classes\*\shell\CuroProtectWithPassword'.
    # Uses the .NET registry API on purpose: the all-files ProgID key is literally
    # named "*", and the PowerShell registry provider (Test-Path / New-Item /
    # Set-ItemProperty) treats "*" as a WILDCARD, which matches every ProgID and
    # makes registration hang / write to the wrong keys. CreateSubKey takes the
    # name literally.
    param([string]$SubKey, [string]$Label, [string]$Command, [string]$Icon)
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($SubKey)
    try {
        $key.SetValue('', $Label)
        if ($Icon) { $key.SetValue('Icon', $Icon) }
        $cmd = $key.CreateSubKey('command')
        try { $cmd.SetValue('', $Command) } finally { $cmd.Close() }
    } finally { $key.Close() }
}

$folderScript = Join-Path $InstallDir 'src\Protect-Folder.ps1'

# Entry on all files: Protect with password
Register-ContextMenu `
    -SubKey 'Software\Classes\*\shell\CuroProtectWithPassword' `
    -Label 'Protect with password' `
    -Icon (Join-Path $InstallDir 'bin\qpdf.exe') `
    -Command ('"{0}" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Path "%1"' -f $psExe, $protectScript)

# Entry on all files: Protect and attach to new Outlook email
Register-ContextMenu `
    -SubKey 'Software\Classes\*\shell\CuroProtectAndEmail' `
    -Label 'Protect and attach to new email' `
    -Command ('"{0}" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Path "%1" -OutlookMode New' -f $psExe, $protectScript)

# Entry on folders: Protect all files in folder
Register-ContextMenu `
    -SubKey 'Software\Classes\Directory\shell\CuroProtectFolder' `
    -Label 'Protect all files in folder' `
    -Command ('"{0}" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Path "%V"' -f $psExe, $folderScript)

# Nudge Explorer to pick up new entries (skippable for headless/CI/setup use).
if (-not $NoExplorerRestart) {
    try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Process explorer } catch { }
}

Write-Log "Install complete. Version $shareVersion registered."
exit 0
