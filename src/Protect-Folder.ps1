#Requires -Version 5.1
<#
.SYNOPSIS
    Batch-protect every file in a folder using a single password.
.DESCRIPTION
    Invoked from the "Protect all files in folder" context-menu entry on
    folders. Shows ONE prompt, then applies the same password to each file
    by calling Invoke-ProtectFileCore in-process (so it does NOT hit the
    `exit` calls in Protect-File.ps1 — those would terminate the whole
    batch). Non-recursive by default. Skips already-produced _protected
    files and .escrow / .json sidecars.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [switch] $Recursive
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

Import-Module (Join-Path $here 'Config.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $here 'Logging.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Protect.psm1') -Force -DisableNameChecking
. (Join-Path $here 'Find-Client.ps1')

$config = Get-CuroConfig
Write-Heartbeat -Operation 'protect_folder' -Config $config

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    [System.Windows.MessageBox]::Show("Not a folder:`n$Path",'Curo PDF Protector') | Out-Null
    exit 3
}

$clientList = Get-ClientList -Config $config

$promptScript = Join-Path $here 'Prompt-Password.ps1'
$prompt = & $promptScript -Config $config -ClientList $clientList -FilePath "$Path\*"
if ($prompt.Cancelled) { exit 0 }

$files = Get-ChildItem -LiteralPath $Path -File -Recurse:$Recursive |
    Where-Object {
        $_.BaseName -notlike "*$($config.output_suffix)" -and
        $_.Extension -notin @('.escrow','.json') -and
        -not ($_.Name -like "*.escrow.json")
    }

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
[System.Windows.MessageBox]::Show($summary,'Curo PDF Protector') | Out-Null
exit $(if ($fail -gt 0) { 4 } else { 0 })
