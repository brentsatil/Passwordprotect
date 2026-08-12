#Requires -Version 5.1
<#
.SYNOPSIS
    Entry point invoked by Explorer right-click "Remove password protection".
.DESCRIPTION
    Produces an unprotected copy of a protected PDF, given its password.
    qpdf --decrypt clears the open password AND every restriction (printing,
    copying, editing), so this one action covers both.

    The password has to be supplied - there is no bypass, by design. For a file
    this tool protected the password IS the client's date of birth, so the same
    client picker used to protect a file supplies it: pick the client, and their
    DOB is used. A typed password also works, for PDFs from providers or clients
    that this tool never touched.

    No escrow record is written (there is no new password to recover), which
    makes the audit row the only trace - so it is written on success AND on
    failure. An unprotected copy of a client document is exactly the event a
    compliance reviewer would want to find.

    Registered with -WindowStyle Hidden, so EVERY failure path must end in a
    visible dialog plus a log record (see Show-CuroError.ps1).
.PARAMETER Path
    The file selected in Explorer.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path
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
            'This PC is not set up for Curo PDF Protector yet, so nothing was changed.'
            ''
            $_.Exception.Message
            ''
            'Ask whoever looks after the tool to finish the setup.'
            "Details were saved to: $log"
        ) -join [Environment]::NewLine)
        exit 2
    }

    # Refuse before asking for a password, so a site that has switched this off
    # does not make the user type one for nothing.
    if ($config.PSObject.Properties['allow_password_removal'] -and -not $config.allow_password_removal) {
        Write-AuditEvent -Config $config -Fields @{ op='unprotect'; outcome='fail'; error_code='NOT_PERMITTED'; src_path=$Path }
        Show-CuroError -Title 'Curo PDF Protector' -Icon Warning -Message (
            'Removing password protection is switched off for this deployment.' + [Environment]::NewLine + [Environment]::NewLine +
            'Ask whoever looks after the tool if you need an unprotected copy.')
        exit 2
    }

    Write-Heartbeat -Operation 'unprotect' -Config $config

    $clientList = Get-ClientList -Config $config
    if ($clientList.HardFail) {
        Show-CuroError -Title 'Client list warning' -Icon Warning -Message (
            "The client list is unavailable or out of date. $($clientList.Warning)" + [Environment]::NewLine + [Environment]::NewLine +
            'You can still type the password manually in the next dialog.')
    }

    # Same picker as protecting. -RequireClientDob is deliberately NOT passed:
    # a provider's PDF has a password that is not any client's date of birth,
    # and refusing to accept one typed would make this useless for those.
    $prompt = & (Join-Path $here 'Prompt-Password.ps1') `
        -Config $config `
        -ClientList $clientList `
        -FilePath $Path `
        -Purpose Unprotect

    if ($prompt.Cancelled) {
        Write-AuditEvent -Config $config -Fields @{ op='unprotect'; outcome='cancel'; src_path=$Path }
        exit 0
    }

    try {
        $result = Invoke-UnprotectFileCore -Config $config -Path $Path -PromptResult $prompt
        if (-not $result.Success) {
            Show-CuroError -Title 'Curo PDF Protector' -Icon Error -Message $result.Message
        } else {
            # Always shown, even when show_success_dialog is off for protecting:
            # the user has just created an UNENCRYPTED copy of a client document
            # and should be told plainly where it is.
            Show-CuroError -Title 'Curo PDF Protector' -Icon Warning -Message $result.Message
        }
        exit $result.ExitCode
    } finally {
        if ($prompt -and $prompt.SecurePassword) { $prompt.SecurePassword.Dispose() }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
} catch {
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
