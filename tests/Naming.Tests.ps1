#Requires -Modules Pester
<#
  Unit tests for Naming.psm1 - the output-name template engine ported from the
  app\ prototype when its batch UI was folded into this tool.

  The single most important test in here is the default-template equivalence:
  a deployment with no output_name_template must produce EXACTLY the historical
  "<stem><output_suffix><ext>" name. Every protected file staff have already
  sent, and every escrow sidecar that names one, assumes that shape.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Naming.psm1') -Force -DisableNameChecking

    function New-NamingConfig {
        param([string] $Template)
        $cfg = [pscustomobject]@{ output_suffix = '_protected' }
        if ($PSBoundParameters.ContainsKey('Template')) {
            $cfg | Add-Member -NotePropertyName output_name_template -NotePropertyValue $Template
        }
        return $cfg
    }
}

Describe 'Expand-NameTemplate' {
    It 'substitutes known tokens' {
        Expand-NameTemplate -Template '{A}-{B}' -Tokens @{ A = 'one'; B = 'two' } | Should -Be 'one-two'
    }
    It 'leaves unknown tokens verbatim so a typo is visible, not silent' {
        Expand-NameTemplate -Template '{Original}-{Nope}' -Tokens @{ Original = 'x' } | Should -Be 'x-{Nope}'
    }
    It 'applies numeric format specifiers' {
        Expand-NameTemplate -Template 'f{Seq:000}' -Tokens @{ Seq = '7' } | Should -Be 'f007'
    }
    It 'ignores a format specifier on a non-numeric value' {
        Expand-NameTemplate -Template '{Name:000}' -Tokens @{ Name = 'abc' } | Should -Be 'abc'
    }
    It 'passes through a template with no tokens' {
        Expand-NameTemplate -Template 'literal' -Tokens @{ A = 'x' } | Should -Be 'literal'
    }
    It 'substitutes an empty token value' {
        Expand-NameTemplate -Template 'a{Ref}b' -Tokens @{ Ref = '' } | Should -Be 'ab'
    }
}

Describe 'Get-SafeFileName' {
    It 'replaces characters Windows forbids in a file name' {
        Get-SafeFileName -Name 'a:b/c\d*e?f"g<h>i|j' | Should -Be 'a_b_c_d_e_f_g_h_i_j'
    }
    It 'trims trailing dots and spaces, which Windows also forbids' {
        Get-SafeFileName -Name 'report.  ' | Should -Be 'report'
    }
    It 'never returns an empty name' {
        Get-SafeFileName -Name '   ' | Should -Be '_'
        Get-SafeFileName -Name ''    | Should -Be '_'
    }
    It 'leaves an ordinary name alone' {
        Get-SafeFileName -Name 'Smith SOA 2026' | Should -Be 'Smith SOA 2026'
    }
}

Describe 'Resolve-NameCollision' {
    It 'returns the path unchanged when nothing exists' {
        Resolve-NameCollision -Path 'C:\x\a.pdf' -ExistsTest { param($p) $false } | Should -Be 'C:\x\a.pdf'
    }
    It 'appends " (2)" before the extension on the first collision' {
        $taken = @('C:\x\a.pdf')
        Resolve-NameCollision -Path 'C:\x\a.pdf' -ExistsTest { param($p) $taken -contains $p } |
            Should -Be 'C:\x\a (2).pdf'
    }
    It 'keeps counting past an existing " (2)"' {
        $taken = @('C:\x\a.pdf', 'C:\x\a (2).pdf', 'C:\x\a (3).pdf')
        Resolve-NameCollision -Path 'C:\x\a.pdf' -ExistsTest { param($p) $taken -contains $p } |
            Should -Be 'C:\x\a (4).pdf'
    }
}

Describe 'Get-ProtectedOutputPath' {
    It 'with NO template configured reproduces the historical suffix naming' {
        # This is the compatibility contract. Do not "improve" this expectation.
        $cfg = New-NamingConfig
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\clients\Smith SOA.pdf' |
            Should -Be 'C:\clients\Smith SOA_protected.pdf'
    }
    It 'preserves the input extension casing rather than forcing .pdf' {
        $cfg = New-NamingConfig
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\clients\SCAN.PDF' |
            Should -Be 'C:\clients\SCAN_protected.PDF'
    }
    It 'keeps the file in the input folder' {
        $cfg = New-NamingConfig
        Split-Path -Parent (Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\a b\c.pdf') |
            Should -Be 'C:\a b'
    }
    It 'honours a configured template' {
        $cfg = New-NamingConfig -Template '{OriginalName}-locked'
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\x\doc.pdf' | Should -Be 'C:\x\doc-locked.pdf'
    }
    It 'does not double the extension when the template already ends with {Ext}' {
        $cfg = New-NamingConfig -Template '{OriginalName}_protected{Ext}'
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\x\doc.pdf' | Should -Be 'C:\x\doc_protected.pdf'
    }
    It 'expands {ClientRef} when supplied' {
        $cfg = New-NamingConfig -Template '{ClientRef}-{OriginalName}_protected'
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\x\doc.pdf' -ClientRef 'C-0042' |
            Should -Be 'C:\x\C-0042-doc_protected.pdf'
    }
    It 'expands {ClientRef} to nothing when there is no client (manual-password path)' {
        $cfg = New-NamingConfig -Template '{OriginalName}_{ClientRef}protected'
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\x\doc.pdf' | Should -Be 'C:\x\doc__protected.pdf'
    }
    It 'expands date tokens from an injected timestamp' {
        $cfg = New-NamingConfig -Template '{OriginalName}-{Date}-{DateCompact}'
        $ts = [datetime]::new(2026, 3, 9)
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\x\d.pdf' -Timestamp $ts |
            Should -Be 'C:\x\d-2026-03-09-20260309.pdf'
    }
    It 'formats {Seq}' {
        $cfg = New-NamingConfig -Template '{OriginalName}-{Seq:000}'
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\x\d.pdf' -Sequence 4 | Should -Be 'C:\x\d-004.pdf'
    }
    It 'sanitises a template that would emit an illegal character' {
        $cfg = New-NamingConfig -Template '{OriginalName}:secure'
        Get-ProtectedOutputPath -Config $cfg -InputPath 'C:\x\d.pdf' | Should -Be 'C:\x\d_secure.pdf'
    }
}

Describe 'Get-TemplateWildcard' {
    It 'reproduces the historical *_protected filter for the default template' {
        Get-TemplateWildcard -Config (New-NamingConfig) | Should -Be '*_protected'
    }
    It 'matches BaseNames the default template produces' {
        $p = Get-TemplateWildcard -Config (New-NamingConfig)
        'Smith SOA_protected' -like $p | Should -BeTrue
        'Smith SOA'           -like $p | Should -BeFalse
    }
    It 'builds a pattern from a custom template with a literal prefix' {
        $p = Get-TemplateWildcard -Config (New-NamingConfig -Template 'Curo-{OriginalName}')
        $p | Should -Be 'Curo-*'
        'Curo-doc' -like $p | Should -BeTrue
        # The old filter prepended a leading *, which would have matched this
        # unrelated file and silently skipped it in a folder batch.
        'SeCuro-doc' -like $p | Should -BeFalse
    }
    It 'escapes wildcard metacharacters in the literal parts' {
        $p = Get-TemplateWildcard -Config (New-NamingConfig -Template '{OriginalName}[locked]')
        'doc[locked]' -like $p | Should -BeTrue
        'docXlocked'  -like $p | Should -BeFalse
    }
}
