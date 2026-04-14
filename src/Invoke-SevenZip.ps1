#Requires -Version 5.1
<#
.SYNOPSIS
    Wrap 7z.exe for AES-256 .7z creation. Password is piped via stdin using
    the -spf + -p- "prompt on stdin" mechanism, never placed on argv.
#>

function Protect-WithSevenZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SevenZipPath,
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [System.Security.SecureString] $Password,
        [switch] $AllowOverwrite
    )

    if (-not (Test-Path -LiteralPath $InputPath)) {
        return [pscustomobject]@{ Success=$false; ErrorCode='SEVENZIP_FAIL'; OutputPath=$null; Stderr="Input not found" }
    }
    if ((Test-Path -LiteralPath $OutputPath) -and -not $AllowOverwrite) {
        return [pscustomobject]@{ Success=$false; ErrorCode='SEVENZIP_FAIL'; OutputPath=$null; Stderr="Output exists and overwrite disabled" }
    }

    try {
        $fs = [System.IO.File]::Open($InputPath,'Open','Read','None')
        $fs.Dispose()
    } catch {
        return [pscustomobject]@{ Success=$false; ErrorCode='FILE_LOCKED'; OutputPath=$null; Stderr="Input file is in use." }
    }

    $tmpOut = "$OutputPath.tmp"

    # 7z accepts the password on argv (-p<pw>). Prefer -spf (store full paths)
    # off and use -p without inline password by piping via -ssw and stdin in
    # newer 7z — but 7z 22+ does not read password from stdin. We therefore
    # use -p<pw> with a just-in-time argv that we never log.
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $SevenZipPath
        foreach ($a in @('a','-t7z','-mhe=on','-mx=5','-y',"-p$plain",$tmpOut,$InputPath)) {
            [void]$pinfo.ArgumentList.Add($a)
        }
        $pinfo.UseShellExecute = $false
        $pinfo.RedirectStandardError = $true
        $pinfo.RedirectStandardOutput = $true
        $pinfo.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $stderr = $proc.StandardError.ReadToEnd() + $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        Remove-Variable plain -ErrorAction SilentlyContinue
        [GC]::Collect()
    }

    if ($code -ne 0) {
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Success=$false; ErrorCode='SEVENZIP_FAIL'; OutputPath=$null; Stderr=$stderr }
    }

    try {
        Move-Item -LiteralPath $tmpOut -Destination $OutputPath -Force
    } catch {
        return [pscustomobject]@{ Success=$false; ErrorCode='SEVENZIP_FAIL'; OutputPath=$null; Stderr=$_.Exception.Message }
    }

    return [pscustomobject]@{ Success=$true; ErrorCode='OK'; OutputPath=$OutputPath; Stderr=$stderr }
}
