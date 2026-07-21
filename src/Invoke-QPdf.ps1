#Requires -Version 5.1
<#!
.SYNOPSIS
    Wrap qpdf.exe for PDF AES-256 encryption without exposing passwords on the
    qpdf process command line.
#>

function ConvertTo-NativeArgString {
    param([string] $Arg)
    if ($null -eq $Arg) { return '""' }
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[ \t\n\v"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') { $bs++ }
        elseif ($ch -eq '"') { [void]$sb.Append('\', ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0 }
        else { if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }; [void]$sb.Append($ch) }
    }
    if ($bs -gt 0) { [void]$sb.Append('\', ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Test-PdfPreEncrypted {
    param([Parameter(Mandatory)] [string] $QpdfPath,[Parameter(Mandatory)] [string] $InputPath)
    $argStr = (@('--is-encrypted','--',$InputPath) | ForEach-Object { ConvertTo-NativeArgString $_ }) -join ' '
    $err = Join-Path $env:TEMP ("qpdf-enc-{0}.err" -f ([guid]::NewGuid().Guid))
    try { $p = Start-Process -FilePath $QpdfPath -ArgumentList $argStr -NoNewWindow -Wait -PassThru -RedirectStandardError $err; return $p.ExitCode -eq 0 }
    finally { Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue }
}

function Add-LongPathPrefix { param([string]$Path) if ($Path -match '^\\\\\?\\') { return $Path }; if ($Path -match '^\\\\') { return "\\?\UNC\$($Path.TrimStart('\'))" }; return "\\?\$Path" }

function New-OwnerPassword {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes); return [Convert]::ToBase64String($bytes) }
    finally { $rng.Dispose(); [Array]::Clear($bytes,0,$bytes.Length) }
}

function ConvertFrom-SecureStringToPlain {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Protect-Pdf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $QpdfPath,
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [System.Security.SecureString] $Password,
        [System.Security.SecureString] $OwnerPassword,
        [switch] $LongPathPrefix,
        [switch] $AllowOverwrite
    )

    if (-not (Test-Path -LiteralPath $InputPath)) { return [pscustomobject]@{ Success=$false; ErrorCode='QPDF_FAIL'; OutputPath=$null; Stderr='Input not found'; OwnerPassword=$null } }
    if ((Test-Path -LiteralPath $OutputPath) -and -not $AllowOverwrite) { return [pscustomobject]@{ Success=$false; ErrorCode='QPDF_FAIL'; OutputPath=$null; Stderr='Output exists and overwrite disabled'; OwnerPassword=$null } }
    if (Test-PdfPreEncrypted -QpdfPath $QpdfPath -InputPath $InputPath) { return [pscustomobject]@{ Success=$false; ErrorCode='PRE_ENCRYPTED'; OutputPath=$null; Stderr='Input PDF is already encrypted. Remove existing protection first.'; OwnerPassword=$null } }
    try { $fs = [System.IO.File]::Open($InputPath,'Open','Read','None'); $fs.Dispose() } catch { return [pscustomobject]@{ Success=$false; ErrorCode='FILE_LOCKED'; OutputPath=$null; Stderr='Input file is in use. Close it in Acrobat or Reader and try again.'; OwnerPassword=$null } }

    $inArg  = if ($LongPathPrefix) { Add-LongPathPrefix $InputPath } else { $InputPath }
    $tmpOut = "$OutputPath.tmp"
    $outArg = if ($LongPathPrefix) { Add-LongPathPrefix $tmpOut } else { $tmpOut }
    $generatedOwner = $false
    if (-not $OwnerPassword) {
        $generatedOwner = $true
        $ownerPlain = New-OwnerPassword
        $OwnerPassword = ConvertTo-SecureString -String $ownerPlain -AsPlainText -Force
    }

    $userPlain = $null; if (-not $ownerPlain) { $ownerPlain = $null }
    try {
        $userPlain = ConvertFrom-SecureStringToPlain $Password
        if (-not $ownerPlain) { $ownerPlain = ConvertFrom-SecureStringToPlain $OwnerPassword }
        # Flag form (--user-password=/--owner-password=/--bits=), not the
        # deprecated positional "--encrypt user owner 256". The flag form is
        # non-deprecated and, per qpdf's own help, "allows you to use any
        # text as the password" - so a password that could look like an
        # option is unambiguous. Each line of the @- argfile is one argument.
        $argFile = @(
            '--encrypt'
            "--user-password=$userPlain"
            "--owner-password=$ownerPlain"
            '--bits=256'
            '--'
            $inArg
            $outArg
        ) -join "`n"

        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $QpdfPath
        $pinfo.Arguments = '@-'
        $pinfo.UseShellExecute = $false
        $pinfo.RedirectStandardInput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.RedirectStandardOutput = $true
        $pinfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($pinfo)
        # Write the argfile as BOM-less UTF-8 bytes straight to the pipe.
        # The default StandardInput StreamWriter on Windows PowerShell 5.1
        # emits a UTF-8 BOM; qpdf then reads the first line as the filename
        # "<BOM>--encrypt" instead of the --encrypt option, and rejects every
        # following --user-password/--owner-password flag as an unrecognized
        # argument. Writing raw no-BOM bytes is what makes encryption work at
        # all on the real Windows binary.
        $enc = New-Object System.Text.UTF8Encoding($false)
        $bytes = $enc.GetBytes($argFile)
        $stdin = $proc.StandardInput.BaseStream
        $stdin.Write($bytes, 0, $bytes.Length)
        $stdin.Flush()
        [Array]::Clear($bytes, 0, $bytes.Length)
        $proc.StandardInput.Close()
        $stderr = $proc.StandardError.ReadToEnd()
        [void]$proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } finally {
        Remove-Variable userPlain -ErrorAction SilentlyContinue
        Remove-Variable ownerPlain -ErrorAction SilentlyContinue
        [GC]::Collect()
    }

    if (($code -ne 0 -and $code -ne 3) -or -not (Test-Path -LiteralPath $tmpOut)) {
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
        if ($generatedOwner -and $OwnerPassword) { $OwnerPassword.Dispose() }
        return [pscustomobject]@{ Success=$false; ErrorCode='QPDF_FAIL'; OutputPath=$null; Stderr=$stderr; OwnerPassword=$null }
    }
    try { Move-Item -LiteralPath $tmpOut -Destination $OutputPath -Force }
    catch { if ($generatedOwner -and $OwnerPassword) { $OwnerPassword.Dispose() }; return [pscustomobject]@{ Success=$false; ErrorCode='QPDF_FAIL'; OutputPath=$null; Stderr=$_.Exception.Message; OwnerPassword=$null } }
    return [pscustomobject]@{ Success=$true; ErrorCode='OK'; OutputPath=$OutputPath; Stderr=$stderr; OwnerPassword=$OwnerPassword }
}
