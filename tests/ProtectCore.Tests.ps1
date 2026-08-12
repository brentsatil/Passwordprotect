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
    Import-Module (Join-Path $PSScriptRoot '..\src\Naming.psm1')  -Force -DisableNameChecking
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

    It 'writes the file the naming module predicts - default and custom template' {
        # The batch window shows Get-ProtectedOutputPath's answer in its "Will
        # create" column BEFORE anything runs. If the core ever computed a name
        # differently, that column would quietly lie to the user. Pin both.
        foreach ($tpl in @($null, '{ClientRef}-{OriginalName}-locked')) {
            $tag  = if ($tpl) { 'tpl' } else { 'default' }
            $work = Join-Path $TestDrive "naming-$tag"
            New-Item -ItemType Directory -Path $work -Force | Out-Null
            $src = Join-Path $work 'Client Report.pdf'
            Copy-Item -LiteralPath $script:cleanPdf -Destination $src
            $cfg = New-TestConfig -Dir $work
            if ($tpl) { $cfg | Add-Member -NotePropertyName output_name_template -NotePropertyValue $tpl }

            $predicted = Get-ProtectedOutputPath -Config $cfg -InputPath $src -ClientRef 'C-TEST'
            $r = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)

            $r.Success    | Should -BeTrue -Because "template '$tag' must protect successfully"
            $r.OutputPath | Should -Be $predicted -Because "the preview column must match what is written ($tag)"
            $predicted    | Should -Exist
        }
    }

    It 'keeps the default output name byte-identical to the historical suffix form' {
        $work = Join-Path $TestDrive 'naming-compat'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $r = Invoke-ProtectFileCore -Config (New-TestConfig -Dir $work) -Path $src -PromptResult (New-TestPrompt)
        $r.OutputPath | Should -Be (Join-Path $work 'doc_protected.pdf')
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

Describe 'Invoke-UnprotectFileCore' {
    It 'removes the password so the copy opens with none, and audits it' {
        $work = Join-Path $TestDrive 'unprot'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work

        # Protect first, so this is the real round trip a user performs.
        $p = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)
        $p.Success | Should -BeTrue

        $r = Invoke-UnprotectFileCore -Config $cfg -Path $p.OutputPath -PromptResult (New-TestPrompt)
        $r.Success | Should -BeTrue
        $out = Join-Path $work 'doc_unprotected.pdf'
        $r.OutputPath | Should -Be $out
        $out | Should -Exist

        # The point of the whole feature: it opens with NO password.
        & $script:qpdf $out (Join-Path $work 'plain.pdf') 2>&1 | Out-Null
        ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) | Should -BeTrue
        (Join-Path $work 'plain.pdf') | Should -Exist

        # The protected original survives - its escrow record still points at it.
        $p.OutputPath | Should -Exist

        $rows = @(Get-Content -LiteralPath $cfg.audit_log_path | Where-Object { $_ -match '"op":"unprotect"' })
        $rows.Count | Should -Be 1
        $rows[0] | Should -Match '"outcome":"ok"'
    }

    It 'strips the _protected suffix rather than stacking two suffixes' {
        # "Statement_protected.pdf" -> "Statement_unprotected.pdf", NOT
        # "Statement_protected_unprotected.pdf".
        $cfg = New-TestConfig -Dir (Join-Path $TestDrive 'namecheck')
        Import-Module (Join-Path $PSScriptRoot '..\src\Naming.psm1') -Force -DisableNameChecking
        $p = Get-UnprotectedOutputPath -Config $cfg -InputPath 'C:\x\Statement_protected.pdf'
        (Split-Path -Leaf $p) | Should -Be 'Statement_unprotected.pdf'
    }

    It 'refuses a wrong password with an actionable error, writing nothing' {
        $work = Join-Path $TestDrive 'badpw'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work
        $p = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)

        $wrong = New-Object System.Security.SecureString
        foreach ($ch in '31129999'.ToCharArray()) { $wrong.AppendChar($ch) }
        $wrong.MakeReadOnly()
        $prompt = [pscustomobject]@{ SecurePassword=$wrong; PasswordSource='manual'; ClientFileRef=$null
                                     DeleteOriginal=$false; AllowOverwrite=$false; OpenOutlook=$false; Cancelled=$false }

        $r = Invoke-UnprotectFileCore -Config $cfg -Path $p.OutputPath -PromptResult $prompt
        $r.Success | Should -BeFalse
        $r.ErrorCode | Should -Be 'BAD_PASSWORD'
        $r.Message | Should -Match 'date of birth'
        (Join-Path $work 'doc_unprotected.pdf') | Should -Not -Exist
        (Get-Content -LiteralPath $cfg.audit_log_path -Raw) | Should -Match 'BAD_PASSWORD'
    }

    It 'refuses a PDF that is not protected in the first place' {
        $work = Join-Path $TestDrive 'notenc'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work

        $r = Invoke-UnprotectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)
        $r.Success | Should -BeFalse
        $r.ErrorCode | Should -Be 'NOT_ENCRYPTED'
    }

    It 'can be switched off for a whole deployment' {
        $work = Join-Path $TestDrive 'denied'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work
        $cfg | Add-Member -NotePropertyName allow_password_removal -NotePropertyValue $false

        $r = Invoke-UnprotectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)
        $r.Success | Should -BeFalse
        $r.ErrorCode | Should -Be 'NOT_PERMITTED'
        (Get-Content -LiteralPath $cfg.audit_log_path -Raw) | Should -Match 'NOT_PERMITTED'
    }
}

Describe 'Invoke-ChangePasswordCore' {
    BeforeAll {
        function New-SecurePw {
            param([Parameter(Mandatory)][string] $Plain)
            $s = New-Object System.Security.SecureString
            foreach ($ch in $Plain.ToCharArray()) { $s.AppendChar($ch) }
            $s.MakeReadOnly()
            return $s
        }
        function New-RekeyPrompt {
            param([Parameter(Mandatory)][string] $NewPlain)
            return [pscustomobject]@{
                SecurePassword = (New-SecurePw -Plain $NewPlain); PasswordSource = 'dob'
                ClientFileRef  = 'C-TEST'; DeleteOriginal = $false; AllowOverwrite = $true
                OpenOutlook    = $false; Cancelled = $false
            }
        }
    }

    It 're-keys in place: old password stops working, new one opens it' {
        $work = Join-Path $TestDrive 'rekey'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work
        $p = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)
        $p.Success | Should -BeTrue
        $target = $p.OutputPath

        $r = Invoke-ChangePasswordCore -Config $cfg -Path $target `
                -CurrentPassword (New-SecurePw -Plain '01031970') -PromptResult (New-RekeyPrompt -NewPlain '25121988')
        $r.Success | Should -BeTrue
        $r.OutputPath | Should -Be $target          # in place

        & $script:qpdf --password=25121988 --decrypt $target (Join-Path $work 'new.pdf') 2>&1 | Out-Null
        ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) | Should -BeTrue
        (Join-Path $work 'new.pdf') | Should -Exist

        & $script:qpdf --password=01031970 --decrypt $target (Join-Path $work 'old.pdf') 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        (Join-Path $work 'old.pdf') | Should -Not -Exist
    }

    It 'escrows the NEW password so it is recoverable, keeping the old record' {
        $work = Join-Path $TestDrive 'rekey-escrow'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work
        $p = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)

        $r = Invoke-ChangePasswordCore -Config $cfg -Path $p.OutputPath `
                -CurrentPassword (New-SecurePw -Plain '01031970') -PromptResult (New-RekeyPrompt -NewPlain '25121988')
        $r.Success | Should -BeTrue

        # Two records now: the original send, and the re-keyed file.
        @(Get-ChildItem -Path $cfg.escrow_dir -Filter '*.escrow.json' -Recurse).Count | Should -Be 2

        # The record for the file as it stands must hold the NEW password.
        $sha = (Get-FileHash -LiteralPath $p.OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $sidecar = Get-ChildItem -Path $cfg.escrow_dir -Filter "$sha.escrow.json" -Recurse
        @($sidecar).Count | Should -Be 1

        $rows = @(Get-Content -LiteralPath $cfg.audit_log_path | Where-Object { $_ -match '"op":"change_password"' })
        $rows.Count | Should -Be 1
        $rows[0] | Should -Match '"outcome":"ok"'
        $rows[0] | Should -Match '"src_sha256"'      # old and new hashes both recorded
    }

    It 'leaves the file byte-identical when the current password is wrong' {
        $work = Join-Path $TestDrive 'rekey-badpw'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work
        $p = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)
        $before = (Get-FileHash -LiteralPath $p.OutputPath -Algorithm SHA256).Hash

        $r = Invoke-ChangePasswordCore -Config $cfg -Path $p.OutputPath `
                -CurrentPassword (New-SecurePw -Plain '31129999') -PromptResult (New-RekeyPrompt -NewPlain '25121988')
        $r.Success | Should -BeFalse
        $r.ErrorCode | Should -Be 'BAD_PASSWORD'
        (Get-FileHash -LiteralPath $p.OutputPath -Algorithm SHA256).Hash | Should -Be $before
        @(Get-ChildItem -Path $work -Filter '*.tmp').Count | Should -Be 0
    }

    It 'restores the original untouched when escrow is unreachable' {
        # The strict guarantee: a file must never end up with a password that has
        # no recovery record. Here the safer order is possible (unlike a fresh
        # protect), so the original comes back byte-for-byte.
        $work = Join-Path $TestDrive 'rekey-noescrow'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work
        $p = Invoke-ProtectFileCore -Config $cfg -Path $src -PromptResult (New-TestPrompt)
        $before = (Get-FileHash -LiteralPath $p.OutputPath -Algorithm SHA256).Hash

        # A FILE where the escrow directory should be - no directory can be made.
        Remove-Item -LiteralPath $cfg.escrow_dir -Recurse -Force
        Set-Content -LiteralPath $cfg.escrow_dir -Value 'not a directory'

        $r = Invoke-ChangePasswordCore -Config $cfg -Path $p.OutputPath `
                -CurrentPassword (New-SecurePw -Plain '01031970') -PromptResult (New-RekeyPrompt -NewPlain '25121988')

        $r.Success | Should -BeFalse
        $r.ErrorCode | Should -Be 'ESCROW_OFFLINE'
        (Get-FileHash -LiteralPath $p.OutputPath -Algorithm SHA256).Hash | Should -Be $before
        # Still opens with the ORIGINAL password - the client is unaffected.
        & $script:qpdf --password=01031970 --decrypt $p.OutputPath (Join-Path $work 'still.pdf') 2>&1 | Out-Null
        ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) | Should -BeTrue
        @(Get-ChildItem -Path $work -Filter '*.tmp').Count | Should -Be 0
    }

    It 'refuses a PDF that has no password yet' {
        $work = Join-Path $TestDrive 'rekey-plain'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $src = Join-Path $work 'doc.pdf'
        Copy-Item -LiteralPath $script:cleanPdf -Destination $src
        $cfg = New-TestConfig -Dir $work

        $r = Invoke-ChangePasswordCore -Config $cfg -Path $src `
                -CurrentPassword (New-SecurePw -Plain '01031970') -PromptResult (New-RekeyPrompt -NewPlain '25121988')
        $r.Success | Should -BeFalse
        $r.ErrorCode | Should -Be 'NOT_ENCRYPTED'
    }
}
