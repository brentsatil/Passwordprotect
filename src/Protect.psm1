# Protect.psm1
# Core protect-one-file logic shared by Protect-File.ps1 (single file from
# Explorer) and Protect-Folder.ps1 (batch, one prompt, many files).
#
# NOTHING in this module calls `exit`. Callers decide how to terminate.

$script:here = $PSScriptRoot
. (Join-Path $script:here 'Show-CuroError.ps1')
. (Join-Path $script:here 'Find-Client.ps1')
. (Join-Path $script:here 'Invoke-QPdf.ps1')
. (Join-Path $script:here 'Write-Escrow.ps1')
. (Join-Path $script:here 'Send-OutlookAttachment.ps1')
Import-Module (Join-Path $script:here 'Logging.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $script:here 'Naming.psm1')  -Force -DisableNameChecking

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
    if (-not $isPdf) {
        Write-AuditEvent -Config $Config -Fields @{ op='protect'; outcome='fail'; error_code='PDF_ONLY'; src_path=$Path }
        return [pscustomobject]@{ Success=$false; ExitCode=4; ErrorCode='PDF_ONLY'; OutputPath=$null; Message='Only PDF files are supported in business mode.' }
    }
    # Output name comes from the shared naming module (optional
    # output_name_template; default = the historical <stem><suffix> form) so
    # the batch window's preview column and the file this writes cannot drift.
    $outputPath = Get-ProtectedOutputPath -Config $Config -InputPath $Path -ClientRef $PromptResult.ClientFileRef

    $startTs = Get-Date
    $cipher  = $null
    $encRes  = $null

    $cipher = 'pdf-aes256'
    $encRes = Protect-Pdf `
        -QpdfPath $Config.qpdf_path `
        -InputPath $Path `
        -OutputPath $outputPath `
        -Password $PromptResult.SecurePassword `
        -LongPathPrefix:$Config.long_path_prefix `
        -AllowOverwrite:$PromptResult.AllowOverwrite

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
            -UserPassword $PromptResult.SecurePassword `
            -OwnerPassword $encRes.OwnerPassword
    } catch {
        if ($encRes.OwnerPassword) { $encRes.OwnerPassword.Dispose() }
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

    if ($encRes.OwnerPassword) { $encRes.OwnerPassword.Dispose() }

    # Optional: delete original. A failure here must not be silent - the
    # user asked for the original to go away and needs to know it is still
    # on disk.
    $deleted = $false
    $deleteError = $null
    if ($PromptResult.DeleteOriginal) {
        try { Remove-Item -LiteralPath $Path -Force; $deleted = $true }
        catch { $deleteError = $_.Exception.Message }
    }

    $durationMs = [int]((Get-Date) - $startTs).TotalMilliseconds
    $outSize = (Get-Item -LiteralPath $encRes.OutputPath).Length
    $inSize  = if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).Length } else { $null }

    $okFields = @{
        op='protect'; outcome='ok';
        src_path=$Path; dst_path=$encRes.OutputPath;
        cipher=$cipher; bytes_in=$inSize; bytes_out=$outSize;
        duration_ms=$durationMs; client_file_ref=$PromptResult.ClientFileRef;
        password_source=$PromptResult.PasswordSource; deleted_original=$deleted;
        escrow_written=$true; escrow_fp=$escrow.Fingerprint; output_sha256=$escrow.OutputSha256;
    }
    if ($deleteError) { $okFields['delete_error'] = $deleteError }
    Write-AuditEvent -Config $Config -Fields $okFields

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

    $message = "Protected: $($encRes.OutputPath)"
    if ($deleteError) {
        $message += [Environment]::NewLine + [Environment]::NewLine +
            "WARNING: The original file could NOT be deleted: $deleteError" +
            [Environment]::NewLine + "Remove it manually if required: $Path"
    }
    return [pscustomobject]@{
        Success=$true; ExitCode=0; ErrorCode='OK'; OutputPath=$encRes.OutputPath
        Message=$message
    }
}

function Invoke-UnprotectFileCore {
    <#
    .SYNOPSIS
        Produce an unprotected copy of a protected PDF + write the audit entry.
    .DESCRIPTION
        The mirror of Invoke-ProtectFileCore, with two deliberate differences.

        No escrow record is written: there is no new password to recover, and
        writing one would put a recovery entry against a file that needs none.

        The audit row is therefore the ONLY trace, which makes it more
        important here than on the protect path - an unprotected copy of a
        client document is exactly the event a compliance reviewer wants to
        find. It is written whether the removal succeeds or fails.

        The protected original is never deleted. Staff asked to remove a
        password, not to destroy the protected copy, and the escrow record
        that covers the original must keep pointing at a file that exists.
    .OUTPUTS
        [pscustomobject] Success, ExitCode, ErrorCode, OutputPath, Message
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $PromptResult    # needs SecurePassword (+ ClientFileRef)
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-AuditEvent -Config $Config -Fields @{ op='unprotect'; outcome='fail'; error_code='INPUT_NOT_FOUND'; src_path=$Path }
        return [pscustomobject]@{ Success=$false; ExitCode=3; ErrorCode='INPUT_NOT_FOUND'; OutputPath=$null; Message="File not found: $Path" }
    }

    # A site can switch this off fleet-wide; absent means allowed, so configs
    # deployed before the feature existed keep working.
    if ($Config.PSObject.Properties['allow_password_removal'] -and -not $Config.allow_password_removal) {
        Write-AuditEvent -Config $Config -Fields @{ op='unprotect'; outcome='fail'; error_code='NOT_PERMITTED'; src_path=$Path }
        return [pscustomobject]@{ Success=$false; ExitCode=2; ErrorCode='NOT_PERMITTED'; OutputPath=$null
            Message='Removing password protection is disabled for this deployment. Ask whoever looks after the tool.' }
    }

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -ne '.pdf') {
        Write-AuditEvent -Config $Config -Fields @{ op='unprotect'; outcome='fail'; error_code='PDF_ONLY'; src_path=$Path }
        return [pscustomobject]@{ Success=$false; ExitCode=4; ErrorCode='PDF_ONLY'; OutputPath=$null; Message='Only PDF files are supported.' }
    }

    $outputPath = Get-UnprotectedOutputPath -Config $Config -InputPath $Path
    $startTs = Get-Date

    $res = Remove-PdfProtection `
        -QpdfPath $Config.qpdf_path `
        -InputPath $Path `
        -OutputPath $outputPath `
        -Password $PromptResult.SecurePassword `
        -LongPathPrefix:$Config.long_path_prefix `
        -AllowOverwrite:$PromptResult.AllowOverwrite

    if (-not $res.Success) {
        Write-AuditEvent -Config $Config -Fields @{
            op='unprotect'; outcome='fail'; error_code=$res.ErrorCode; src_path=$Path
            client_file_ref=$PromptResult.ClientFileRef; password_source=$PromptResult.PasswordSource
        }
        $message = switch ($res.ErrorCode) {
            'BAD_PASSWORD'  { "That password does not open this PDF. If the password is the client's date of birth, check it in the client list (DDMMYYYY)." }
            'NOT_ENCRYPTED' { 'This PDF is not password protected, so there is nothing to remove.' }
            'FILE_LOCKED'   { 'The PDF is open in another program. Close it and try again.' }
            default         { "Could not remove the protection ($($res.ErrorCode)): $($res.Stderr)" }
        }
        return [pscustomobject]@{ Success=$false; ExitCode=4; ErrorCode=$res.ErrorCode; OutputPath=$null; Message=$message }
    }

    $durationMs = [int]((Get-Date) - $startTs).TotalMilliseconds
    Write-AuditEvent -Config $Config -Fields @{
        op='unprotect'; outcome='ok'; src_path=$Path; dst_path=$res.OutputPath
        bytes_in=(Get-Item -LiteralPath $Path).Length
        bytes_out=(Get-Item -LiteralPath $res.OutputPath).Length
        duration_ms=$durationMs
        client_file_ref=$PromptResult.ClientFileRef
        password_source=$PromptResult.PasswordSource
        output_sha256=(Get-FileSha256 -Path $res.OutputPath)
    }

    return [pscustomobject]@{
        Success=$true; ExitCode=0; ErrorCode='OK'; OutputPath=$res.OutputPath
        Message=("Unprotected copy created:" + [Environment]::NewLine + $res.OutputPath + [Environment]::NewLine + [Environment]::NewLine +
                 "This copy has NO password and no restrictions - anyone who can open the folder can read it. " +
                 "The protected original is untouched.")
    }
}

Export-ModuleMember -Function Invoke-ProtectFileCore, Invoke-UnprotectFileCore
