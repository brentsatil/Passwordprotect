#Requires -Version 5.1
<#
.SYNOPSIS
    Entry point invoked by Explorer right-click "Protect with password".
.DESCRIPTION
    Thin shim: load config, load client list, prompt, delegate to
    Invoke-ProtectFileCore (in Protect.psm1), show result, exit.
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

Import-Module (Join-Path $here 'Config.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $here 'Logging.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Protect.psm1') -Force -DisableNameChecking
. (Join-Path $here 'Find-Client.ps1')

try {
    $config = Get-CuroConfig
} catch {
    [System.Windows.MessageBox]::Show("Configuration error: $($_.Exception.Message)",'Curo PDF Protector') | Out-Null
    exit 2
}

Write-Heartbeat -Operation 'protect' -Config $config

$clientList = Get-ClientList -Config $config
if ($clientList.HardFail) {
    [System.Windows.MessageBox]::Show(
        "The client list is unavailable or out of date. $($clientList.Warning)`n`nYou can still enter a password manually in the next dialog.",
        'Client list warning') | Out-Null
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
        [System.Windows.MessageBox]::Show($result.Message, 'Curo PDF Protector') | Out-Null
    } elseif ($config.show_success_dialog) {
        $msg = "$($result.Message)`n`nRecipient hint: $($config.recipient_hint_text)"
        [System.Windows.MessageBox]::Show($msg, 'Curo PDF Protector') | Out-Null
    }
    exit $result.ExitCode
} finally {
    if ($prompt -and $prompt.SecurePassword) { $prompt.SecurePassword.Dispose() }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
