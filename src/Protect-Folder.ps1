#Requires -Version 5.1
<#
.SYNOPSIS
    Batch-protect every file in a folder using a single password.
.DESCRIPTION
    Invoked from the "Protect all files in folder" context-menu entry on
    folders. Shows ONE prompt, then applies the same password to each file.
    Non-recursive by default. Skips output _protected files and existing
    already-encrypted PDFs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [switch] $Recursive
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path $here 'Config.psm1')  -Force
Import-Module (Join-Path $here 'Logging.psm1') -Force
. (Join-Path $here 'Find-Client.ps1')

$config = Get-CuroConfig
Write-Heartbeat -Operation 'protect_folder' -Config $config

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    [System.Windows.MessageBox]::Show("Not a folder:`n$Path",'Curo PDF Protector') | Out-Null
    exit 3
}

$clientList = Get-ClientList -Config $config

$promptScript = Join-Path $here 'Prompt-Password.ps1'
$result = & $promptScript -Config $config -ClientList $clientList -FilePath "$Path\*"
if ($result.Cancelled) { exit 0 }

$files = Get-ChildItem -LiteralPath $Path -File -Recurse:$Recursive |
    Where-Object { $_.Name -notmatch '\Q'+$config.output_suffix+'\E' -and $_.Extension -notin @('.escrow','.json') }

$ok = 0; $fail = 0; $skip = 0
foreach ($f in $files) {
    $args = @('-Path', $f.FullName)
    # Re-invoke Protect-File.ps1 in-process for full behaviour (escrow, audit).
    try {
        & (Join-Path $here 'Protect-File.ps1') @args
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++ }
    } catch { $fail++ }
}

$result.SecurePassword.Dispose()
[System.Windows.MessageBox]::Show("Batch complete.`nProtected: $ok  Failed: $fail",'Curo PDF Protector') | Out-Null
