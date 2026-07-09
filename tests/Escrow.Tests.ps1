#Requires -Modules Pester
<#
  Escrow round-trip: wrap a password under a pub key, recover via the priv key.
  Uses an ephemeral keypair so no real escrow material is touched.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Write-Escrow.ps1')

    $script:tmp = Join-Path $env:TEMP "curo-escrow-tests-$((New-Guid).Guid)"
    New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null

    # Minimal fake "output" file to compute SHA against.
    $script:outPath = Join-Path $script:tmp 'fake_protected.pdf'
    Set-Content -LiteralPath $script:outPath -Value 'not a real pdf, just bytes'

    # Ephemeral certificate (public .cer + private .pfx), compatible with Windows PowerShell 5.1.
    $script:pubPath  = Join-Path $script:tmp 'escrow.cer'
    $script:privPath = Join-Path $script:tmp 'escrow.pfx'
    $script:pfxPassword = ConvertTo-SecureString -String 'test-pfx-password' -AsPlainText -Force
    $cert = New-SelfSignedCertificate -Subject 'CN=Curo Escrow Test' -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy Exportable -KeyUsage KeyEncipherment,DataEncipherment -CertStoreLocation 'Cert:\CurrentUser\My'
    Export-Certificate -Cert $cert -FilePath $script:pubPath -Force | Out-Null
    Export-PfxCertificate -Cert $cert -FilePath $script:privPath -Password $script:pfxPassword | Out-Null
    Remove-Item -LiteralPath ("Cert:\CurrentUser\My\$($cert.Thumbprint)") -Force -ErrorAction SilentlyContinue

    $script:cfg = [pscustomobject]@{
        escrow_dir = Join-Path $script:tmp 'escrow'
        escrow_cert_path = $script:pubPath
    }
}

AfterAll {
    Remove-Item -Path $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Escrow wrap + recover round-trip' {
    It 'wraps a password and recovers it byte-equal' {
        $ss = New-Object System.Security.SecureString
        foreach ($c in '12031970'.ToCharArray()) { $ss.AppendChar($c) }
        $ss.MakeReadOnly()

        $sidecar = Write-EscrowSidecar -Config $script:cfg `
            -SourcePath 'C:\tmp\source.pdf' `
            -OutputPath $script:outPath `
            -Cipher 'pdf-aes256' `
            -PasswordSource 'dob' `
            -ClientFileRef 'C-00421' `
            -UserPassword $ss `
            -OwnerPassword $ss

        $sidecar.SidecarPath | Should -Exist

        $entry = Get-Content $sidecar.SidecarPath -Raw | ConvertFrom-Json
        $entry.schema_version | Should -Be 1
        $entry.cipher          | Should -Be 'pdf-aes256'
        $entry.client_file_ref | Should -Be 'C-00421'
        $entry.pubkey_fingerprint_sha256.Length | Should -Be 64

        # Recover.
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($script:privPath, 'test-pfx-password')
        try {
            $plainBytes = $cert.PrivateKey.Decrypt([Convert]::FromBase64String($entry.wrapped_user_password_b64), $true)
            $recovered = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        } finally { $cert.Dispose() }

        $recovered | Should -Be '12031970'
    }

    It 'refuses when escrow dir is unreachable' {
        $badCfg = [pscustomobject]@{
            escrow_dir = '\\does-not-exist\nope'
            escrow_cert_path = $script:pubPath
        }
        $ss = New-Object System.Security.SecureString
        foreach ($c in 'x'.ToCharArray()) { $ss.AppendChar($c) }
        $ss.MakeReadOnly()
        { Write-EscrowSidecar -Config $badCfg -SourcePath 'x' -OutputPath $script:outPath `
            -Cipher 'pdf-aes256' -PasswordSource 'manual' -Password $ss } | Should -Throw
    }
}
