#Requires -Modules Pester
<#
  End-to-end tests of the core protect chain WITHOUT any WPF: real qpdf
  encryption, real escrow wrapping against a throwaway certificate, real
  audit rows - all under $TestDrive. This is the code every entry point
  (right-click, folder batch, drag-drop launcher) funnels into.
#>

BeforeAll {
    $ErrorActionPreference = 'Continue'   # qpdf writes warnings to stderr; assertions throw explicitly

    Import-Module (Join-Path $PSScriptRoot '..\src\Protect.psm1') -Force -DisableNameChecking
    . (Join-Path $PSScriptRoot '..\src\Show-CuroError.ps1')
    . (Join-Path $PSScriptRoot '..\src\Send-OutlookAttachment.ps1')

    $script:root = Split-Path -Parent $PSScriptRoot
    $script:qpdf = Join-Path $script:root 'bin\qpdf.exe'

    # Ephemeral escrow certificate (public half only - these tests never decrypt).
    $script:pubPath = Join-Path $TestDrive 'escrow.cer'
    $cert = New-SelfSignedCertificate -Subject 'CN=Curo Core Test' -KeyAlgorithm RSA -KeyLength 2048 `
        -KeyExportPolicy Exportable -KeyUsage KeyEncipherment,DataEncipherment -CertStoreLocation 'Cert:\CurrentUser\My'
    Export-Certificate -Cert $cert -FilePath $script:pubPath -Force | Out-Null
    Remove-Item -LiteralPath ("Cert:\CurrentUser\My\$($cert.Thumbprint)") -Force -ErrorAction SilentlyContinue

    # Minimal PDF, normalised by qpdf (same trick as the CI smoke test).
    $raw = Join-Path $TestDrive 'raw.pdf'
    @(
        '%PDF-1.4'
        '1 0 obj'
        '<< /Type /Catalog /Pages 2 0 R >>'
        'endobj'
        '2 0 obj'
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
        'endobj'
        '3 0 obj'
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>'
        'endobj'
        'trailer'
        '<< /Root 1 0 R >>'
        '%%EOF'
    ) | Set-Content -LiteralPath $raw -Encoding ascii
    $script:cleanPdf = Join-Path $TestDrive 'clean.pdf'
    & $script:qpdf $raw $script:cleanPdf 2>&1 | Out-Null
    if (($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) -or -not (Test-Path -LiteralPath $script:cleanPdf)) {
        throw "qpdf could not build the test PDF (exit $LASTEXITCODE)"
    }

    function New-TestConfig {
        param([Parameter(Mandatory)][string] $Dir)
        return [pscustomobject]@{
            output_suffix                 = '_protected'
            qpdf_path                     = $script:qpdf
            long_path_prefix              = $true
            escrow_dir                    = Join-Path $Dir 'escrow'
            escrow_cert_path              = $script:pubPath
            escrow_pubkey_path            = $script:pubPath
            audit_log_path                = Join-Path $Dir 'audit.log'
            outlook_integration           = $false
            outlook_com_timeout_seconds   = 1
            outlook_fallback_desktop_drop = $true
            show_recipient_hint           = $false
            recipient_hint_text           = ''
        }
    }

    function New-TestPrompt {
        param([switch] $DeleteOriginal)
        $ss = New-Object System.Security.SecureString
        foreach ($ch in '01031970'.ToCharArray()) { $ss.AppendChar($ch) }
        $ss.MakeReadOnly()
        return [pscustomobject]@{
            SecurePassword = $ss
            PasswordSource = 'dob'
            ClientFileRef  = 'C-TEST'
            DeleteOriginal = [bool]$DeleteOriginal
            AllowOverwrite = $false
            OpenOutlook    = $false
            Cancelled      = $false
        }
    }
}

Describe 'Invoke-ProtectFileCore' {
    It 'protects a PDF, writes escrow + audit, and the output decrypts with the DOB' {
        $work = Join-Path $TestDrive 'happy'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work

        $r = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)

        $r.Success | Should -BeTrue
        $out = Join-Path $work 'doc_protected.pdf'
        $out | Should -Exist

        & $script:qpdf --password=01031970 --decrypt $out (Join-Path $work 'dec.pdf') 2>&1 | Out-Null
        ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) | Should -BeTrue
        (Join-Path $work 'dec.pdf') | Should -Exist

        @(Get-ChildItem -Path $cfg.escrow_dir -Filter '*.escrow.json' -Recurse).Count | Should -Be 1
        $okRows = @(Get-Content -LiteralPath $cfg.audit_log_path | Where-Object { $_ -match '"outcome":"ok"' })
        $okRows.Count | Should -Be 1
    }

    It 'fails closed when the escrow location is unreachable and removes the output' {
        $work = Join-Path $TestDrive 'noescrow'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work
        # A FILE at the escrow_dir path makes directory creation under it
        # impossible - deterministic stand-in for an offline share.
        Set-Content -LiteralPath $cfg.escrow_dir -Value 'not a directory'

        $r = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)

        $r.Success | Should -BeFalse
        $r.ErrorCode | Should -Be 'ESCROW_OFFLINE'
        (Join-Path $work 'doc_protected.pdf') | Should -Not -Exist
        (Get-Content -LiteralPath $cfg.audit_log_path -Raw) | Should -Match 'ESCROW_OFFLINE'
    }

    It 'succeeds but reports a visible warning when the original cannot be deleted' {
        $work = Join-Path $TestDrive 'nodelete'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work

        # Deny delete on the source file AND delete-child on its folder
        # (deleting needs either right), leaving reads and the tmp-file
        # rename untouched. Explicit deny beats the runner's admin allow.
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $denyChild = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $me, 'DeleteSubdirectoriesAndFiles', 'None', 'None', 'Deny')
        $denyFile = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'Delete', 'Deny')
        $dirAcl = Get-Acl -LiteralPath $work
        $dirAcl.AddAccessRule($denyChild)
        Set-Acl -LiteralPath $work -AclObject $dirAcl
        $fileAcl = Get-Acl -LiteralPath $src
        $fileAcl.AddAccessRule($denyFile)
        Set-Acl -LiteralPath $src -AclObject $fileAcl

        try {
            $r = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt -DeleteOriginal)
        } finally {
            $fileAcl = Get-Acl -LiteralPath $src
            $fileAcl.RemoveAccessRule($denyFile) | Out-Null
            Set-Acl -LiteralPath $src -AclObject $fileAcl
            $dirAcl = Get-Acl -LiteralPath $work
            $dirAcl.RemoveAccessRule($denyChild) | Out-Null
            Set-Acl -LiteralPath $work -AclObject $dirAcl
        }

        $r.Success | Should -BeTrue
        $r.Message | Should -Match 'could NOT be deleted'
        Test-Path -LiteralPath $src | Should -BeTrue
        (Get-Content -LiteralPath $cfg.audit_log_path -Raw) | Should -Match 'delete_error'
    }
}

Describe 'Invoke-DesktopDropFallback' {
    It 'copies the attachment to the desktop and reports DesktopDrop' {
        $env:CURO_SUPPRESS_UI = '1'
        try {
            $att = Join-Path $TestDrive 'curo-fallback-test.pdf'
            Set-Content -LiteralPath $att -Value 'x'
            $r = Invoke-DesktopDropFallback -AttachmentPath $att -Reason 'unit test'
            $r.Success | Should -BeTrue
            $r.Mode | Should -Be 'DesktopDrop'
            $onDesktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'curo-fallback-test.pdf'
            $onDesktop | Should -Exist
            Remove-Item -LiteralPath $onDesktop -Force -ErrorAction SilentlyContinue
        } finally {
            Remove-Item Env:CURO_SUPPRESS_UI -ErrorAction SilentlyContinue
        }
    }
}
