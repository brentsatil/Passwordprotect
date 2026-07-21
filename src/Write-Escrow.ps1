#Requires -Version 5.1
<#!
.SYNOPSIS
    Write certificate-encrypted per-file escrow sidecars for protected PDFs.
#>

function Get-CertificateFingerprint {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    return $Certificate.Thumbprint.Replace(' ','').ToLowerInvariant()
}

function Import-EscrowCertificate {
    param([Parameter(Mandatory)][string] $CertificatePath)
    if (-not (Test-Path -LiteralPath $CertificatePath)) { throw "Escrow public certificate not found at '$CertificatePath'. Re-run install.ps1 or contact IT." }
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
}

function Get-FileSha256 {
    param([string] $Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $fs = [System.IO.File]::OpenRead($Path); try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-','').ToLowerInvariant() } finally { $fs.Dispose() } }
    finally { $sha.Dispose() }
}

function Convert-SecureStringToUtf8Bytes {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr); return [System.Text.Encoding]::UTF8.GetBytes($plain) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); Remove-Variable plain -ErrorAction SilentlyContinue }
}

function Protect-EscrowBytes {
    <#
    .SYNOPSIS
        Wrap bytes under the escrow certificate's public key.
    .OUTPUTS
        @{ Wrapped = [byte[]]; Label = 'rsa-oaep-sha256-cert' | 'rsa-oaep-sha1-cert' }
    #>
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[Parameter(Mandatory)][byte[]]$Bytes)
    # Prefer SHA-256 OAEP via the CNG key (GetRSAPublicKey returns an RSACng for
    # certs from New-SelfSignedCertificate on Win10/11). Fall back to SHA-1 only
    # if the key is a legacy CSP that cannot do SHA-256 - never fail a protect
    # over padding capability. Recovery reads the recorded label back.
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
    if (-not $rsa) { throw 'Escrow certificate does not contain an RSA public key.' }
    if ($rsa -is [System.Security.Cryptography.RSACryptoServiceProvider]) {
        # Legacy CSP handle: OAEP-SHA1 only.
        return @{ Wrapped = $rsa.Encrypt($Bytes, $true); Label = 'rsa-oaep-sha1-cert' }
    }
    try {
        return @{ Wrapped = $rsa.Encrypt($Bytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256); Label = 'rsa-oaep-sha256-cert' }
    } catch {
        return @{ Wrapped = $rsa.Encrypt($Bytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA1); Label = 'rsa-oaep-sha1-cert' }
    }
}

function Write-EscrowSidecar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $Cipher,
        [Parameter(Mandatory)] [string] $PasswordSource,
        [string] $ClientFileRef,
        [Parameter(Mandatory)] [System.Security.SecureString] $UserPassword,
        [Parameter(Mandatory)] [System.Security.SecureString] $OwnerPassword
    )

    $certPath = if ($Config.escrow_cert_path) { $Config.escrow_cert_path } else { $Config.escrow_pubkey_path }
    $cert = Import-EscrowCertificate -CertificatePath $certPath
    try {
        $fingerprint = Get-CertificateFingerprint -Certificate $cert
        $userBytes = Convert-SecureStringToUtf8Bytes $UserPassword
        $ownerBytes = Convert-SecureStringToUtf8Bytes $OwnerPassword
        try {
            $wrappedUser = Protect-EscrowBytes -Certificate $cert -Bytes $userBytes
            $wrappedOwner = Protect-EscrowBytes -Certificate $cert -Bytes $ownerBytes
        } finally {
            if ($userBytes) { [Array]::Clear($userBytes,0,$userBytes.Length) }
            if ($ownerBytes) { [Array]::Clear($ownerBytes,0,$ownerBytes.Length) }
        }
        $wrapAlgorithm = $wrappedUser.Label

        $sha = Get-FileSha256 -Path $OutputPath
        $size = (Get-Item -LiteralPath $OutputPath).Length
        $now = (Get-Date).ToUniversalTime()
        $dir = Join-Path $Config.escrow_dir (Join-Path $now.ToString('yyyy') $now.ToString('MM'))
        try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } }
        catch { throw [System.InvalidOperationException]::new("Escrow share '$($Config.escrow_dir)' is unreachable: $($_.Exception.Message)") }

        $entry = [ordered]@{
            schema_version = 2
            created_utc = $now.ToString('o')
            tool_version = (Get-Content (Join-Path $PSScriptRoot '..\VERSION') -ErrorAction SilentlyContinue).Trim()
            host = $env:COMPUTERNAME
            user = "$env:USERDOMAIN\$env:USERNAME"
            source_filename = Split-Path $SourcePath -Leaf
            source_path = $SourcePath
            output_filename = Split-Path $OutputPath -Leaf
            output_sha256 = $sha
            output_size_bytes = $size
            cipher = $Cipher
            key_wrap_algorithm = $wrapAlgorithm
            public_key_fingerprint = $fingerprint
            pubkey_fingerprint_sha256 = $fingerprint
            wrapped_user_password_b64 = [Convert]::ToBase64String($wrappedUser.Wrapped)
            wrapped_owner_password_b64 = [Convert]::ToBase64String($wrappedOwner.Wrapped)
            client_file_ref = $ClientFileRef
            password_source = $PasswordSource
        }
        $sidecarPath = Join-Path $dir "$sha.escrow.json"
        $tmp = "$sidecarPath.tmp"
        [System.IO.File]::WriteAllText($tmp, ($entry | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $sidecarPath -Force
        if (-not (Test-Path -LiteralPath $sidecarPath)) { throw 'Escrow sidecar did not persist after write.' }
        return [pscustomobject]@{ SidecarPath=$sidecarPath; Fingerprint=$fingerprint; OutputSha256=$sha }
    } finally { $cert.Dispose() }
}
