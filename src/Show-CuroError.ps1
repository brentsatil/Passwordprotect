#Requires -Version 5.1
<#
.SYNOPSIS
    Reliable failure logging + user notification for every entry point.
.DESCRIPTION
    The Explorer context-menu shims run with -WindowStyle Hidden, so an
    unreported failure looks like "right-click did nothing" to the user.
    These helpers make that impossible:

      Write-CuroShimLog - appends a full diagnostic record to a log under
                          %LOCALAPPDATA%\CuroPDFProtect. That location is
                          always writable and needs no config, so it works
                          on the exact failure it exists for (unconfigured
                          or broken machine).
      Show-CuroError    - shows a message box that works from a hidden
                          process: WPF first (with DefaultDesktopOnly so
                          the box cannot open behind Explorer), then a raw
                          user32 MessageBoxW P/Invoke fallback that needs
                          no framework assemblies and works from any
                          apartment state.

    Set CURO_SUPPRESS_UI=1 to skip all UI. CI relies on this: a modal
    dialog on a headless runner would hang the job until its timeout.

    Neither function ever throws, and neither ever receives or records
    password material (passwords live only in SecureStrings elsewhere).
#>

function Get-CuroShimLogPath {
    $dir = Join-Path $env:LOCALAPPDATA 'CuroPDFProtect'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'error.log')
}

function Write-CuroShimLog {
    <#
    .SYNOPSIS
        Append a diagnostic record for a failure and return the log path
        (so callers can name it in the dialog they show next).
    #>
    param(
        [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [string] $Message,
        [string] $LogPath
    )
    if (-not $LogPath) {
        try { $LogPath = Get-CuroShimLogPath } catch { return $null }
    }
    try {
        $lines = @("==== Curo PDF Protector failure $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====")
        $lines += "PowerShell : $($PSVersionTable.PSVersion)"
        $lines += "OS         : $([Environment]::OSVersion.VersionString)"
        $lines += "Process    : PID $PID  User $env:USERDOMAIN\$env:USERNAME"
        if ($Message) { $lines += "Message    : $Message" }
        if ($ErrorRecord) {
            $lines += "Error      : $($ErrorRecord.Exception.Message)"
            $lines += "Type       : $($ErrorRecord.Exception.GetType().FullName)"
            $lines += "Where      : $($ErrorRecord.InvocationInfo.ScriptName):$($ErrorRecord.InvocationInfo.ScriptLineNumber)"
            $lines += "StackTrace :"
            $lines += $ErrorRecord.ScriptStackTrace
            $lines += $ErrorRecord.Exception.ToString()
        }
        $lines += ''
        Add-Content -LiteralPath $LogPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    } catch { }
    return $LogPath
}

function Show-CuroError {
    <#
    .SYNOPSIS
        Show a message box that cannot fail silently, even from a hidden
        process that has loaded no UI assemblies.
    #>
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Error','Warning','Information')] [string] $Icon = 'Error'
    )
    if ($env:CURO_SUPPRESS_UI -eq '1') { return }

    # Preferred: WPF. DefaultDesktopOnly forces the box onto the desktop
    # on top of other windows - a hidden process owns no window to parent
    # to, and without it the dialog can open behind Explorer and look like
    # a hang.
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show(
            $Message, $Title,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]$Icon,
            [System.Windows.MessageBoxResult]::OK,
            [System.Windows.MessageBoxOptions]::DefaultDesktopOnly) | Out-Null
        return
    } catch { }

    # Terminal fallback: raw user32 MessageBoxW. Works from any apartment
    # state and needs nothing loaded. MB_SETFOREGROUND + MB_TOPMOST keep it
    # visible from a hidden process.
    try {
        if (-not ('CuroPDFProtect.NativeMsgBox' -as [type])) {
            Add-Type -Namespace CuroPDFProtect -Name NativeMsgBox -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
'@
        }
        $mbIcon = switch ($Icon) {
            'Error'       { 0x10 }
            'Warning'     { 0x30 }
            'Information' { 0x40 }
        }
        $flags = [uint32](0x0 -bor $mbIcon -bor 0x10000 -bor 0x40000)  # MB_OK | icon | MB_SETFOREGROUND | MB_TOPMOST
        [CuroPDFProtect.NativeMsgBox]::MessageBoxW([IntPtr]::Zero, $Message, $Title, $flags) | Out-Null
    } catch { }
}
