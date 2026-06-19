#Requires -Modules Pester
<#
    Tests for the standalone PasswordProtect tool. These exercise the pure
    helpers only (DOB formatting, output naming, binary resolution) and never
    invoke qpdf/7z or any WPF dialog, so they run anywhere Pester runs.
#>

BeforeAll {
    # Dot-sourcing leaves $MyInvocation.InvocationName = '.', so the script's
    # guarded main body does not execute on import.
    . (Join-Path $PSScriptRoot '..\PasswordProtect.ps1')
}

Describe 'Format-DobPassword' {
    It 'zero-pads day and month and produces 8 digits' {
        $p = Format-DobPassword -Day 1 -Month 3 -Year 1970
        $p | Should -Be '01031970'
        $p.Length | Should -Be 8
    }

    It 'keeps two-digit day/month as-is' {
        Format-DobPassword -Day 25 -Month 12 -Year 1988 | Should -Be '25121988'
    }

    It 'rejects an out-of-range day' {
        { Format-DobPassword -Day 32 -Month 1 -Year 1990 } | Should -Throw
    }

    It 'rejects an out-of-range month' {
        { Format-DobPassword -Day 1 -Month 13 -Year 1990 } | Should -Throw
    }

    It 'rejects a non-4-digit year' {
        { Format-DobPassword -Day 1 -Month 1 -Year 199 } | Should -Throw
    }
}

Describe 'Get-OutputPath' {
    It 'names a PDF copy <stem>_protected.pdf in the same folder' {
        $in  = Join-Path $TestDrive 'report.pdf'
        $out = Get-OutputPath -InputPath $in
        Split-Path -Leaf $out   | Should -Be 'report_protected.pdf'
        Split-Path -Parent $out | Should -Be (Split-Path -Parent $in)
    }

    It 'turns a non-PDF into <stem>_protected.7z' {
        $in  = Join-Path $TestDrive 'notes.docx'
        Get-OutputPath -InputPath $in | Split-Path -Leaf | Should -Be 'notes_protected.7z'
    }

    It 'treats an uppercase .PDF extension as a PDF' {
        $in = Join-Path $TestDrive 'SCAN.PDF'
        Get-OutputPath -InputPath $in | Split-Path -Leaf | Should -Be 'SCAN_protected.PDF'
    }

    It 'honours a custom suffix' {
        $in = Join-Path $TestDrive 'a.pdf'
        Get-OutputPath -InputPath $in -Suffix '-locked' | Split-Path -Leaf | Should -Be 'a-locked.pdf'
    }
}

Describe 'Resolve-Settings' {
    It 'prefers the bundled bin\ binaries when present' {
        $base = Join-Path $TestDrive 'app1'
        $bin  = Join-Path $base 'bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin 'qpdf.exe') -Value 'x'
        Set-Content -LiteralPath (Join-Path $bin '7z.exe')   -Value 'x'

        $s = Resolve-Settings -BaseDir $base
        $s.QpdfPath     | Should -Be (Join-Path $bin 'qpdf.exe')
        $s.SevenZipPath | Should -Be (Join-Path $bin '7z.exe')
        $s.OutputSuffix | Should -Be '_protected'
    }

    It 'falls back to config paths when bin\ is absent' {
        $base = Join-Path $TestDrive 'app2'
        $cfg  = Join-Path $base 'config'
        New-Item -ItemType Directory -Path $cfg -Force | Out-Null
        $fakeQpdf  = Join-Path $TestDrive 'q.exe'; Set-Content -LiteralPath $fakeQpdf  -Value 'x'
        $fakeSeven = Join-Path $TestDrive 's.exe'; Set-Content -LiteralPath $fakeSeven -Value 'x'
        @{ output_suffix='_protected'; qpdf_path=$fakeQpdf; sevenzip_path=$fakeSeven } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cfg 'settings.default.json') -Encoding UTF8

        $s = Resolve-Settings -BaseDir $base
        $s.QpdfPath     | Should -Be $fakeQpdf
        $s.SevenZipPath | Should -Be $fakeSeven
    }

    It 'throws a clear error when a binary cannot be found anywhere' {
        $base = Join-Path $TestDrive 'app3'
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        { Resolve-Settings -BaseDir $base } | Should -Throw '*not found*'
    }
}
