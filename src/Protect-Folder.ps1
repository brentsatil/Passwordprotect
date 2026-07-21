#Requires -Version 5.1
<#
.SYNOPSIS
    Batch-protect every file in a folder using a single password.
.DESCRIPTION
    Invoked from the "Protect all files in folder" context-menu entry on
    folders. Shows ONE prompt, then applies the same password to each file
    by calling Invoke-ProtectFileCore in-process (so it does NOT hit the
    `exit` calls in Protect-File.ps1 - those would terminate the whole
    batch). Non-recursive by default. PDF-only; skips already-produced _protected files.

    Registered with -WindowStyle Hidden, so EVERY failure path must end in
    a visible dialog plus a log record (see Show-CuroError.ps1).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [switch] $Recursive
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

    Write-Heartbeat -Operation 'protect_folder' -Config $config

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Show-CuroError -Title 'Curo PDF Protector' -Icon Error -Message "Not a folder:`n$Path"
        exit 3
    }

    $clientList = Get-ClientList -Config $config
    if ($clientList.HardFail) {
        Show-CuroError -Title 'Client list warning' -Icon Warning -Message (
            "The client list is unavailable or out of date. $($clientList.Warning)`n`nYou can still enter a password manually in the next dialog.")
    }

    $promptScript = Join-Path $here 'Prompt-Password.ps1'
    $prompt = & $promptScript -Config $config -ClientList $clientList -FilePath "$Path\*"
    if ($prompt.Cancelled) { exit 0 }

    $files = Get-ChildItem -LiteralPath $Path -File -Recurse:$Recursive |
        Where-Object { $_.Extension -ieq '.pdf' -and $_.BaseName -notlike "*$($config.output_suffix)" }

    $ok = 0; $fail = 0; $firstError = $null

    try {
        foreach ($f in $files) {
            try {
                $r = Invoke-ProtectFileCore -Config $config -Path $f.FullName -PromptResult $prompt
                if ($r.Success) { $ok++ }
                else {
                    $fail++
                    if (-not $firstError) { $firstError = "$($f.Name): $($r.ErrorCode)" }
                    # If escrow is offline, the whole run will keep failing. Stop.
                    if ($r.ErrorCode -eq 'ESCROW_OFFLINE') { break }
                }
            } catch {
                $fail++
                if (-not $firstError) { $firstError = "$($f.Name): $($_.Exception.Message)" }
            }
        }
    } finally {
        if ($prompt -and $prompt.SecurePassword) { $prompt.SecurePassword.Dispose() }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }

    $summary = "Batch complete.`nProtected: $ok  Failed: $fail"
    if ($firstError) { $summary += "`nFirst error: $firstError" }
    $summaryIcon = if ($fail -gt 0) { 'Warning' } else { 'Information' }
    Show-CuroError -Title 'Curo PDF Protector' -Icon $summaryIcon -Message $summary
    exit $(if ($fail -gt 0) { 4 } else { 0 })
} catch {
    # Catch-all so nothing can die invisibly in the hidden window.
    $log = Write-CuroShimLog -ErrorRecord $_
    Show-CuroError -Title 'Curo PDF Protector - error' -Icon Error -Message (@(
        "Curo PDF Protector ran into a problem and couldn't finish the batch:"
        ''
        $_.Exception.Message
        ''
        "Details were saved to: $log"
        'Please send that file to whoever set this up.'
    ) -join [Environment]::NewLine)
    exit 2
}
