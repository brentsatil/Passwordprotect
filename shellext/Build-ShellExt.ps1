#Requires -Version 5.1
<#
.SYNOPSIS
    Build the Windows 11 modern context-menu handler and its sparse MSIX.
.DESCRIPTION
    Produces, in -OutputDir:
      CuroShellExt.dll   the IExplorerCommand COM server (native x64)
      CuroPDFProtect.msix  the sparse package that supplies package identity

    Windows 11 requires BOTH to show a command in the default context menu -
    see docs\DECISIONS.md #26. Neither is needed on Windows 10, where the
    legacy registry verbs install.ps1 writes are still the right mechanism.

    A sparse package cannot be installed unsigned. With no certificate supplied
    this script generates a self-signed one, which is fine for an internal
    deployment provided the certificate is trusted on each PC -
    Install-ShellExt.ps1 does that. For a cleaner story use a real certificate
    (Azure Artifact Signing is ~$10/month and needs no hardware token).

.PARAMETER OutputDir      Where to place the built artefacts.
.PARAMETER LauncherExe    PasswordProtect.exe to stage beside the DLL. The
                          handler resolves it relative to its own location.
.PARAMETER CertThumbprint Existing signing cert in Cert:\CurrentUser\My.
.PARAMETER CertPfx        Signing cert .pfx (with -CertPfxPassword).
.PARAMETER SkipSign       Build and pack only. The package will NOT install.
#>

[CmdletBinding()]
param(
    [string] $OutputDir = (Join-Path $PSScriptRoot 'out'),
    [string] $LauncherExe,
    [string] $CertThumbprint,
    [string] $CertPfx,
    [string] $CertPfxPassword,
    [switch] $SkipSign
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent $here

function Step($m) { Write-Host "[build] $m" }

# --- the CLSID and publisher must agree across three files ------------------
# A mismatch here fails at install time with an opaque signature or activation
# error, so check it at build time where the message can be useful.
$srcPath = Join-Path $here 'CuroShellExt\dllmain.cpp'
$manPath = Join-Path $here 'package\AppxManifest.xml'
$src = Get-Content -LiteralPath $srcPath -Raw
$man = Get-Content -LiteralPath $manPath -Raw

if ($src -notmatch '(?im)^\s*//\s*\{([0-9A-F-]{36})\}') { throw "Could not find the CLSID comment in $srcPath" }
$srcClsid = $Matches[1].ToUpperInvariant()

$manClsids = [regex]::Matches($man, '(?i)(?:Id|Clsid)="\{?([0-9A-F-]{36})\}?"') |
             ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Sort-Object -Unique
if ($manClsids.Count -ne 1)      { throw "Expected exactly one CLSID in the manifest, found: $($manClsids -join ', ')" }
if ($manClsids[0] -ne $srcClsid) { throw "CLSID mismatch: dllmain.cpp has $srcClsid, AppxManifest.xml has $($manClsids[0])" }
Step "CLSID $srcClsid consistent across source and manifest."

if ($man -notmatch 'Publisher="([^"]+)"') { throw 'No Publisher in AppxManifest.xml' }
$publisher = $Matches[1]
Step "Package publisher: $publisher"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# --- locate the MSVC and SDK tooling ----------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found - Visual Studio Build Tools with the C++ workload are required.' }
$vsRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'No Visual Studio installation with the C++ toolset was found.' }
$vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vsRoot" }
Step "MSVC: $vsRoot"

# --- compile the COM server -------------------------------------------------
$dll = Join-Path $OutputDir 'CuroShellExt.dll'
$obj = Join-Path $OutputDir 'obj'
New-Item -ItemType Directory -Force -Path $obj | Out-Null

# /permissive- for conformant C++, /GS for stack cookies, /guard:cf for CFG -
# this DLL is loaded into Explorer, so it gets the hardening flags.
$clArgs = @(
    '/nologo','/c','/EHsc','/O2','/MD','/W4','/permissive-','/GS','/guard:cf',
    '/DUNICODE','/D_UNICODE','/DWIN32_LEAN_AND_MEAN',
    "/Fo:$obj\dllmain.obj",
    "`"$(Join-Path $here 'CuroShellExt\dllmain.cpp')`""
) -join ' '
$linkArgs = @(
    '/nologo','/DLL','/guard:cf','/DYNAMICBASE','/NXCOMPAT',
    "/DEF:`"$(Join-Path $here 'CuroShellExt\CuroShellExt.def')`"",
    "/OUT:`"$dll`"",
    "`"$obj\dllmain.obj`"",
    'ole32.lib','oleaut32.lib','shlwapi.lib','uuid.lib','user32.lib','advapi32.lib'
) -join ' '

$bat = Join-Path $OutputDir '_build.cmd'
@(
    '@echo off'
    "call `"$vcvars`" >nul || exit /b 1"
    "cl $clArgs || exit /b 1"
    "link $linkArgs || exit /b 1"
) | Set-Content -LiteralPath $bat -Encoding ascii

& cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Native build failed (exit $LASTEXITCODE)." }
if (-not (Test-Path $dll)) { throw 'CuroShellExt.dll was not produced.' }
Step ("Built CuroShellExt.dll ({0:N0} bytes)" -f (Get-Item $dll).Length)

# --- stage the package layout -----------------------------------------------
# Sparse package: the manifest is packed alone; the payload lives at the
# external location. The DLL and exe are staged into OutputDir, which is what
# Install-ShellExt.ps1 passes as -ExternalLocation.
$layout = Join-Path $OutputDir '_layout'
Remove-Item -Recurse -Force $layout -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $layout 'Images') | Out-Null
Copy-Item -LiteralPath $manPath -Destination (Join-Path $layout 'AppxManifest.xml') -Force

# Minimal 1x1 PNG placeholders. The manifest must reference logos; a sparse
# package that never appears in the Start menu does not need real artwork.
$png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
foreach ($n in 'StoreLogo.png','Square150x150Logo.png','Square44x44Logo.png') {
    [System.IO.File]::WriteAllBytes((Join-Path $layout "Images\$n"), $png)
}

if ($LauncherExe) {
    if (-not (Test-Path -LiteralPath $LauncherExe)) { throw "LauncherExe not found: $LauncherExe" }
    Copy-Item -LiteralPath $LauncherExe -Destination (Join-Path $OutputDir 'PasswordProtect.exe') -Force
    Step 'Staged PasswordProtect.exe beside the handler.'
} else {
    Write-Warning 'No -LauncherExe supplied. Copy PasswordProtect.exe next to CuroShellExt.dll before installing, or the verb will do nothing.'
}

# --- pack --------------------------------------------------------------------
$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
$makeappx = Get-ChildItem -Path $sdkRoot -Filter 'makeappx.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } |
            Sort-Object FullName -Descending | Select-Object -First 1
if (-not $makeappx) { throw 'makeappx.exe not found - install the Windows SDK.' }

$msix = Join-Path $OutputDir 'CuroPDFProtect.msix'
Remove-Item -LiteralPath $msix -Force -ErrorAction SilentlyContinue
& $makeappx.FullName pack /d $layout /p $msix /nv /o
if ($LASTEXITCODE -ne 0) { throw "makeappx failed (exit $LASTEXITCODE)." }
Step "Packed $msix"

if ($SkipSign) {
    Write-Warning 'Package is UNSIGNED (-SkipSign). Windows will refuse to install it.'
    Step 'Done.'
    return
}

# --- sign --------------------------------------------------------------------
$signtool = Get-ChildItem -Path $sdkRoot -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } |
            Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe not found - install the Windows SDK.' }

$thumb = $CertThumbprint
$tempPfx = $null
if (-not $thumb -and -not $CertPfx) {
    # The certificate SUBJECT must match Identity/@Publisher exactly or the
    # install fails with a signature mismatch that says nothing useful.
    Step "No certificate supplied - generating a self-signed one for $publisher"
    $cert = New-SelfSignedCertificate -Type Custom -Subject $publisher `
        -KeyUsage DigitalSignature -FriendlyName 'Curo PDF Protector (self-signed)' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}Subject Type:End Entity')
    $thumb = $cert.Thumbprint
    $tempPfx = Join-Path $OutputDir 'CuroPDFProtect-selfsigned.pfx'
    $pw = ConvertTo-SecureString -String 'curo-selfsign' -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $tempPfx -Password $pw | Out-Null
    Export-Certificate -Cert $cert -FilePath (Join-Path $OutputDir 'CuroPDFProtect-selfsigned.cer') | Out-Null
    Step "Self-signed cert $thumb (public .cer exported for Install-ShellExt.ps1)."
}

if ($CertPfx) {
    & $signtool.FullName sign /fd SHA256 /a /f $CertPfx /p $CertPfxPassword $msix
} else {
    & $signtool.FullName sign /fd SHA256 /sha1 $thumb $msix
}
if ($LASTEXITCODE -ne 0) { throw "signtool failed (exit $LASTEXITCODE)." }

if ($tempPfx) { Remove-Item -LiteralPath ("Cert:\CurrentUser\My\$thumb") -Force -ErrorAction SilentlyContinue }

Step 'Signed.'
Step "Artefacts in $OutputDir - install with .\Install-ShellExt.ps1 -PackageDir '$OutputDir'"
