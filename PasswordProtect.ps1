#Requires -Version 5.1
<#
.SYNOPSIS
    PDF-only business password protection tool.

.DESCRIPTION
    Open it (double-click PasswordProtect.cmd) and a drop window appears, or
    drag files straight onto PasswordProtect.cmd. For every file dropped:
      - PDFs -> password-protected PDF (AES-256, via qpdf).
      - non-PDF files are rejected; business mode is PDF-only.
    For each PDF, the user selects the client from clients.csv; that client's
    DOB (DDMMYYYY) is used as the user password. Every protected output is
    audited and escrowed before the run is reported as successful.

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
# $PSScriptRoot is populated both when this file is run with -File and when it
# is dot-sourced by the tests, so it is the most reliable anchor for the
# sibling src\ and bin\ folders.
$script:Here   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:SrcDir = Join-Path $script:Here 'src'

# The encryption engine (Invoke-QPdf.ps1) and the WPF
# assemblies are loaded inside Invoke-Main rather than here, so that any
# failure to load them is caught by the entry-point handler and reported to
# the user instead of silently closing the window.

# ---------------------------------------------------------------------------
# Pure helpers (no WPF, no binaries) - kept testable.
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
        Destination next to the original as <stem>_protected.pdf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InputPath,
        [string] $Suffix = '_protected'
    )
    # NB: Split-Path -LiteralPath cannot be combined with -Parent (different
    # parameter sets in Windows PowerShell 5.1). Use the .NET API instead.
    $dir  = [System.IO.Path]::GetDirectoryName($InputPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($InputPath)
    $ext  = [IO.Path]::GetExtension($InputPath)
    if ($ext -ine '.pdf') { throw 'Only PDF files are supported.' }
    $name = "$stem$Suffix$ext"
    return (Join-Path $dir $name)
}

function Resolve-Settings {
    <#
    .SYNOPSIS
        Locate qpdf.exe and read naming options. Probe order:
          1. business config in %ProgramData%\CuroPDFProtect\settings.json
          2. bundled bin\ next to this script
          3. qpdf on PATH
        Throws a clear, user-facing message if a binary cannot be found.
    .OUTPUTS
        @{ QpdfPath; OutputSuffix; LongPathPrefix; AllowOverwrite }
    #>
    [CmdletBinding()]
    param([string] $BaseDir = $script:Here)

    # Defaults match config/settings.default.json.
    $suffix         = '_protected'
    $longPathPrefix = $true
    $allowOverwrite = $false
    $cfgQpdf        = $null


    $cfgPath = Join-Path (Join-Path $BaseDir 'config') 'settings.default.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            if ($cfg.output_suffix)   { $suffix = [string]$cfg.output_suffix }
            if ($null -ne $cfg.long_path_prefix) { $longPathPrefix = [bool]$cfg.long_path_prefix }
            if ($null -ne $cfg.allow_overwrite)  { $allowOverwrite = [bool]$cfg.allow_overwrite }
            if ($cfg.qpdf_path)      { $cfgQpdf  = [Environment]::ExpandEnvironmentVariables([string]$cfg.qpdf_path) }
        } catch {
            # Malformed config is non-fatal; fall back to bundled bin\.
        }
    }

    $binDir = Join-Path $BaseDir 'bin'
    $qpdf  = Resolve-Binary -Name 'qpdf.exe' -BundledPath (Join-Path $binDir 'qpdf.exe') -ConfigPath $cfgQpdf  -CommandName 'qpdf'

    return @{
        QpdfPath       = $qpdf
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


function Show-HealthScreen {
    param([Parameter(Mandatory)]$Health)
    $lines = @('Curo PDF Protector needs setup before it can protect PDFs.','')
    foreach ($i in $Health.Issues) {
        $lines += "[$($i.Component)] $($i.Message)"
        $lines += "Next step: $($i.NextStep)"
        $lines += ''
    }
    $lines += 'Nothing was protected. Business mode requires healthy config, qpdf, client list, audit logging, and escrow.'
    [System.Windows.MessageBox]::Show(($lines -join "`n"), 'Curo PDF Protector - setup required', 'OK', 'Warning') | Out-Null
}

# ---------------------------------------------------------------------------
# Main (guarded so dot-sourcing in tests does not run it).
# ---------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding()]
    param([string[]] $InputFiles)

    # WPF dialogs need these assemblies and an STA thread. Loading here (inside
    # the entry-point try/catch) means a missing/blocked WPF stack is reported.
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw ("PowerShell is not running in STA mode, which the dialogs require. " +
               "Start the tool with PasswordProtect.cmd (it passes -STA).")
    }

    # Preflight: the tool only works with its helper scripts and engine intact.
    foreach ($req in 'Invoke-QPdf.ps1','Prompt-Drop.ps1','Prompt-Password.ps1','Config.psm1','Protect.psm1','Find-Client.ps1') {
        $rp = Join-Path $script:SrcDir $req
        if (-not (Test-Path -LiteralPath $rp)) {
            throw ("Missing required file:`n  $rp`n`nThe program folder looks incomplete. " +
                   "Re-copy the whole PasswordProtect folder, keeping src\ and bin\ next to PasswordProtect.cmd.")
        }
    }

    # Engine (reused). Dot-sourced here so a load failure is reported, not fatal.
    . (Join-Path $script:SrcDir 'Invoke-QPdf.ps1')
    Import-Module (Join-Path $script:SrcDir 'Config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:SrcDir 'Protect.psm1') -Force -DisableNameChecking

    # 1. Business health: refuse closed if audit, escrow, config, qpdf, or clients are unhealthy.
    $health = Test-CuroHealth
    if (-not $health.Healthy) {
        Show-HealthScreen -Health $health | Out-Null
        return 2
    }
    $config = $health.Config

    # 2. Resolve binaries up front; clear error if missing.
    try {
        $settings = @{ QpdfPath=$config.qpdf_path; OutputSuffix=$config.output_suffix; LongPathPrefix=$config.long_path_prefix; AllowOverwrite=$config.allow_overwrite }
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Password Protect - setup problem',
            'OK', 'Error') | Out-Null
        return 2
    }

    # 3. Gather files: from args, or via the drop window.
    $paths = @($InputFiles | Where-Object { $_ })
    if ($paths.Count -eq 0) {
        $paths = @(& (Join-Path $script:SrcDir 'Prompt-Drop.ps1'))
    }
    $paths = @($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($paths.Count -eq 0) { return 0 }   # nothing to do / user closed window

    # 4. Load clients and require a client/DOB assignment for every PDF.
    . (Join-Path $script:SrcDir 'Find-Client.ps1')
    $clientList = Get-ClientList -Config $config
    if ($clientList.HardFail) {
        [System.Windows.MessageBox]::Show($clientList.Warning, 'Curo PDF Protector - client list unavailable', 'OK', 'Error') | Out-Null
        return 2
    }

    # 5. Protect each PDF with audit and escrow. Each row gets its own client picker
    # so unmatched/ambiguous files cannot be processed without manual resolution.
    $results = @()
    foreach ($p in $paths) {
        $prompt = & (Join-Path $script:SrcDir 'Prompt-Password.ps1') -Config $config -ClientList $clientList -FilePath $p -RequireClientDob
        if ($prompt.Cancelled) {
            $results += [pscustomobject]@{ Success=$false; Message="$(Split-Path -Leaf $p) - cancelled before client/DOB assignment" }
            continue
        }
        try {
            $results += Invoke-ProtectFileCore -Config $config -Path $p -PromptResult $prompt
        } finally {
            if ($prompt -and $prompt.SecurePassword) { $prompt.SecurePassword.Dispose() }
            [GC]::Collect()
        }
    }

    # 6. Summary dialog.
    $ok   = @($results | Where-Object { $_.Success })
    $bad  = @($results | Where-Object { -not $_.Success })
    $lines = @()
    $lines += "Protected $($ok.Count) of $($results.Count) file(s)."
    if ($ok.Count)  { $lines += ''; $lines += ($ok  | ForEach-Object { "  OK   $($_.Message)" }) }
    if ($bad.Count) { $lines += ''; $lines += ($bad | ForEach-Object { "  SKIP $($_.Message)" }) }
    $icon = if ($bad.Count -and -not $ok.Count) { 'Error' } elseif ($bad.Count) { 'Warning' } else { 'Information' }
    [System.Windows.MessageBox]::Show(($lines -join "`n"), 'Password Protect', 'OK', $icon) | Out-Null

    # The summary dialog has already told the user about any skipped files, so
    # this is a successful *run*. Non-zero exits are reserved for genuine
    # crashes (handled by the entry point) so the launcher only pauses then.
    return 0
}

function Write-CrashLog {
    <#
    .SYNOPSIS
        Append a full diagnostic record for an unhandled error so a failure is
        never invisible. Never records the password (it lives only in a
        SecureString and is never written here).
    #>
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)] [string] $LogPath
    )
    $apartment = try { [System.Threading.Thread]::CurrentThread.GetApartmentState() } catch { 'unknown' }
    $body = @(
        "==== PasswordProtect crash $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===="
        "PowerShell : $($PSVersionTable.PSVersion)   Apartment: $apartment"
        "OS         : $([Environment]::OSVersion.VersionString)"
        "Message    : $($ErrorRecord.Exception.Message)"
        "Type       : $($ErrorRecord.Exception.GetType().FullName)"
        "Where      : $($ErrorRecord.InvocationInfo.ScriptName):$($ErrorRecord.InvocationInfo.ScriptLineNumber)"
        "Command    : $($ErrorRecord.InvocationInfo.Line.Trim())"
        "StackTrace :"
        $ErrorRecord.ScriptStackTrace
        ''
        $ErrorRecord.Exception.ToString()
        ''
    ) -join [Environment]::NewLine
    try { Add-Content -LiteralPath $LogPath -Value $body -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------------------
# Entry point. Runs only when executed directly; the guard skips it when this
# file is dot-sourced (e.g. by the Pester tests). ANY unexpected failure is
# written to PasswordProtect-error.log AND shown in a dialog, so the window
# never just vanishes with no explanation.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    $script:LogPath = Join-Path $script:Here 'PasswordProtect-error.log'
    $exitCode = 0
    try {
        $exitCode = Invoke-Main -InputFiles $Files
    } catch {
        $exitCode = 99
        Write-CrashLog -ErrorRecord $_ -LogPath $script:LogPath
        $message = @(
            "Password Protect ran into a problem and couldn't finish:"
            ''
            $_.Exception.Message
            ''
            'A full report was saved next to the program at:'
            $script:LogPath
            ''
            'Please send that file to whoever set this up.'
        ) -join [Environment]::NewLine
        $shown = $false
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
            [System.Windows.MessageBox]::Show($message, 'Password Protect - error', 'OK', 'Error') | Out-Null
            $shown = $true
        } catch { }
        if (-not $shown) {
            Write-Host ''
            Write-Host $message -ForegroundColor Red
            Write-Host ''
        }
    }
    exit $exitCode
}
