#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Config.psm1') -Force
}

Describe 'Get-CuroConfig' {
    It 'rejects missing files' {
        { Get-CuroConfig -Path 'C:\does\not\exist.json' } | Should -Throw
    }

    It 'rejects a config with the wrong schema_version' {
        $tmp = New-TemporaryFile
        @{ schema_version = 999; client_lookup_file='\\x\y'; escrow_dir='\\x\y';
           dob_password_digits=8; manual_password_min_length=10; audit_log_retention_days=2555 } |
           ConvertTo-Json | Set-Content -LiteralPath $tmp.FullName -Encoding UTF8
        { Get-CuroConfig -Path $tmp.FullName } | Should -Throw
        Remove-Item $tmp
    }

    It 'accepts a well-formed config' {
        $tmp = New-TemporaryFile
        @{
            schema_version = 1
            client_lookup_file = '\\server\shared\PDFProtect\clients.csv'
            escrow_dir = '\\server\data\PDFProtect-Escrow'
            dob_password_digits = 8
            manual_password_min_length = 10
            manual_password_required_classes = 3
            audit_log_retention_days = 2555
            audit_log_path = '%ProgramData%\CuroPDFProtect\audit.log'
            qpdf_path = 'C:\Program Files\CuroPDFProtect\bin\qpdf.exe'
        } | ConvertTo-Json | Set-Content -LiteralPath $tmp.FullName -Encoding UTF8
        $cfg = Get-CuroConfig -Path $tmp.FullName
        $cfg.schema_version | Should -Be 1
        Remove-Item $tmp
    }

    It 'rejects a config missing qpdf_path' {
        $tmp = New-TemporaryFile
        @{
            schema_version = 1
            client_lookup_file = '\\server\shared\PDFProtect\clients.csv'
            escrow_dir = '\\server\data\PDFProtect-Escrow'
            dob_password_digits = 8
            manual_password_min_length = 10
            manual_password_required_classes = 3
            audit_log_retention_days = 2555
            audit_log_path = '%ProgramData%\CuroPDFProtect\audit.log'
        } | ConvertTo-Json | Set-Content -LiteralPath $tmp.FullName -Encoding UTF8
        { Get-CuroConfig -Path $tmp.FullName } | Should -Throw '*qpdf_path*'
        Remove-Item $tmp
    }
    It 'rejects a config missing manual_password_required_classes' {
        # Unvalidated, the missing key reached Test-ManualComplexity as $null,
        # coerced to [int]0, and every manual password passed "at least 0
        # character classes" - complexity enforcement off, with no error.
        $tmp = New-TemporaryFile
        @{
            schema_version = 1
            client_lookup_file = '\\server\shared\PDFProtect\clients.csv'
            escrow_dir = '\\server\data\PDFProtect-Escrow'
            dob_password_digits = 8
            manual_password_min_length = 10
            audit_log_retention_days = 2555
            audit_log_path = '%ProgramData%\CuroPDFProtect\audit.log'
            qpdf_path = 'C:\Program Files\CuroPDFProtect\bin\qpdf.exe'
        } | ConvertTo-Json | Set-Content -LiteralPath $tmp.FullName -Encoding UTF8
        { Get-CuroConfig -Path $tmp.FullName } | Should -Throw '*manual_password_required_classes*'
        Remove-Item $tmp
    }
}

Describe 'output_name_template validation' {
    BeforeAll {
        function New-TemplateConfigFile {
            param([string] $Template, [switch] $Omit)
            $tmp = New-TemporaryFile
            $h = @{
                schema_version = 1
                client_lookup_file = '\\server\shared\PDFProtect\clients.csv'
                escrow_dir = '\\server\data\PDFProtect-Escrow'
                dob_password_digits = 8
                manual_password_min_length = 10
                manual_password_required_classes = 3
                audit_log_retention_days = 2555
                audit_log_path = '%ProgramData%\CuroPDFProtect\audit.log'
                qpdf_path = 'C:\Program Files\CuroPDFProtect\bin\qpdf.exe'
                output_suffix = '_protected'
            }
            if (-not $Omit) { $h['output_name_template'] = $Template }
            $h | ConvertTo-Json | Set-Content -LiteralPath $tmp.FullName -Encoding UTF8
            return $tmp
        }
    }

    It 'accepts a config with NO template - every settings.json deployed before the key existed stays valid' {
        # This is the compatibility guarantee: making the key required would
        # break every teammate's machine on the next exe update.
        $tmp = New-TemplateConfigFile -Omit
        $cfg = Get-CuroConfig -Path $tmp.FullName
        $cfg.PSObject.Properties['output_name_template'] | Should -BeNullOrEmpty
        Remove-Item $tmp
    }

    It 'accepts a valid template' {
        $tmp = New-TemplateConfigFile -Template '{ClientRef}-{OriginalName}_protected'
        (Get-CuroConfig -Path $tmp.FullName).output_name_template | Should -Be '{ClientRef}-{OriginalName}_protected'
        Remove-Item $tmp
    }

    It 'rejects a template that expands to an empty file name' {
        # "{ClientRef}" alone names every manual-password output "_.pdf", and
        # the second file in a folder would collide with the first.
        $tmp = New-TemplateConfigFile -Template '{ClientRef}'
        { Get-CuroConfig -Path $tmp.FullName } | Should -Throw '*output_name_template*'
        Remove-Item $tmp
    }

    It 'ignores an empty template string and falls back to the suffix naming' {
        $tmp = New-TemplateConfigFile -Template ''
        { Get-CuroConfig -Path $tmp.FullName } | Should -Not -Throw
        Remove-Item $tmp
    }
}

Describe 'Get-CuroConfigPath probe order' {
    AfterEach { Remove-Item Env:CURO_SETTINGS_PATH -ErrorAction SilentlyContinue }

    It 'honours the CURO_SETTINGS_PATH override even for a missing file' {
        $env:CURO_SETTINGS_PATH = 'X:\nowhere\settings.json'
        Get-CuroConfigPath | Should -Be 'X:\nowhere\settings.json'
    }

    It 'falls back to the machine-wide path when nothing is set or present' {
        Remove-Item Env:CURO_SETTINGS_PATH -ErrorAction SilentlyContinue
        $expected = Join-Path $env:ProgramData 'CuroPDFProtect\settings.json'
        $perUser  = Join-Path $env:LOCALAPPDATA 'CuroPDFProtect\settings.json'
        # Only meaningful when neither real config exists on this host; the
        # per-user path is checked too since it now wins the probe.
        if (-not (Test-Path -LiteralPath $expected) -and -not (Test-Path -LiteralPath $perUser)) {
            Get-CuroConfigPath | Should -Be $expected
        }
    }

    It 'prefers the per-user config over a machine-wide one' {
        # This ordering is what stops a stale Install-mode config (pointing at a
        # Program Files qpdf that uninstall.ps1 deleted) from shadowing the
        # per-user config that --setup writes, a trap --setup could not repair.
        Remove-Item Env:CURO_SETTINGS_PATH -ErrorAction SilentlyContinue
        $fakeLocal = Join-Path $TestDrive 'local'
        New-Item -ItemType Directory -Force -Path (Join-Path $fakeLocal 'CuroPDFProtect') | Out-Null
        $userCfg = Join-Path $fakeLocal 'CuroPDFProtect\settings.json'
        '{}' | Set-Content -LiteralPath $userCfg -Encoding UTF8

        $savedLocal = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $fakeLocal
            Get-CuroConfigPath | Should -Be $userCfg
        } finally {
            $env:LOCALAPPDATA = $savedLocal
        }
    }

    It 'names setup.ps1 in the not-found error' {
        $env:CURO_SETTINGS_PATH = Join-Path $TestDrive 'absent.json'
        { Get-CuroConfig } | Should -Throw '*setup.ps1*'
    }
}
