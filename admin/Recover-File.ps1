#Requires -Version 5.1
<#
.SYNOPSIS
    Recover a forgotten password from the escrow log.
.DESCRIPTION
    Admin-only. Requires the escrow private key (normally on the safe USB) and
    the password that protects that .pfx.

    Accepts any of:
      -OutputPath  : path to the protected file - computes sha256 and looks up
      -SourceName  : original filename as recorded in the sidecar
      -ClientRef   : client file_ref - returns all matching entries
      -Sha256      : direct hash lookup

    Writes the recovered password to the clipboard (never to the console,
    never to a file) and emits an audit record on the LOCAL machine. The
    operator must clear their clipboard when done.

    Decryption follows the sidecar's recorded key_wrap_algorithm, so files
    escrowed under the old SHA-1 wrapping and the current SHA-256 wrapping
    are both recoverable with the same key.

.EXAMPLE
    .\Recover-File.ps1 -PrivateKeyPath E:\curo-escrow.pfx `
                       -OutputPath '\\server\clients\SoA_Smith_protected.pdf'
    # Prompts for the PFX password, then copies the password to the clipboard.
#>

[CmdletBinding()]
param(
    [string] $PrivateKeyPath,
    [securestring] $PfxPassword,
    [string] $EscrowDir,
    [string] $OutputPath,
    [string] $SourceName,
    [string] $ClientRef,
    [string] $Sha256
)

function Get-EscrowSha256 { param($p)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $fs=[IO.File]::OpenRead($p); try { ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-','').ToLowerInvariant() } finally { $fs.Dispose() } }
    finally { $sha.Dispose() }
}

function Unprotect-EscrowEntry {
    <#
    .SYNOPSIS
        Decrypt one wrapped password from a parsed escrow sidecar entry, using
        the private-key certificate and the entry's recorded wrap algorithm.
    .OUTPUTS
        The recovered password [string].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [ValidateSet('user','owner')] [string] $Which = 'user'
    )
    if (-not $Certificate.HasPrivateKey) { throw 'Recovery certificate does not contain a private key.' }
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'Could not obtain the RSA private key from the recovery certificate.' }

    if ($Which -eq 'owner') {
        $field = $Entry.wrapped_owner_password_b64
    } else {
        # schema 2 records wrapped_user_password_b64; schema 1 used wrapped_password_b64.
        $field = if ($Entry.wrapped_user_password_b64) { $Entry.wrapped_user_password_b64 } else { $Entry.wrapped_password_b64 }
    }
    if (-not $field) { throw "Sidecar has no wrapped $Which password." }

    # Padding follows the recorded algorithm. Anything but an explicit sha256
    # label (including schema-1 entries with no label) is SHA-1 OAEP.
    $padding = if ("$($Entry.key_wrap_algorithm)" -match 'sha256') {
        [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256
    } else {
        [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA1
    }
    $wrapped = [Convert]::FromBase64String($field)
    $plainBytes = $rsa.Decrypt($wrapped, $padding)
    try { return [System.Text.Encoding]::UTF8.GetString($plainBytes) }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}

# --- Main (guarded so dot-sourcing in tests does not run it) -----------------
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $here = Split-Path -Parent $MyInvocation.MyCommand.Definition
    Import-Module (Join-Path (Split-Path $here -Parent) 'src\Config.psm1') -Force
    Import-Module (Join-Path (Split-Path $here -Parent) 'src\Logging.psm1') -Force
    $config = Get-CuroConfig
    if (-not $EscrowDir) { $EscrowDir = $config.escrow_dir }

    if (-not $PrivateKeyPath) { throw 'Provide -PrivateKeyPath (the escrow .pfx on the recovery USB).' }
    if (-not (Test-Path -LiteralPath $PrivateKeyPath)) {
        throw "Private key not found at '$PrivateKeyPath'. Insert the escrow USB."
    }
    if (-not $PfxPassword) { $PfxPassword = Read-Host 'Escrow .pfx password' -AsSecureString }

    $candidates = @()
    if ($Sha256) { $candidates = Get-ChildItem -Path $EscrowDir -Filter "$Sha256.escrow.json" -Recurse -ErrorAction SilentlyContinue }
    elseif ($OutputPath) {
        $h = Get-EscrowSha256 $OutputPath
        $candidates = Get-ChildItem -Path $EscrowDir -Filter "$h.escrow.json" -Recurse -ErrorAction SilentlyContinue
    }
    else {
        $all = Get-ChildItem -Path $EscrowDir -Filter '*.escrow.json' -Recurse -ErrorAction SilentlyContinue
        foreach ($f in $all) {
            $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $hit = $true
            if ($SourceName -and $j.source_filename -ne $SourceName) { $hit = $false }
            if ($ClientRef  -and $j.client_file_ref -ne $ClientRef)  { $hit = $false }
            if ($hit) { $candidates += $f }
        }
    }

    if (-not $candidates) { throw "No matching escrow sidecar found." }

    if ($candidates.Count -gt 1) {
        Write-Host ""
        Write-Host "Multiple escrow entries match. Pick one:"
        $i = 0
        foreach ($c in $candidates) {
            $j = Get-Content $c.FullName -Raw | ConvertFrom-Json
            Write-Host "  [$i] $($j.created_utc)  $($j.source_filename)  ref=$($j.client_file_ref)"
            $i++
        }
        $choice = [int](Read-Host 'Index')
        $candidates = @($candidates[$choice])
    }

    $entry = Get-Content $candidates[0].FullName -Raw | ConvertFrom-Json

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PrivateKeyPath, $PfxPassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    try {
        # Warn (don't fail) if this key is not the one that wrapped the file -
        # the likeliest cause of a decrypt failure is the wrong recovery USB.
        $recFp = $cert.Thumbprint.Replace(' ','').ToLowerInvariant()
        $wrapFp = "$($entry.public_key_fingerprint)".Replace(' ','').ToLowerInvariant()
        if ($wrapFp -and $recFp -ne $wrapFp) {
            Write-Warning "This key's fingerprint ($recFp) does not match the key that wrapped this file ($wrapFp). You may have the wrong recovery USB; decryption will likely fail."
        }
        $password = Unprotect-EscrowEntry -Entry $entry -Certificate $cert -Which user
    } finally {
        $cert.Dispose()
    }

    # Write to clipboard - requires a STA host. Avoid writing to console.
    Set-Clipboard -Value $password
    Remove-Variable password

    Write-AuditEvent -Config $config -Fields @{
        op='recover'; outcome='ok';
        recovered_sha256=$entry.output_sha256;
        recovered_source=$entry.source_filename;
        recovered_client_ref=$entry.client_file_ref;
        key_wrap_algorithm=$entry.key_wrap_algorithm;
        operator=$env:USERNAME;
    }

    Write-Host "`nPassword copied to clipboard." -ForegroundColor Green
    Write-Host "Source file : $($entry.source_filename)"
    Write-Host "Protected   : $($entry.output_filename)"
    Write-Host "Client ref  : $($entry.client_file_ref)"
    Write-Host "Wrapped by  : $($entry.key_wrap_algorithm)  pubkey $("$($entry.public_key_fingerprint)".Substring(0,[Math]::Min(16,"$($entry.public_key_fingerprint)".Length)))..."
    Write-Host "`nClear your clipboard when you're finished." -ForegroundColor Yellow
}
