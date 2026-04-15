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
            audit_log_retention_days = 2555
            audit_log_path = '%ProgramData%\CuroPDFProtect\audit.log'
        } | ConvertTo-Json | Set-Content -LiteralPath $tmp.FullName -Encoding UTF8
        $cfg = Get-CuroConfig -Path $tmp.FullName
        $cfg.schema_version | Should -Be 1
        Remove-Item $tmp
    }
}
