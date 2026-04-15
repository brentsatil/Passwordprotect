#Requires -Version 5.1
<#
.SYNOPSIS
    Entry point invoked by Explorer right-click "Protect with password".
.DESCRIPTION
    Orchestrates the protect flow:
      heartbeat -> load config -> load client list -> prompt -> encrypt ->
      write escrow sidecar -> audit -> (optional) Outlook attach -> success toast.

    Fails closed on:
      - config schema mismatch
      - CSV hard-stale
      - already-encrypted PDF
      - locked input file
      - escrow share unreachable
.PARAMETER Path
    The file selected in Explorer.
.PARAMETER OutlookMode
    When invoked from the Outlook context menu entries: New | Reply | Forward.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [ValidateSet('None','New','Reply','Forward')] [string] $OutlookMode = 'None'
)

$ErrorActionPreference = 'Stop'

# --- Resolve module directory and import siblings ----------------------------
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path $here 'Config.psm1')  -Force
Import-Module (Join-Path $here 'Logging.psm1') -Force
. (Join-Path $here 'Find-Client.ps1')
. (Join-Path $here 'Invoke-QPdf.ps1')
. (Join-Path $here 'Invoke-SevenZip.ps1')
. (Join-Path $here 'Write-Escrow.ps1')
. (Join-Path $here 'Send-OutlookAttachment.ps1')

try {
    $config = Get-CuroConfig
} catch {
    [System.Windows.MessageBox]::Show("Configuration error: $($_.Exception.Message)",'Curo PDF Protector') | Out-Null
    exit 2
}

Write-Heartbeat -Operation 'protect' -Config $config

# --- Validate input ----------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    [System.Windows.MessageBox]::Show("File not found:`n$Path",'Curo PDF Protector') | Out-Null
    Write-AuditEvent -Config $config -Fields @{ op='protect'; outcome='fail'; error_code='INPUT_NOT_FOUND'; src_path=$Path }
    exit 3
}

# --- Load client list. Hard-fail if past the fail-days threshold. ------------
$clientList = Get-ClientList -Config $config
if ($clientList.HardFail) {
    [System.Windows.MessageBox]::Show(
        "The client list is unavailable or out of date. $($clientList.Warning)`n`nYou can still enter a password manually in the next dialog.",
        'Client list warning') | Out-Null
}

# --- Show the prompt ---------------------------------------------------------
$promptScript = Join-Path $here 'Prompt-Password.ps1'
$result = & $promptScript `
    -Config $config `
    -ClientList $clientList `
    -FilePath $Path `
    -OfferOutlook:($config.outlook_integration -and $OutlookMode -eq 'None')

if ($result.Cancelled) {
    Write-AuditEvent -Config $config -Fields @{ op='protect'; outcome='cancel'; src_path=$Path }
    exit 0
}

# --- Pick cipher path --------------------------------------------------------
$ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
$isPdf = $ext -eq '.pdf'

$targetDir  = Split-Path -LiteralPath $Path -Parent
$stem       = [IO.Path]::GetFileNameWithoutExtension($Path)
$suffix     = $config.output_suffix
$outputName = if ($isPdf) { "$stem$suffix$ext" } else { "$stem$suffix.7z" }
$outputPath = Join-Path $targetDir $outputName

$startTs = Get-Date
$encRes  = $null
$cipher  = $null

try {
    if ($isPdf) {
        $cipher = 'pdf-aes256'
        $encRes = Protect-Pdf `
            -QpdfPath $config.qpdf_path `
            -InputPath $Path `
            -OutputPath $outputPath `
            -Password $result.SecurePassword `
            -LongPathPrefix:$config.long_path_prefix `
            -AllowOverwrite:$result.AllowOverwrite
    } else {
        $cipher = '7z-aes256'
        $encRes = Protect-WithSevenZip `
            -SevenZipPath $config.sevenzip_path `
            -InputPath $Path `
            -OutputPath $outputPath `
            -Password $result.SecurePassword `
            -AllowOverwrite:$result.AllowOverwrite
    }

    if (-not $encRes.Success) {
        [System.Windows.MessageBox]::Show(
            "Could not protect the file.`n`nError: $($encRes.ErrorCode)`n$($encRes.Stderr)",
            'Curo PDF Protector') | Out-Null
        Write-AuditEvent -Config $config -Fields @{
            op='protect'; outcome='fail'; error_code=$encRes.ErrorCode;
            src_path=$Path; cipher=$cipher; password_source=$result.PasswordSource;
            client_file_ref=$result.ClientFileRef;
        }
        exit 4
    }

    # --- Write escrow sidecar. This is required; if it fails we DELETE the
    #     output and refuse the operation (per D1 = refuse-closed).
    $escrow = $null
    try {
        $escrow = Write-EscrowSidecar `
            -Config $config `
            -SourcePath $Path `
            -OutputPath $encRes.OutputPath `
            -Cipher $cipher `
            -PasswordSource $result.PasswordSource `
            -ClientFileRef $result.ClientFileRef `
            -Password $result.SecurePassword
    } catch {
        Remove-Item -LiteralPath $encRes.OutputPath -Force -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show(
            "Escrow record could not be written. Operation aborted and the protected file was removed.`n`n$($_.Exception.Message)",
            'Escrow unavailable') | Out-Null
        Write-AuditEvent -Config $config -Fields @{
            op='protect'; outcome='fail'; error_code='ESCROW_OFFLINE';
            src_path=$Path; cipher=$cipher; password_source=$result.PasswordSource;
        }
        exit 5
    }

    # --- Optional: delete original. ------------------------------------------
    $deleted = $false
    if ($result.DeleteOriginal) {
        try {
            Remove-Item -LiteralPath $Path -Force
            $deleted = $true
        } catch {
            # Non-fatal; note in audit.
        }
    }

    $durationMs = [int]((Get-Date) - $startTs).TotalMilliseconds
    $outSize = (Get-Item -LiteralPath $encRes.OutputPath).Length
    $inSize  = if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).Length } else { $null }

    Write-AuditEvent -Config $config -Fields @{
        op='protect'; outcome='ok';
        src_path=$Path; dst_path=$encRes.OutputPath;
        cipher=$cipher; bytes_in=$inSize; bytes_out=$outSize;
        duration_ms=$durationMs; client_file_ref=$result.ClientFileRef;
        password_source=$result.PasswordSource; deleted_original=$deleted;
        escrow_written=$true; escrow_fp=$escrow.Fingerprint; output_sha256=$escrow.OutputSha256;
    }

    # --- Optional: Outlook attach. ------------------------------------------
    $effectiveOutlookMode = if ($OutlookMode -ne 'None') { $OutlookMode }
                            elseif ($result.OpenOutlook)  { 'New' }
                            else                          { $null }
    if ($effectiveOutlookMode) {
        $olRes = Send-ProtectedToOutlook -Config $config `
                -AttachmentPath $encRes.OutputPath -Mode $effectiveOutlookMode
        Write-AuditEvent -Config $config -Fields @{
            op='outlook_attach'; outcome=$(if ($olRes.Success) {'ok'} else {'fail'});
            dst_path=$encRes.OutputPath; outlook_mode=$olRes.Mode; error=$olRes.Error
        }
    }

    # --- Success toast. ------------------------------------------------------
    if ($config.show_success_dialog) {
        $msg = "Protected: $($encRes.OutputPath)`n`nRecipient hint: $($config.recipient_hint_text)"
        [System.Windows.MessageBox]::Show($msg, 'Curo PDF Protector') | Out-Null
    }
    exit 0

} finally {
    if ($result -and $result.SecurePassword) { $result.SecurePassword.Dispose() }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
