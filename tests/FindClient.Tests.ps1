#Requires -Modules Pester
<#
  Unit tests for Find-Client.ps1 — DOB normalisation and CSV robustness.
  Run: Invoke-Pester -Path .\tests
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Find-Client.ps1')
}

Describe 'Get-NormalisedDob' {
    It 'strips separators from DDMMYYYY' {
        (Get-NormalisedDob '12/03/1970') | Should -Be '12031970'
        (Get-NormalisedDob '12-03-1970') | Should -Be '12031970'
        (Get-NormalisedDob '12.03.1970') | Should -Be '12031970'
    }
    It 'zero-pads DD and MM in output' {
        (Get-NormalisedDob '1/3/1970')   | Should -Be '01031970'
    }
    It 'accepts already-canonical DDMMYYYY' {
        (Get-NormalisedDob '12031970') | Should -Be '12031970'
    }
    It 'converts YYYYMMDD to DDMMYYYY when DDMMYYYY is invalid' {
        (Get-NormalisedDob '19700312') | Should -Be '12031970'
    }
    It 'prefers DDMMYYYY over YYYYMMDD when both interpretations are possible' {
        # 19081990 is a valid DDMMYYYY (19 Aug 1990). As YYYYMMDD it would
        # be 1908-19-90 which is nonsense. Must resolve to DDMMYYYY.
        (Get-NormalisedDob '19081990') | Should -Be '19081990'
        (Get-NormalisedDob '20051985') | Should -Be '20051985'
    }
    It 'rejects impossible dates' {
        (Get-NormalisedDob '32011970') | Should -BeNullOrEmpty
        (Get-NormalisedDob '00011970') | Should -BeNullOrEmpty
        (Get-NormalisedDob '01131970') | Should -BeNullOrEmpty
    }
    It 'rejects out-of-range years' {
        (Get-NormalisedDob '01011800') | Should -BeNullOrEmpty
        (Get-NormalisedDob '01012200') | Should -BeNullOrEmpty
    }
    It 'rejects short input' {
        (Get-NormalisedDob '')          | Should -BeNullOrEmpty
        (Get-NormalisedDob '1970')      | Should -BeNullOrEmpty
        (Get-NormalisedDob '1/3/70')    | Should -BeNullOrEmpty
    }
    It 'handles UTF-8 input with stray chars' {
        (Get-NormalisedDob 'DOB: 12/03/1970') | Should -Be '12031970'
    }
}

Describe 'Find-Client picker matches' {
    BeforeAll {
        $script:list = [pscustomobject]@{
            Source='test'; SourceKind='primary'; AgeDays=0; Stale=$false; HardFail=$false;
            MalformedRows=0; Warning=$null;
            Clients = @(
                [pscustomobject]@{ Name='Smith, John';   Dob='12031970'; FileRef='C-00101'; Display='Smith, John  —  C-00101' }
                [pscustomobject]@{ Name='Smith, John';   Dob='22061985'; FileRef='C-00421'; Display='Smith, John  —  C-00421' }
                [pscustomobject]@{ Name="O'Brien, Mary"; Dob='01011990'; FileRef='C-00502'; Display="O'Brien, Mary  —  C-00502" }
            )
        }
    }
    It 'matches substring case-insensitively' {
        (Find-Client -ClientList $script:list -Query 'smith').Count | Should -Be 2
    }
    It "handles apostrophes in names" {
        (Find-Client -ClientList $script:list -Query "o'brien").Count | Should -Be 1
    }
    It 'matches file_ref' {
        (Find-Client -ClientList $script:list -Query 'C-00421').Count | Should -Be 1
    }
    It 'returns nothing for empty query' {
        (Find-Client -ClientList $script:list -Query '').Count | Should -Be 0
    }
}
