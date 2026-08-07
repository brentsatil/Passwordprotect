#Requires -Version 5.1
<#
.SYNOPSIS
    Install the Windows 11 modern context-menu entry for Curo PDF Protector.
.DESCRIPTION
    Registers the sparse MSIX built by Build-ShellExt.ps1 so that "Protect with
    password" appears in the DEFAULT Windows 11 right-click menu rather than
    under "Show more options".

    Windows 11 only. On Windows 10 the legacy registry verbs written by
    install.ps1 are the correct mechanism and this script refuses to run.

    A sparse package cannot be installed unless Windows trusts its signature.
    With a self-signed certificate that means adding the certificate to the
    machine's Trusted People store, which needs administrator rights ONCE per
    PC. With a certificate from a trusted CA (e.g. Azure Artifact Signing) that
    step is unnecessary and this script can run without elevation.

.PARAMETER PackageDir
    The folder Build-ShellExt.ps1 wrote: CuroPDFProtect.msix, CuroShellExt.dll
    and PasswordProtect.exe. It becomes the package's external location, so it
    must stay put - put it somewhere permanent, not a temp folder.
.PARAMETER SkipCertTrust
    Do not touch the certificate store (use when the package is signed by a
    certificate the machine already trusts).
.PARAMETER NoExplorerRestart
    Do not restart Explorer. Microsoft documents that Explorer must be
    restarted before a newly installed shell extension loads, so the menu will
    not appear until the next sign-in.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PackageDir,
    [switch] $SkipCertTrust,
    [switch] $NoExplorerRestart
)

$ErrorActionPreference = 'Stop'

function Step($m)  { Write-Host "[OK]   $m" -ForegroundColor Green }
function Note($m)  { Write-Host "       $m" }
function Fail($m)  { Write-Host "[FAIL] $m" -ForegroundColor Red }

# --- Windows 11 only ---------------------------------------------------------
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 22000) {
    Fail "This needs Windows 11 (build 22000+); this PC is build $build."
    Note 'On Windows 10 the standard right-click entry from install.ps1 already'
    Note 'appears in the normal menu - nothing to do here.'
    exit 1
}
Step "Windows 11 detected (build $build)."

$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$msix = Join-Path $PackageDir 'CuroPDFProtect.msix'
$dll  = Join-Path $PackageDir 'CuroShellExt.dll'
$exe  = Join-Path $PackageDir 'PasswordProtect.exe'

foreach ($f in @($msix, $dll)) {
    if (-not (Test-Path -LiteralPath $f)) { Fail "Missing $f - run Build-ShellExt.ps1 first."; exit 1 }
}
if (-not (Test-Path -LiteralPath $exe)) {
    Fail "PasswordProtect.exe is not in $PackageDir."
    Note 'The menu entry launches it from beside the DLL, so it must live there.'
    exit 1
}
Step "Package folder: $PackageDir"

# The external location is baked in at registration time; a package registered
# from a temp folder breaks the moment that folder is cleaned up.
if ($PackageDir -like "$env:TEMP*" -or $PackageDir -like '*\AppData\Local\Temp\*') {
    Fail 'Refusing to register from a temp folder - the external location must be permanent.'
    Note 'Copy the folder somewhere durable (e.g. C:\Program Files\CuroPDFProtect\shellext) and retry.'
    exit 1
}

# --- trust the signing certificate -------------------------------------------
if (-not $SkipCertTrust) {
    $sig = Get-AuthenticodeSignature -LiteralPath $msix
    if ($sig.Status -eq 'Valid') {
        Step 'Package signature is already trusted by this machine.'
    } else {
        Note "Signature status: $($sig.Status) - the certificate is not yet trusted here."
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Fail 'Trusting the certificate needs an elevated PowerShell (once per PC).'
            Note 'Re-run this script as Administrator, or sign the package with a'
            Note 'certificate from a CA the machine already trusts.'
            exit 1
        }
        if (-not $sig.SignerCertificate) { Fail 'The package is not signed at all. Re-run Build-ShellExt.ps1 without -SkipSign.'; exit 1 }

        $cerPath = Join-Path $env:TEMP 'curo-shellext-signer.cer'
        [System.IO.File]::WriteAllBytes($cerPath, $sig.SignerCertificate.RawData)
        try {
            Import-Certificate -FilePath $cerPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
            Step "Trusted the signing certificate ($($sig.SignerCertificate.Subject))."
            Note 'Self-signed: this is a deliberate, per-machine trust decision.'
        } finally {
            Remove-Item -LiteralPath $cerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- register ----------------------------------------------------------------
try {
    Add-AppxPackage -Path $msix -ExternalLocation $PackageDir -ErrorAction Stop
    Step 'Registered the sparse package (package identity granted).'
} catch {
    Fail "Registration failed: $($_.Exception.Message)"
    Note 'Common causes: the certificate is not trusted (see above), the'
    Note 'Publisher in AppxManifest.xml does not match the signing certificate'
    Note 'subject, or sideloading is disabled by policy.'
    exit 1
}

$pkg = Get-AppxPackage -Name 'CuroFinancialServices.PDFProtector' -ErrorAction SilentlyContinue
if (-not $pkg) { Fail 'Package did not appear in Get-AppxPackage after registration.'; exit 1 }
Step "Installed $($pkg.PackageFullName)"

# --- Explorer restart ---------------------------------------------------------
if ($NoExplorerRestart) {
    Note 'Explorer NOT restarted - the entry appears after the next sign-in.'
} else {
    Note 'Restarting Explorer so the extension loads...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Step 'Explorer restarted.'
}

Write-Host ''
Step 'Done. Right-click a PDF - "Protect with password" should now be in the'
Note 'MAIN menu, not under "Show more options".'
Note ''
Note 'It is scoped to .pdf only, and greys out if the selection contains'
Note 'anything else - the tool is PDF-only by design.'
Note ''
Note 'The legacy right-click entries from install.ps1 (if present) still exist'
Note 'under "Show more options". Both run the same tool; uninstall.ps1 removes'
Note 'those, Uninstall-ShellExt.ps1 removes this one.'
