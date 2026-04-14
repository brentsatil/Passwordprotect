#Requires -Version 5.1
<#
.SYNOPSIS
    Write a per-file escrow sidecar. One JSON file per protected output.
.DESCRIPTION
    Each protected file gets a matching sidecar at
        <escrow_dir>\YYYY\MM\<output_sha256>.escrow.json
    The sidecar contains the RSA-OAEP-SHA256 wrapped password plus enough
    metadata for recovery (file ref, source filename, pubkey fingerprint,
    tool version, host, user, timestamp).

    Hard-fails if the escrow directory is unreachable. The tool's overall
    operation will be aborted upstream — we never produce a protected file
    without a recoverable sidecar.
#>

function Get-PubKeyFingerprint {
    param([Security.Cryptography.RSA]$Rsa)
    # Fingerprint = SHA-256 of the DER-encoded SubjectPublicKeyInfo.
    $spki = $Rsa.ExportSubjectPublicKeyInfo()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($spki))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Import-EscrowPublicKey {
    param([Parameter(Mandatory)][string] $PubKeyPath)
    if (-not (Test-Path -LiteralPath $PubKeyPath)) {
        throw "Escrow public key not found at '$PubKeyPath'. Re-run install.ps1 or contact IT."
    }
    $pem = Get-Content -LiteralPath $PubKeyPath -Raw
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($pem)
    return $rsa
}

function Get-FileSha256 {
    param([string] $Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-','').ToLowerInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function Write-EscrowSidecar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $Cipher,                  # 'pdf-aes256' | '7z-aes256'
        [Parameter(Mandatory)] [string] $PasswordSource,          # 'dob' | 'manual'
        [string] $ClientFileRef,
        [Parameter(Mandatory)] [System.Security.SecureString] $Password
    )

    $rsa = Import-EscrowPublicKey -PubKeyPath $Config.escrow_pubkey_path
    try {
        $fingerprint = Get-PubKeyFingerprint -Rsa $rsa

        # Wrap the password. Convert SecureString -> UTF8 bytes, encrypt,
        # zero the intermediate byte array.
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
            $wrapped = $rsa.Encrypt($bytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
            Remove-Variable plain -ErrorAction SilentlyContinue
        }

        $sha = Get-FileSha256 -Path $OutputPath
        $size = (Get-Item -LiteralPath $OutputPath).Length

        $now = (Get-Date).ToUniversalTime()
        $yyyy = $now.ToString('yyyy')
        $mm   = $now.ToString('MM')
        $dir = Join-Path $Config.escrow_dir (Join-Path $yyyy $mm)

        # Check reachability BEFORE returning success. Hard-fail if we
        # can't write, per D1 (refuse-closed).
        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
        } catch {
            throw [System.InvalidOperationException]::new(
                "Escrow share '$($Config.escrow_dir)' is unreachable: $($_.Exception.Message)")
        }

        $entry = [ordered]@{
            schema_version          = 1
            created_utc             = $now.ToString('o')
            tool_version            = (Get-Content (Join-Path $PSScriptRoot '..\VERSION') -ErrorAction SilentlyContinue).Trim()
            host                    = $env:COMPUTERNAME
            user                    = "$env:USERDOMAIN\$env:USERNAME"
            source_filename         = Split-Path $SourcePath -Leaf
            source_path             = $SourcePath
            output_filename         = Split-Path $OutputPath -Leaf
            output_sha256           = $sha
            output_size_bytes       = $size
            cipher                  = $Cipher
            pubkey_fingerprint_sha256 = $fingerprint
            wrapped_password_b64    = [Convert]::ToBase64String($wrapped)
            client_file_ref         = $ClientFileRef
            password_source         = $PasswordSource
        }

        $sidecarPath = Join-Path $dir "$sha.escrow.json"
        $json = $entry | ConvertTo-Json -Depth 6

        # Write to a .tmp and rename for atomicity.
        $tmp = "$sidecarPath.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $sidecarPath -Force

        # Verification read-back — confirms the write actually landed on the
        # share before we return success.
        if (-not (Test-Path -LiteralPath $sidecarPath)) {
            throw "Escrow sidecar did not persist after write."
        }

        return [pscustomobject]@{
            SidecarPath = $sidecarPath
            Fingerprint = $fingerprint
            OutputSha256 = $sha
        }
    } finally {
        $rsa.Dispose()
    }
}
