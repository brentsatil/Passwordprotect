#Requires -Modules Pester
<#
  Escrow round-trip: wrap a password under a pub key, recover via the priv key.
  Uses an ephemeral passworded keypair so no real escrow material is touched.
  Covers the current SHA-256 wrapping AND recovery of legacy SHA-1 / schema-1
  sidecars (so old protected files stay recoverable after the upgrade).
#>

function New-SS([string]$s) {
    $ss = New-Object System.Security.SecureString
    foreach ($c in $s.ToCharArray()) { $ss.AppendChar($c) }
    $ss.MakeReadOnly(); return $ss
}
function Wrap-Sha1B64([string]$plain) {
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($script:pubCert)
    [Convert]::ToBase64String($rsa.Encrypt([System.Text.Encoding]::UTF8.GetBytes($plain), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA1))
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Write-Escrow.ps1')
    . (Join-Path $PSScriptRoot '..\admin\Recover-File.ps1')   # Unprotect-EscrowEntry (guarded main)

    $script:tmp = Join-Path $env:TEMP "curo-escrow-tests-$((New-Guid).Guid)"
    New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null

    $script:outPath = Join-Path $script:tmp 'fake_protected.pdf'
    Set-Content -LiteralPath $script:outPath -Value 'not a real pdf, just bytes'

    # Ephemeral certificate: public .cer for wrapping, password-protected .pfx
    # for recovery (exercises the -PfxPassword path).
    $script:pubPath  = Join-Path $script:tmp 'escrow.cer'
    $script:privPath = Join-Path $script:tmp 'escrow.pfx'
    $script:pfxPw    = 'test-pfx-password'
    $cert = New-SelfSignedCertificate -Subject 'CN=Curo Escrow Test' -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy Exportable -KeyUsage KeyEncipherment,DataEncipherment -CertStoreLocation 'Cert:\CurrentUser\My'
    Export-Certificate -Cert $cert -FilePath $script:pubPath -Force | Out-Null
    Export-PfxCertificate -Cert $cert -FilePath $script:privPath -Password (ConvertTo-SecureString -String $script:pfxPw -AsPlainText -Force) | Out-Null
    Remove-Item -LiteralPath ("Cert:\CurrentUser\My\$($cert.Thumbprint)") -Force -ErrorAction SilentlyContinue

    $script:cfg = [pscustomobject]@{
        escrow_dir = Join-Path $script:tmp 'escrow'
        escrow_cert_path = $script:pubPath
    }

    # Load the private cert once (from the passworded pfx) for recovery.
    $script:privCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($script:privPath, $script:pfxPw)
    # And the public cert, to hand-build legacy SHA-1 / schema-1 sidecars.
    $script:pubCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($script:pubPath)
}

AfterAll {
    if ($script:privCert) { $script:privCert.Dispose() }
    if ($script:pubCert)  { $script:pubCert.Dispose() }
    Remove-Item -Path $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Escrow wrap + recover round-trip' {
    It 'wraps with SHA-256 and recovers byte-equal via the passworded pfx' {
        $ss = New-SS '12031970'
        $sidecar = Write-EscrowSidecar -Config $script:cfg `
            -SourcePath 'C:\tmp\source.pdf' -OutputPath $script:outPath `
            -Cipher 'pdf-aes256' -PasswordSource 'dob' -ClientFileRef 'C-00421' `
            -UserPassword $ss -OwnerPassword $ss

        $sidecar.SidecarPath | Should -Exist
        $entry = Get-Content $sidecar.SidecarPath -Raw | ConvertFrom-Json
        $entry.schema_version    | Should -Be 2
        $entry.key_wrap_algorithm | Should -Be 'rsa-oaep-sha256-cert'
        $entry.public_key_fingerprint | Should -Match '^[0-9a-f]{40}$'

        (Unprotect-EscrowEntry -Entry $entry -Certificate $script:privCert -Which user)  | Should -Be '12031970'
        (Unprotect-EscrowEntry -Entry $entry -Certificate $script:privCert -Which owner) | Should -Be '12031970'
    }

    It 'recovers a legacy SHA-1-labelled sidecar' {
        $entry = [pscustomobject]@{
            schema_version = 2
            key_wrap_algorithm = 'rsa-oaep-sha1-cert'
            wrapped_user_password_b64 = (Wrap-Sha1B64 '25121988')
        }
        (Unprotect-EscrowEntry -Entry $entry -Certificate $script:privCert -Which user) | Should -Be '25121988'
    }

    It 'recovers a schema-1 sidecar (wrapped_password_b64, no algorithm label)' {
        $entry = [pscustomobject]@{
            schema_version = 1
            wrapped_password_b64 = (Wrap-Sha1B64 '01011990')
        }
        (Unprotect-EscrowEntry -Entry $entry -Certificate $script:privCert -Which user) | Should -Be '01011990'
    }

    It 'refuses when escrow dir is unreachable' {
        $badCfg = [pscustomobject]@{ escrow_dir = '\\does-not-exist\nope'; escrow_cert_path = $script:pubPath }
        $ss = New-SS 'x'
        { Write-EscrowSidecar -Config $badCfg -SourcePath 'x' -OutputPath $script:outPath `
            -Cipher 'pdf-aes256' -PasswordSource 'manual' -UserPassword $ss -OwnerPassword $ss } | Should -Throw
    }
}
