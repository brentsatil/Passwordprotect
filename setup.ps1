#Requires -Version 5.1
<#
.SYNOPSIS
    Guided, idempotent first-time setup for the Curo PDF Protector.
.DESCRIPTION
    Takes a fresh clone (or a fresh machine) to a working, health-passing
    install in one run. Two modes:

      -Mode Install   Machine-wide install with Explorer right-click menus.
                      Runs install.ps1 (needs Administrator), writes
                      settings to %ProgramData%, hardens ACLs.

      -Mode Launcher  No-admin, self-contained. The tool runs from this
                      folder via PasswordProtect.cmd (drag-and-drop). Writes
                      settings to <this folder>\config\settings.json. No
                      registry, no admin. (Reduced tamper-resistance on the
                      audit log - documented in docs/ADMIN-SETUP.md.)

    Both modes need two shared locations, which you supply as parameters (or
    are prompted for): where the client list lives, and where password-
    recovery (escrow) records are written. Each accepts a UNC share
    (\\server\share\...), a synced OneDrive/SharePoint folder path, or a
    plain local path.

    Every step prints [OK] / [SKIP] / [FAIL]. The script is safe to re-run:
    existing config, an existing escrow key, and an existing client list are
    left in place unless -Force is given.

.PARAMETER Mode            Install | Launcher.
.PARAMETER ClientListPath  Where clients.csv lives (shared, readable by all staff).
.PARAMETER EscrowDir       Folder for escrow sidecars (shared, backed up).
.PARAMETER ClientSource    Master client spreadsheet/CSV to publish clients.csv from.
.PARAMETER SkipClientPublish  Don't publish clients.csv (do it later with admin\Publish-Clients.ps1).
.PARAMETER PfxPath         Where to write the escrow private key .pfx (keep OFFLINE, e.g. a USB).
.PARAMETER PfxPassword     Password protecting the escrow .pfx (prompted if omitted).
.PARAMETER InstallDir      Install-mode target (default C:\Program Files\CuroPDFProtect).
.PARAMETER NonInteractive  Never prompt; fail if a required value is missing.
.PARAMETER Force           Overwrite existing settings and regenerate the escrow key.

.EXAMPLE
    # No-admin, drag-and-drop, everything on a OneDrive-synced team folder:
    .\setup.ps1 -Mode Launcher `
        -ClientListPath "$env:USERPROFILE\Curo\PDFProtect\clients.csv" `
        -EscrowDir      "$env:USERPROFILE\Curo\PDFProtect-Escrow" `
        -ClientSource   "$env:USERPROFILE\Curo\Master-Clients.xlsx" `
        -PfxPath        'D:\curo-escrow.pfx'
.EXAMPLE
    # Machine-wide install with right-click menus, file-server shares:
    .\setup.ps1 -Mode Install `
        -ClientListPath '\\server\shared\PDFProtect\clients.csv' `
        -EscrowDir      '\\server\data\PDFProtect-Escrow' `
        -ClientSource   '\\server\shared\Master\Clients.xlsx' `
        -PfxPath        'E:\curo-escrow.pfx'
#>

[CmdletBinding()]
param(
    [ValidateSet('Install','Launcher')] [string] $Mode,
    [string] $ClientListPath,
    [string] $EscrowDir,
    [string] $ClientSource,
    [switch] $SkipClientPublish,
    [string] $PfxPath,
    [securestring] $PfxPassword,
    [string] $InstallDir = 'C:\Program Files\CuroPDFProtect',
    [switch] $NonInteractive,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

# --- tiny reporting helpers -------------------------------------------------
$script:failed = $false
function Say    { param($m) Write-Host $m }
function StepOK   { param($m) Write-Host "[OK]   $m"   -ForegroundColor Green }
function StepSkip { param($m) Write-Host "[SKIP] $m"   -ForegroundColor Yellow }
function StepFail { param($m) Write-Host "[FAIL] $m"   -ForegroundColor Red; $script:failed = $true }

function Need {
    <# Return a required value, prompting if allowed, else fail-fast. #>
    param([string]$Value, [string]$Name, [string]$Prompt)
    if ($Value) { return $Value }
    if ($NonInteractive) { throw "Missing required parameter -$Name (running -NonInteractive)." }
    $entered = Read-Host $Prompt
    if (-not $entered) { throw "No value entered for -$Name." }
    return $entered
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltinRole]::Administrator)
}

Say ''
Say '=== Curo PDF Protector setup ==='

# --- Step 1: mode + elevation ----------------------------------------------
if (-not $Mode) {
    if ($NonInteractive) { throw 'Missing required parameter -Mode (Install or Launcher).' }
    $ans = Read-Host 'Mode - [I]nstall machine-wide (needs admin), or [L]auncher no-admin? (I/L)'
    $Mode = if ($ans -match '^[Ii]') { 'Install' } else { 'Launcher' }
}
Say "Mode: $Mode"

if ($Mode -eq 'Install' -and -not (Test-IsAdmin)) {
    StepFail 'Install mode requires an elevated (Run as Administrator) PowerShell.'
    Say 'Re-run this in an admin PowerShell, or use -Mode Launcher for a no-admin setup.'
    exit 1
}
StepOK "Mode and privileges OK."

# --- Step 2: install payload (Install mode only) ---------------------------
$toolDir = if ($Mode -eq 'Install') { $InstallDir } else { $root }
if ($Mode -eq 'Install') {
    try {
        & (Join-Path $root 'install.ps1') -SourcePath $root -InstallDir $InstallDir -NoExplorerRestart -Silent
        StepOK "Payload installed to $InstallDir."
    } catch {
        StepFail "install.ps1 failed: $($_.Exception.Message)"
        exit 1
    }
} else {
    if (-not (Test-Path -LiteralPath (Join-Path $root 'bin\qpdf.exe'))) {
        StepFail "bin\qpdf.exe not found next to setup.ps1 - keep the whole folder together."
        exit 1
    }
    StepOK "Launcher runs in place from $root."
}

# --- gather shared locations ------------------------------------------------
$ClientListPath = Need $ClientListPath 'ClientListPath' 'Path to the shared client list (clients.csv) - UNC, synced folder, or local'
$EscrowDir      = Need $EscrowDir      'EscrowDir'      'Folder for password-recovery (escrow) records - UNC, synced folder, or local'

# --- Step 3: settings.json --------------------------------------------------
$programData = Join-Path $env:ProgramData 'CuroPDFProtect'
if (-not (Test-Path -LiteralPath $programData)) { New-Item -ItemType Directory -Path $programData -Force | Out-Null }

$settingsTarget = if ($Mode -eq 'Install') {
    Join-Path $programData 'settings.json'
} else {
    Join-Path (Join-Path $root 'config') 'settings.json'
}

# All later steps (and the admin scripts we invoke) resolve config through
# the probe order in Config.psm1; pin it to exactly the file we are writing.
$env:CURO_SETTINGS_PATH = $settingsTarget

if ((Test-Path -LiteralPath $settingsTarget) -and -not $Force) {
    StepSkip "settings.json already exists ($settingsTarget). Use -Force to rewrite."
} else {
    $template = Get-Content -LiteralPath (Join-Path $root 'config\settings.default.json') -Raw | ConvertFrom-Json
    # Convert the parsed object to an ordered hashtable we can edit + re-serialise.
    $s = [ordered]@{}
    foreach ($p in $template.PSObject.Properties) { $s[$p.Name] = $p.Value }
    $s['client_lookup_file'] = $ClientListPath
    $s['escrow_dir']         = $EscrowDir
    $s['qpdf_path']          = Join-Path $toolDir 'bin\qpdf.exe'
    $s['install_dir']        = $toolDir
    $s['escrow_cert_path']   = Join-Path $programData 'escrow.cer'
    $s['escrow_pubkey_path'] = Join-Path $programData 'escrow.cer'
    $s['audit_log_path']     = Join-Path $programData 'audit.log'
    $s['client_lookup_cache_path'] = Join-Path $programData 'cache\clients.csv'

    $json = ($s | ConvertTo-Json -Depth 6)
    $tmp = "$settingsTarget.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $settingsTarget -Force
    StepOK "Wrote $settingsTarget."
}

# Validate what we wrote (single source of truth: Config.psm1's validator).
Import-Module (Join-Path $root 'src\Config.psm1') -Force -DisableNameChecking
try {
    $cfg = Get-CuroConfig -Path $settingsTarget
    StepOK "settings.json is valid (schema $($cfg.schema_version))."
} catch {
    StepFail "settings.json failed validation: $($_.Exception.Message)"
    exit 1
}

# --- Step 4: local state (audit log dir + client cache dir) -----------------
foreach ($d in @($programData, (Join-Path $programData 'cache'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
StepOK "Local state folders ready under $programData."

# --- Step 5: escrow keypair -------------------------------------------------
$certPath = Join-Path $programData 'escrow.cer'
if ((Test-Path -LiteralPath $certPath) -and -not $Force) {
    StepSkip "Escrow certificate already present ($certPath). Use -Force to rotate."
} else {
    $PfxPath = Need $PfxPath 'PfxPath' 'Where to save the escrow PRIVATE key (.pfx) - keep this OFFLINE (e.g. a USB drive)'
    if (-not $PfxPassword) {
        if ($NonInteractive) { throw 'Missing required parameter -PfxPassword (running -NonInteractive).' }
        $PfxPassword = Read-Host 'Choose a password to protect the escrow .pfx' -AsSecureString
    }
    if ((Test-Path -LiteralPath $PfxPath) -and -not $Force) {
        StepFail "PFX destination already exists ($PfxPath). Move it aside or use -Force."
        exit 1
    }
    if ($Force -and (Test-Path -LiteralPath $PfxPath)) { Remove-Item -LiteralPath $PfxPath -Force }
    try {
        & (Join-Path $root 'admin\Rotate-EscrowKey.ps1') -NewPrivateKeyPath $PfxPath -PfxPassword $PfxPassword
        StepOK "Escrow keypair generated. Public cert: $certPath"
        Say  "       KEEP THE PRIVATE KEY SAFE: $PfxPath"
        Say  "       It is the ONLY way to recover a client's password. Store it offline"
        Say  "       (a safe, a USB in a drawer) and make a second copy off-site."
    } catch {
        StepFail "Escrow key generation failed: $($_.Exception.Message)"
        exit 1
    }
}

# --- Step 6: publish the client list ---------------------------------------
if ($SkipClientPublish) {
    StepSkip "Client list not published (run admin\Publish-Clients.ps1 later)."
} elseif (-not $ClientSource) {
    if (Test-Path -LiteralPath $ClientListPath) {
        StepSkip "No -ClientSource given; existing client list left in place ($ClientListPath)."
    } else {
        StepFail "No client list at $ClientListPath and no -ClientSource to publish one from."
        Say 'Provide -ClientSource <master xlsx/csv>, or -SkipClientPublish and create it later.'
    }
} else {
    try {
        & (Join-Path $root 'admin\Publish-Clients.ps1') -Source $ClientSource -Destination $ClientListPath
        StepOK "Published client list to $ClientListPath."
    } catch {
        StepFail "Publishing clients failed: $($_.Exception.Message)"
    }
}

# --- Step 7: final health report -------------------------------------------
Say ''
Say '=== Health check ==='
$health = Test-CuroHealth -Path $settingsTarget
if ($health.Healthy) {
    StepOK 'All health checks passed.'
} else {
    foreach ($i in $health.Issues) {
        StepFail "$($i.Component): $($i.Message)"
        Say     "       -> $($i.NextStep)"
    }
}

Say ''
if ($script:failed -or -not $health.Healthy) {
    Say 'Setup finished with problems - see [FAIL] lines above.'
    exit 1
}
Say 'Setup complete. The tool is ready to use.'
if ($Mode -eq 'Install') {
    Say 'Right-click any PDF in Explorer -> "Protect with password".'
} else {
    Say "Drag PDFs onto PasswordProtect.cmd in $root (or double-click it)."
}
exit 0
