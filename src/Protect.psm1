# Protect.psm1
# Core protect-one-file logic shared by Protect-File.ps1 (single file from
# Explorer) and Protect-Folder.ps1 (batch, one prompt, many files).
#
# NOTHING in this module calls `exit`. Callers decide how to terminate.

$script:here = $PSScriptRoot
. (Join-Path $script:here 'Find-Client.ps1')
. (Join-Path $script:here 'Invoke-QPdf.ps1')
. (Join-Path $script:here 'Invoke-SevenZip.ps1')
. (Join-Path $script:here 'Write-Escrow.ps1')
. (Join-Path $script:here 'Send-OutlookAttachment.ps1')
Import-Module (Join-Path $script:here 'Logging.psm1') -Force -DisableNameChecking

function Invoke-ProtectFileCore {
    <#
    .SYNOPSIS
        Encrypt one file + write the escrow sidecar + write audit entries.
    .OUTPUTS
        [pscustomobject] with:
          Success      [bool]
          ExitCode     [int]  (0 ok, 3 input not found, 4 encrypt failed,
                               5 escrow failed, 2 other)
          ErrorCode    [string] enum
          OutputPath   [string or $null]
          Message      [string] human-readable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $PromptResult,   # must carry SecurePassword et al.
        [ValidateSet('None','New','Reply','Forward')] [string] $OutlookMode = 'None'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-AuditEvent -Config $Config -Fields @{ op='protect'; outcome='fail'; error_code='INPUT_NOT_FOUND'; src_path=$Path }
        return [pscustomobject]@{ Success=$false; ExitCode=3; ErrorCode='INPUT_NOT_FOUND'; OutputPath=$null; Message="File not found: $Path" }
    }

    $ext        = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $isPdf      = $ext -eq '.pdf'
    $targetDir  = Split-Path -LiteralPath $Path -Parent
    $stem       = [IO.Path]::GetFileNameWithoutExtension($Path)
    $suffix     = $Config.output_suffix
    $outputName = if ($isPdf) { "$stem$suffix$ext" } else { "$stem$suffix.7z" }
    $outputPath = Join-Path $targetDir $outputName

    $startTs = Get-Date
    $cipher  = $null
    $encRes  = $null

    if ($isPdf) {
        $cipher = 'pdf-aes256'
        $encRes = Protect-Pdf `
            -QpdfPath $Config.qpdf_path `
            -InputPath $Path `
            -OutputPath $outputPath `
            -Password $PromptResult.SecurePassword `
            -LongPathPrefix:$Config.long_path_prefix `
            -AllowOverwrite:$PromptResult.AllowOverwrite
    } else {
        $cipher = '7z-aes256'
        $encRes = Protect-WithSevenZip `
            -SevenZipPath $Config.sevenzip_path `
            -InputPath $Path `
            -OutputPath $outputPath `
            -Password $PromptResult.SecurePassword `
            -AllowOverwrite:$PromptResult.AllowOverwrite
    }

    if (-not $encRes.Success) {
        Write-AuditEvent -Config $Config -Fields @{
            op='protect'; outcome='fail'; error_code=$encRes.ErrorCode;
            src_path=$Path; cipher=$cipher; password_source=$PromptResult.PasswordSource;
            client_file_ref=$PromptResult.ClientFileRef;
        }
        return [pscustomobject]@{
            Success=$false; ExitCode=4; ErrorCode=$encRes.ErrorCode;
            OutputPath=$null
            Message="Encryption failed ($($encRes.ErrorCode)): $($encRes.Stderr)"
        }
    }

    # Escrow (refuse-closed if unreachable).
    try {
        $escrow = Write-EscrowSidecar `
            -Config $Config `
            -SourcePath $Path `
            -OutputPath $encRes.OutputPath `
            -Cipher $cipher `
            -PasswordSource $PromptResult.PasswordSource `
            -ClientFileRef $PromptResult.ClientFileRef `
            -Password $PromptResult.SecurePassword
    } catch {
        Remove-Item -LiteralPath $encRes.OutputPath -Force -ErrorAction SilentlyContinue
        Write-AuditEvent -Config $Config -Fields @{
            op='protect'; outcome='fail'; error_code='ESCROW_OFFLINE';
            src_path=$Path; cipher=$cipher; password_source=$PromptResult.PasswordSource;
        }
        return [pscustomobject]@{
            Success=$false; ExitCode=5; ErrorCode='ESCROW_OFFLINE'; OutputPath=$null
            Message="Escrow record could not be written; protected file was removed. $($_.Exception.Message)"
        }
    }

    # Optional: delete original.
    $deleted = $false
    if ($PromptResult.DeleteOriginal) {
        try { Remove-Item -LiteralPath $Path -Force; $deleted = $true } catch { }
    }

    $durationMs = [int]((Get-Date) - $startTs).TotalMilliseconds
    $outSize = (Get-Item -LiteralPath $encRes.OutputPath).Length
    $inSize  = if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).Length } else { $null }

    Write-AuditEvent -Config $Config -Fields @{
        op='protect'; outcome='ok';
        src_path=$Path; dst_path=$encRes.OutputPath;
        cipher=$cipher; bytes_in=$inSize; bytes_out=$outSize;
        duration_ms=$durationMs; client_file_ref=$PromptResult.ClientFileRef;
        password_source=$PromptResult.PasswordSource; deleted_original=$deleted;
        escrow_written=$true; escrow_fp=$escrow.Fingerprint; output_sha256=$escrow.OutputSha256;
    }

    # Optional: Outlook attach.
    $effectiveOutlookMode = if ($OutlookMode -ne 'None') { $OutlookMode }
                            elseif ($PromptResult.OpenOutlook) { 'New' }
                            else { $null }
    if ($effectiveOutlookMode) {
        $olRes = Send-ProtectedToOutlook -Config $Config -AttachmentPath $encRes.OutputPath -Mode $effectiveOutlookMode
        Write-AuditEvent -Config $Config -Fields @{
            op='outlook_attach'; outcome=$(if ($olRes.Success) {'ok'} else {'fail'});
            dst_path=$encRes.OutputPath; outlook_mode=$olRes.Mode; error=$olRes.Error
        }
    }

    return [pscustomobject]@{
        Success=$true; ExitCode=0; ErrorCode='OK'; OutputPath=$encRes.OutputPath
        Message="Protected: $($encRes.OutputPath)"
    }
}

Export-ModuleMember -Function Invoke-ProtectFileCore
