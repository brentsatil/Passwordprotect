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

    # Ephemeral keypair.
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $script:pubPath  = Join-Path $script:tmp 'escrow.pub'
    $script:privPath = Join-Path $script:tmp 'escrow.key'
    Set-Content -LiteralPath $script:pubPath  -Value ($rsa.ExportSubjectPublicKeyInfoPem()) -Encoding UTF8
    Set-Content -LiteralPath $script:privPath -Value ($rsa.ExportPkcs8PrivateKeyPem())      -Encoding UTF8
    $rsa.Dispose()

    $script:cfg = [pscustomobject]@{
        escrow_dir = Join-Path $script:tmp 'escrow'
        escrow_pubkey_path = $script:pubPath
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
            -Password $ss

        $sidecar.SidecarPath | Should -Exist

        $entry = Get-Content $sidecar.SidecarPath -Raw | ConvertFrom-Json
        $entry.schema_version | Should -Be 1
        $entry.cipher          | Should -Be 'pdf-aes256'
        $entry.client_file_ref | Should -Be 'C-00421'
        $entry.pubkey_fingerprint_sha256.Length | Should -Be 64

        # Recover.
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.ImportFromPem((Get-Content $script:privPath -Raw))
        try {
            $plainBytes = $rsa.Decrypt(
                [Convert]::FromBase64String($entry.wrapped_password_b64),
                [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
            $recovered = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        } finally { $rsa.Dispose() }

        $recovered | Should -Be '12031970'
    }

    It 'refuses when escrow dir is unreachable' {
        $badCfg = [pscustomobject]@{
            escrow_dir = '\\does-not-exist\nope'
            escrow_pubkey_path = $script:pubPath
        }
        $ss = New-Object System.Security.SecureString
        foreach ($c in 'x'.ToCharArray()) { $ss.AppendChar($c) }
        $ss.MakeReadOnly()
        { Write-EscrowSidecar -Config $badCfg -SourcePath 'x' -OutputPath $script:outPath `
            -Cipher 'pdf-aes256' -PasswordSource 'manual' -Password $ss } | Should -Throw
    }
}
