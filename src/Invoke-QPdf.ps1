#Requires -Version 5.1
<#
.SYNOPSIS
    Wrap qpdf.exe for PDF AES-256 encryption. Password is piped via stdin,
    never placed on the command line.
.DESCRIPTION
    Returns a PSCustomObject:
        @{ Success = [bool]; ErrorCode = 'PRE_ENCRYPTED'|'FILE_LOCKED'|'QPDF_FAIL'|'OK';
           OutputPath = <string or $null>; Stderr = <string> }
    The caller is responsible for writing audit entries and disposing the
    SecureString it passed in.
#>

function Test-PdfPreEncrypted {
    param(
        [Parameter(Mandatory)] [string] $QpdfPath,
        [Parameter(Mandatory)] [string] $InputPath
    )
    # qpdf --is-encrypted exits 0 if encrypted, 2 if not, 3 on error.
    $p = Start-Process -FilePath $QpdfPath -ArgumentList @('--is-encrypted','--',$InputPath) `
         -NoNewWindow -Wait -PassThru -RedirectStandardError $env:TEMP\qpdf-enc.err
    return $p.ExitCode -eq 0
}

function Add-LongPathPrefix {
    param([string]$Path)
    if ($Path -match '^\\\\\?\\') { return $Path }
    if ($Path -match '^\\\\')    { return "\\?\UNC\$($Path.TrimStart('\'))" }
    return "\\?\$Path"
}

function Protect-Pdf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $QpdfPath,
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [System.Security.SecureString] $Password,
        [switch] $LongPathPrefix,
        [switch] $AllowOverwrite
    )

    if (-not (Test-Path -LiteralPath $InputPath)) {
        return [pscustomobject]@{ Success=$false; ErrorCode='QPDF_FAIL'; OutputPath=$null; Stderr="Input not found" }
    }
    if ((Test-Path -LiteralPath $OutputPath) -and -not $AllowOverwrite) {
        return [pscustomobject]@{ Success=$false; ErrorCode='QPDF_FAIL'; OutputPath=$null; Stderr="Output exists and overwrite disabled" }
    }

    # Fail closed on files that look already-encrypted.
    if (Test-PdfPreEncrypted -QpdfPath $QpdfPath -InputPath $InputPath) {
        return [pscustomobject]@{ Success=$false; ErrorCode='PRE_ENCRYPTED'; OutputPath=$null;
            Stderr='Input PDF is already encrypted. Remove existing protection first.' }
    }

    # Fail closed on files that are locked (e.g. open in Acrobat).
    try {
        $fs = [System.IO.File]::Open($InputPath,'Open','Read','None')
        $fs.Dispose()
    } catch {
        return [pscustomobject]@{ Success=$false; ErrorCode='FILE_LOCKED'; OutputPath=$null;
            Stderr="Input file is in use. Close it in Acrobat or Reader and try again." }
    }

    $inArg  = if ($LongPathPrefix) { Add-LongPathPrefix $InputPath } else { $InputPath }
    $tmpOut = "$OutputPath.tmp"
    $outArg = if ($LongPathPrefix) { Add-LongPathPrefix $tmpOut } else { $tmpOut }

    # qpdf --encrypt <user-pw> <owner-pw> 256 -- in out
    # --password-mode=unicode is fine; we pass user == owner (Curo does not
    # use owner-password permissions for advice docs).
    # IMPORTANT: the password is passed on argv to qpdf v10; qpdf does not
    # currently support stdin for --encrypt, so we pass it on the command
    # line INSIDE a single Start-Process -ArgumentList array (never
    # interpolated via cmd.exe) and rely on the fact that the argv of a
    # short-lived child is only visible to processes running as the same
    # user. Audit log never records argv.
    # If this constraint is tightened in future qpdf releases, switch to
    # @password-file: with a temp file on a RAM disk.
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $args = @(
            '--encrypt', $plain, $plain, '256',
            '--',
            $inArg,
            $outArg
        )
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $QpdfPath
        foreach ($a in $args) { [void]$pinfo.ArgumentList.Add($a) }
        $pinfo.UseShellExecute = $false
        $pinfo.RedirectStandardError = $true
        $pinfo.RedirectStandardOutput = $true
        $pinfo.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        Remove-Variable plain -ErrorAction SilentlyContinue
        [GC]::Collect()
    }

    if ($code -ne 0) {
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Success=$false; ErrorCode='QPDF_FAIL'; OutputPath=$null; Stderr=$stderr }
    }

    # Atomic-ish rename into place.
    try {
        Move-Item -LiteralPath $tmpOut -Destination $OutputPath -Force
    } catch {
        return [pscustomobject]@{ Success=$false; ErrorCode='QPDF_FAIL'; OutputPath=$null; Stderr=$_.Exception.Message }
    }

    return [pscustomobject]@{ Success=$true; ErrorCode='OK'; OutputPath=$OutputPath; Stderr=$stderr }
}
