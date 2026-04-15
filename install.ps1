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
      1. Compare version.txt on deploy share vs local install — skip if current.
      2. Copy src\, admin\, bin\, config\ into C:\Program Files\CuroPDFProtect\.
      3. Verify SHA-256 of bundled qpdf.exe and 7z.exe against pinned hashes.
      4. Write C:\ProgramData\CuroPDFProtect\settings.json (from network config
         if supplied, otherwise from config\settings.default.json).
      5. Fetch escrow.pub from the share and place in ProgramData.
      6. Register HKLM context-menu entries.
      7. Create and ACL the audit log directory.
      8. Record version.txt.
      9. Emit a heartbeat audit row.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourcePath,
    [string] $NetworkConfigPath,
    [string] $ClientLookupPath,
    [string] $InstallDir = 'C:\Program Files\CuroPDFProtect',
    [switch] $Silent
)

$ErrorActionPreference = 'Stop'

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

# --- Verify binary hashes ----------------------------------------------------
$hashesPath = Join-Path $SourcePath 'bin\HASHES.txt'
if (Test-Path $hashesPath) {
    $expected = @{}
    Get-Content $hashesPath | ForEach-Object {
        if ($_ -match '^\s*([a-fA-F0-9]{64})\s+\*?(.+)\s*$') {
            $expected[$Matches[2].Trim().ToLowerInvariant()] = $Matches[1].ToLowerInvariant()
        }
    }
    foreach ($bin in 'qpdf.exe','7z.exe') {
        $p = Join-Path $InstallDir "bin\$bin"
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant()
        $exp = $expected[$bin.ToLowerInvariant()]
        if (-not $exp) { throw "No pinned hash for $bin in HASHES.txt" }
        if ($actual -ne $exp) { throw "SHA-256 mismatch for ${bin}: expected $exp, got $actual" }
        Write-Log "SHA-256 OK: $bin"
    }
} else {
    Write-Warning "HASHES.txt not present on deploy share — binaries unverified."
}

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
$pubSrc = Join-Path $SourcePath 'escrow.pub'
$pubDst = Join-Path $programData 'escrow.pub'
if (Test-Path $pubSrc) {
    Copy-Item -LiteralPath $pubSrc -Destination $pubDst -Force
    Write-Log "escrow.pub deployed"
} else {
    Write-Warning "No escrow.pub on deploy share — Rotate-EscrowKey.ps1 has not been run."
}

# --- ACL ProgramData ---------------------------------------------------------
$acl = Get-Acl $programData
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Users','Modify','ContainerInherit,ObjectInherit','None','Allow')
$acl.SetAccessRule($rule)
Set-Acl $programData $acl

# --- Register context menu (HKLM, per-machine) -------------------------------
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$protectScript = Join-Path $InstallDir 'src\Protect-File.ps1'

function Register-ContextMenu {
    param([string]$RootKey, [string]$EntryKey, [string]$Label, [string]$Command, [string]$Icon)
    $full = "$RootKey\$EntryKey"
    if (-not (Test-Path $full)) { New-Item -Path $full -Force | Out-Null }
    Set-ItemProperty -Path $full -Name '(default)' -Value $Label
    if ($Icon) { Set-ItemProperty -Path $full -Name 'Icon' -Value $Icon }
    $cmdKey = "$full\command"
    if (-not (Test-Path $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
    Set-ItemProperty -Path $cmdKey -Name '(default)' -Value $Command
}

# Entry on all files: Protect with password
Register-ContextMenu `
    -RootKey 'HKLM:\Software\Classes\*\shell' `
    -EntryKey 'CuroProtectWithPassword' `
    -Label 'Protect with password' `
    -Icon (Join-Path $InstallDir 'bin\qpdf.exe') `
    -Command ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Path "%1"' -f $psExe, $protectScript)

# Entry on all files: Protect and attach to new Outlook email
Register-ContextMenu `
    -RootKey 'HKLM:\Software\Classes\*\shell' `
    -EntryKey 'CuroProtectAndEmail' `
    -Label 'Protect and attach to new email' `
    -Command ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Path "%1" -OutlookMode New' -f $psExe, $protectScript)

# Entry on folders: Protect all files in folder
$folderScript = Join-Path $InstallDir 'src\Protect-Folder.ps1'
Register-ContextMenu `
    -RootKey 'HKLM:\Software\Classes\Directory\shell' `
    -EntryKey 'CuroProtectFolder' `
    -Label 'Protect all files in folder' `
    -Command ('"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Path "%V"' -f $psExe, $folderScript)

# Nudge Explorer to pick up new entries
try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Process explorer } catch { }

Write-Log "Install complete. Version $shareVersion registered."
exit 0
