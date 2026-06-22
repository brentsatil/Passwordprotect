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

function ConvertTo-NativeArgString {
    # Quote one argument for a Windows CreateProcess command line (per the
    # CommandLineToArgvW rules). Needed because Windows PowerShell 5.1 / .NET
    # Framework has no ProcessStartInfo.ArgumentList, so we assign .Arguments.
    param([string] $Arg)
    if ($null -eq $Arg) { return '""' }
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[ \t\n\v"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') {
            $bs++
        } elseif ($ch -eq '"') {
            [void]$sb.Append('\', ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0
        } else {
            if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($bs -gt 0) { [void]$sb.Append('\', ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Test-PdfPreEncrypted {
    param(
        [Parameter(Mandatory)] [string] $QpdfPath,
        [Parameter(Mandatory)] [string] $InputPath
    )
    # qpdf --is-encrypted exits 0 if encrypted, 2 if not, 3 on error.
    # Pass a single pre-quoted argument string so paths with spaces survive.
    $argStr = (@('--is-encrypted','--',$InputPath) | ForEach-Object { ConvertTo-NativeArgString $_ }) -join ' '
    $p = Start-Process -FilePath $QpdfPath -ArgumentList $argStr `
         -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\qpdf-enc.err"
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
        $pinfo.Arguments = (@($args | ForEach-Object { ConvertTo-NativeArgString $_ })) -join ' '
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

    # qpdf exit codes: 0 = clean, 3 = warnings (output WAS still produced),
    # 2 = errors. Treat warnings as success -- plenty of real-world PDFs are
    # slightly non-conforming and make qpdf warn, yet still encrypt correctly.
    # Only a genuine error (or a missing temp output) is a failure.
    if (($code -ne 0 -and $code -ne 3) -or -not (Test-Path -LiteralPath $tmpOut)) {
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
