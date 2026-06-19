#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone drag-and-drop "password protect" tool.

.DESCRIPTION
    Open it (double-click PasswordProtect.cmd) and a drop window appears, or
    drag files straight onto PasswordProtect.cmd. For every file dropped:
      - PDFs            -> a real password-protected PDF (AES-256, via qpdf).
      - everything else -> an encrypted .7z archive   (AES-256, via 7-Zip).
    A single popup asks for a date of birth; that DOB (DDMMYYYY) becomes the
    password for every file in the drop. Each protected copy is written into
    the SAME folder as the original; the original is kept.

    This is the lightweight personal cousin of the enterprise tool in this
    repo: it reuses the encryption engine (Protect-Pdf / Protect-WithSevenZip)
    but deliberately skips escrow, the client CSV, Outlook and audit logging.

.NOTES
    Run with -STA (WPF requirement); PasswordProtect.cmd does this for you.
    Pure helpers (Format-DobPassword, Get-OutputPath, Resolve-Settings) are
    exercised by tests/PasswordProtect.Tests.ps1 without invoking the binaries.
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Files
)

$ErrorActionPreference = 'Stop'
$script:Here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- Engine (reused, dot-sourced) -------------------------------------------
$script:SrcDir = Join-Path $script:Here 'src'
. (Join-Path $script:SrcDir 'Invoke-QPdf.ps1')
. (Join-Path $script:SrcDir 'Invoke-SevenZip.ps1')

# ---------------------------------------------------------------------------
# Pure helpers (no WPF, no binaries) — kept testable.
# ---------------------------------------------------------------------------

function Format-DobPassword {
    <#
    .SYNOPSIS
        Build a DDMMYYYY password string from numeric day/month/year.
        Throws on out-of-range values so the dialog can show a message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Day,
        [Parameter(Mandatory)] [int] $Month,
        [Parameter(Mandatory)] [int] $Year
    )
    if ($Day   -lt 1 -or $Day   -gt 31)   { throw "Day must be between 1 and 31." }
    if ($Month -lt 1 -or $Month -gt 12)   { throw "Month must be between 1 and 12." }
    if ($Year  -lt 1900 -or $Year -gt 9999) { throw "Year must be a 4-digit year (1900 or later)." }
    return ('{0:D2}{1:D2}{2:D4}' -f $Day, $Month, $Year)
}

function Get-OutputPath {
    <#
    .SYNOPSIS
        Destination next to the original. PDFs keep their extension;
        everything else becomes a .7z. Mirrors src/Protect.psm1 naming.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InputPath,
        [string] $Suffix = '_protected'
    )
    $dir  = Split-Path -LiteralPath $InputPath -Parent
    $stem = [IO.Path]::GetFileNameWithoutExtension($InputPath)
    $ext  = [IO.Path]::GetExtension($InputPath)
    $name = if ($ext -ieq '.pdf') { "$stem$Suffix$ext" } else { "$stem$Suffix.7z" }
    return (Join-Path $dir $name)
}

function Resolve-Settings {
    <#
    .SYNOPSIS
        Locate qpdf.exe / 7z.exe and read naming options. Probe order:
          1. bundled bin\ next to this script (the normal, self-contained case)
          2. paths in config\settings.default.json (enterprise install)
          3. qpdf / 7z on PATH
        Throws a clear, user-facing message if a binary cannot be found.
    .OUTPUTS
        @{ QpdfPath; SevenZipPath; OutputSuffix; LongPathPrefix; AllowOverwrite }
    #>
    [CmdletBinding()]
    param([string] $BaseDir = $script:Here)

    # Defaults match config/settings.default.json.
    $suffix         = '_protected'
    $longPathPrefix = $true
    $allowOverwrite = $false
    $cfgQpdf        = $null
    $cfgSeven       = $null

    $cfgPath = Join-Path (Join-Path $BaseDir 'config') 'settings.default.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            if ($cfg.output_suffix)   { $suffix = [string]$cfg.output_suffix }
            if ($null -ne $cfg.long_path_prefix) { $longPathPrefix = [bool]$cfg.long_path_prefix }
            if ($null -ne $cfg.allow_overwrite)  { $allowOverwrite = [bool]$cfg.allow_overwrite }
            if ($cfg.qpdf_path)      { $cfgQpdf  = [Environment]::ExpandEnvironmentVariables([string]$cfg.qpdf_path) }
            if ($cfg.sevenzip_path)  { $cfgSeven = [Environment]::ExpandEnvironmentVariables([string]$cfg.sevenzip_path) }
        } catch {
            # Malformed config is non-fatal; fall back to bundled bin\.
        }
    }

    $binDir = Join-Path $BaseDir 'bin'
    $qpdf  = Resolve-Binary -Name 'qpdf.exe' -BundledPath (Join-Path $binDir 'qpdf.exe') -ConfigPath $cfgQpdf  -CommandName 'qpdf'
    $seven = Resolve-Binary -Name '7z.exe'   -BundledPath (Join-Path $binDir '7z.exe')   -ConfigPath $cfgSeven -CommandName '7z'

    return @{
        QpdfPath       = $qpdf
        SevenZipPath   = $seven
        OutputSuffix   = $suffix
        LongPathPrefix = $longPathPrefix
        AllowOverwrite = $allowOverwrite
    }
}

function Resolve-Binary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $BundledPath,
        [string] $ConfigPath,
        [string] $CommandName
    )
    if (Test-Path -LiteralPath $BundledPath) { return $BundledPath }
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) { return $ConfigPath }
    if ($CommandName) {
        $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "$Name not found. Expected it at:`n  $BundledPath`nReinstall the tool or place $Name there."
}

function Invoke-ProtectOne {
    <#
    .SYNOPSIS
        Protect a single file. Returns a friendly per-file result for the
        summary dialog. Never throws on an encryption failure.
    .OUTPUTS
        @{ Path; Success; Message }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [System.Security.SecureString] $Password,
        [Parameter(Mandatory)] $Settings
    )

    $name = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ Path = $Path; Success = $false; Message = "$name — not a file, skipped" }
    }

    $out = Get-OutputPath -InputPath $Path -Suffix $Settings.OutputSuffix
    $ext = [IO.Path]::GetExtension($Path)

    if ($ext -ieq '.pdf') {
        $res = Protect-Pdf -QpdfPath $Settings.QpdfPath -InputPath $Path -OutputPath $out `
            -Password $Password -LongPathPrefix:$Settings.LongPathPrefix -AllowOverwrite:$Settings.AllowOverwrite
    } else {
        $res = Protect-WithSevenZip -SevenZipPath $Settings.SevenZipPath -InputPath $Path -OutputPath $out `
            -Password $Password -AllowOverwrite:$Settings.AllowOverwrite
    }

    if ($res.Success) {
        return @{ Path = $Path; Success = $true; Message = "$name -> $(Split-Path -Leaf $res.OutputPath)" }
    }

    $reason = switch ($res.ErrorCode) {
        'PRE_ENCRYPTED' { 'already password-protected — skipped' }
        'FILE_LOCKED'   { 'file is open in another program — close it and retry' }
        default {
            if ($res.Stderr -match 'exists') { "a $($Settings.OutputSuffix) copy already exists" }
            else { 'could not protect (engine error)' }
        }
    }
    return @{ Path = $Path; Success = $false; Message = "$name — $reason" }
}

# ---------------------------------------------------------------------------
# Main (guarded so dot-sourcing in tests does not run it).
# ---------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding()]
    param([string[]] $InputFiles)

    Add-Type -AssemblyName PresentationFramework

    # 1. Resolve binaries up front; clear error if missing.
    try {
        $settings = Resolve-Settings
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Password Protect — setup problem',
            'OK', 'Error') | Out-Null
        return 2
    }

    # 2. Gather files: from args, or via the drop window.
    $paths = @($InputFiles | Where-Object { $_ })
    if ($paths.Count -eq 0) {
        $paths = @(& (Join-Path $script:SrcDir 'Prompt-Drop.ps1'))
    }
    $paths = @($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($paths.Count -eq 0) { return 0 }   # nothing to do / user closed window

    # 3. Ask for the date of birth once for the whole batch.
    $dob = & (Join-Path $script:SrcDir 'Prompt-Dob.ps1') -FileCount $paths.Count
    if ($dob.Cancelled -or -not $dob.SecurePassword) { return 0 }

    # 4. Protect each file.
    $results = @()
    try {
        foreach ($p in $paths) {
            $results += Invoke-ProtectOne -Path $p -Password $dob.SecurePassword -Settings $settings
        }
    } finally {
        if ($dob.SecurePassword) { $dob.SecurePassword.Dispose() }
        [GC]::Collect()
    }

    # 5. Summary dialog.
    $ok   = @($results | Where-Object { $_.Success })
    $bad  = @($results | Where-Object { -not $_.Success })
    $lines = @()
    $lines += "Protected $($ok.Count) of $($results.Count) file(s)."
    if ($ok.Count)  { $lines += ''; $lines += ($ok  | ForEach-Object { "  OK   $($_.Message)" }) }
    if ($bad.Count) { $lines += ''; $lines += ($bad | ForEach-Object { "  SKIP $($_.Message)" }) }
    $icon = if ($bad.Count -and -not $ok.Count) { 'Error' } elseif ($bad.Count) { 'Warning' } else { 'Information' }
    [System.Windows.MessageBox]::Show(($lines -join "`n"), 'Password Protect', 'OK', $icon) | Out-Null

    return $(if ($bad.Count -and -not $ok.Count) { 1 } else { 0 })
}

# Only run when executed directly (not when dot-sourced by tests).
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Main -InputFiles $Files)
}
