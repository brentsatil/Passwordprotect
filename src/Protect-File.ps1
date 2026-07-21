#Requires -Version 5.1
<#
.SYNOPSIS
    Entry point invoked by Explorer right-click "Protect with password".
.DESCRIPTION
    Thin shim: load config, load client list, prompt, delegate to
    Invoke-ProtectFileCore (in Protect.psm1), show result, exit.

    Registered with -WindowStyle Hidden, so EVERY failure path must end in
    a visible dialog plus a log record - an unhandled error here looks like
    "right-click did nothing" to the user (see Show-CuroError.ps1).
.PARAMETER Path
    The file selected in Explorer.
.PARAMETER OutlookMode
    When invoked from the Outlook context-menu entry: New | Reply | Forward.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [ValidateSet('None','New','Reply','Forward')] [string] $OutlookMode = 'None'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here 'Show-CuroError.ps1')

try {
    Import-Module (Join-Path $here 'Config.psm1')  -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Protect.psm1') -Force -DisableNameChecking
    . (Join-Path $here 'Find-Client.ps1')

    try {
        $config = Get-CuroConfig
    } catch {
        $log = Write-CuroShimLog -ErrorRecord $_
        Show-CuroError -Title 'Curo PDF Protector - setup required' -Icon Warning -Message (@(
            'This PC is not set up for Curo PDF Protector yet, so nothing was protected.'
            ''
            $_.Exception.Message
            ''
            'Ask whoever looks after the tool to finish the setup.'
            "Details were saved to: $log"
        ) -join [Environment]::NewLine)
        exit 2
    }

    Write-Heartbeat -Operation 'protect' -Config $config

    $clientList = Get-ClientList -Config $config
    if ($clientList.HardFail) {
        Show-CuroError -Title 'Client list warning' -Icon Warning -Message (
            "The client list is unavailable or out of date. $($clientList.Warning)`n`nYou can still enter a password manually in the next dialog.")
    }

    $promptScript = Join-Path $here 'Prompt-Password.ps1'
    $prompt = & $promptScript `
        -Config $config `
        -ClientList $clientList `
        -FilePath $Path `
        -OfferOutlook:($config.outlook_integration -and $OutlookMode -eq 'None')

    if ($prompt.Cancelled) {
        Write-AuditEvent -Config $config -Fields @{ op='protect'; outcome='cancel'; src_path=$Path }
        exit 0
    }

    try {
        $result = Invoke-ProtectFileCore -Config $config -Path $Path `
            -PromptResult $prompt -OutlookMode $OutlookMode

        if (-not $result.Success) {
            Show-CuroError -Title 'Curo PDF Protector' -Icon Error -Message $result.Message
        } elseif ($config.show_success_dialog) {
            $msg = "$($result.Message)`n`nRecipient hint: $($config.recipient_hint_text)"
            Show-CuroError -Title 'Curo PDF Protector' -Icon Information -Message $msg
        }
        exit $result.ExitCode
    } finally {
        if ($prompt -and $prompt.SecurePassword) { $prompt.SecurePassword.Dispose() }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
} catch {
    # Catch-all so nothing can die invisibly in the hidden window.
    $log = Write-CuroShimLog -ErrorRecord $_
    Show-CuroError -Title 'Curo PDF Protector - error' -Icon Error -Message (@(
        "Curo PDF Protector ran into a problem and couldn't finish:"
        ''
        $_.Exception.Message
        ''
        "Details were saved to: $log"
        'Please send that file to whoever set this up.'
    ) -join [Environment]::NewLine)
    exit 2
}
