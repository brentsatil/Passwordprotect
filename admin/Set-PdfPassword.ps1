#Requires -Version 5.1
<#
.SYNOPSIS
    Change the password on an already-protected PDF, in place, with a new
    escrow record.
.DESCRIPTION
    Admin-only on purpose, and it is rarely the right tool. If you still have
    the original unprotected document, correct the client list and protect it
    again - that is simpler and leaves no stale copy. This exists for the case
    where the unprotected original is gone and the file must be re-keyed.

    Requires the CURRENT password. There is no bypass. If nobody knows it and
    this tool produced the file, recover it first with admin\Recover-File.ps1.

    Fail-closed and reversible: the new escrow record is written while the
    original is still intact, and if escrow is unreachable the original is
    restored byte-for-byte. The OLD escrow record is left alone - it is a
    truthful record of a file that was sent.

    NOTE: a copy already sent to the client keeps opening with the OLD
    password. Changing the password here does not reach out and change theirs.

.PARAMETER Path
    The protected PDF to re-key. Modified in place.
.PARAMETER ClientRef
    Take the NEW password from this client's date of birth in the published
    client list - the same rule the rest of the tool uses.
.PARAMETER NewPassword
    Use this password instead of a client DOB.
.PARAMETER CurrentPassword
    The password that opens the file today. Prompted for if omitted.
.PARAMETER ConfigPath
    Explicit settings.json, for a machine where the usual probe will not find it.

.EXAMPLE
    .\Set-PdfPassword.ps1 -Path '\\server\clients\SoA_Smith_protected.pdf' -ClientRef C-00101
    # Prompts for the current password, re-keys to that client's DOB.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $ClientRef,
    [securestring] $NewPassword,
    [securestring] $CurrentPassword,
    [string] $ConfigPath
)

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $here = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $root = Split-Path -Parent $here
    Import-Module (Join-Path $root 'src\Config.psm1')  -Force -DisableNameChecking
    Import-Module (Join-Path $root 'src\Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'src\Protect.psm1') -Force -DisableNameChecking
    . (Join-Path $root 'src\Find-Client.ps1')

    $config = if ($ConfigPath) { Get-CuroConfig -Path $ConfigPath } else { Get-CuroConfig }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    if (-not $ClientRef -and -not $NewPassword) {
        throw 'Provide -ClientRef (use that client date of birth) or -NewPassword.'
    }
    if ($ClientRef -and $NewPassword) {
        throw 'Provide only one of -ClientRef or -NewPassword.'
    }

    $passwordSource = 'manual'
    $newSecure = $NewPassword
    if ($ClientRef) {
        $clientList = Get-ClientList -Config $config
        if ($clientList.HardFail) { throw "Client list unavailable: $($clientList.Warning)" }
        $client = @($clientList.Clients | Where-Object { $_.FileRef -eq $ClientRef })
        if ($client.Count -eq 0) { throw "No client with file_ref '$ClientRef' in $($clientList.Source)." }
        if ($client.Count -gt 1) { throw "More than one client has file_ref '$ClientRef' - fix the client list." }
        $newSecure = New-Object System.Security.SecureString
        foreach ($ch in ([string]$client[0].Dob).ToCharArray()) { $newSecure.AppendChar($ch) }
        $newSecure.MakeReadOnly()
        $passwordSource = 'dob'
        Write-Host "New password: date of birth for $($client[0].Display)"
    }

    if (-not $CurrentPassword) {
        $CurrentPassword = Read-Host 'Current password (the one that opens the file now)' -AsSecureString
    }

    # Matches the shape Invoke-ChangePasswordCore reads; SecurePassword is the NEW one.
    $prompt = [pscustomobject]@{
        SecurePassword = $newSecure
        PasswordSource = $passwordSource
        ClientFileRef  = $ClientRef
        DeleteOriginal = $false
        AllowOverwrite = $true
        OpenOutlook    = $false
        Cancelled      = $false
    }

    try {
        $result = Invoke-ChangePasswordCore -Config $config -Path $Path `
            -CurrentPassword $CurrentPassword -PromptResult $prompt
    } finally {
        if ($newSecure) { $newSecure.Dispose() }
        if ($CurrentPassword) { $CurrentPassword.Dispose() }
        [GC]::Collect()
    }

    Write-Host ''
    if ($result.Success) {
        Write-Host $result.Message -ForegroundColor Green
        Write-Host ''
        Write-Host 'Reminder: any copy the client already has still opens with the OLD' -ForegroundColor Yellow
        Write-Host 'password. Send them this file if they need the new one.' -ForegroundColor Yellow
    } else {
        Write-Host "FAILED ($($result.ErrorCode)): $($result.Message)" -ForegroundColor Red
    }
    exit $result.ExitCode
}
