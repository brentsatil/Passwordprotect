#Requires -Modules Pester
<#
  Unit tests for BatchQueue.psm1 - the row-state machine behind the batch
  protect window. No WPF here: that is the whole reason the state machine lives
  in its own module. tests\Xaml.Tests.ps1 covers the window shell.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\BatchQueue.psm1') -Force -DisableNameChecking
    . (Join-Path $PSScriptRoot '..\src\Find-Client.ps1')

    $script:cfg = [pscustomobject]@{ output_suffix = '_protected' }

    # A real client list built through Get-ClientList, so auto-matching is
    # exercised against the same shape the window gets at run time.
    function New-TestClientList {
        param(
            [Parameter(Mandatory)][string] $Dir,
            # Override the roster for a test that needs a specific name shape.
            # Defaulted so existing callers are untouched.
            [string[]] $Rows = @(
                'John Smith,01/03/1970,C-1001'
                'Jane Smith,02/04/1980,C-1002'
                'Aaron Brackenridge,05/06/1990,C-1003'
            )
        )
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $csv = Join-Path $Dir 'clients.csv'
        @(@('client_name,dob,file_ref') + $Rows) | Set-Content -LiteralPath $csv -Encoding UTF8
        $cacheDir = Join-Path $Dir 'cache'
        $cfg = [pscustomobject]@{
            client_lookup_file       = $csv
            client_lookup_cache_path = (Join-Path $cacheDir 'clients.csv')
            client_lookup_warn_days  = 8
            client_lookup_fail_days  = 21
            client_lookup_cache_hours = 48
        }
        return Get-ClientList -Config $cfg
    }

    function Get-Client {
        param($ClientList, [string] $Ref)
        return @($ClientList.Clients | Where-Object { $_.FileRef -eq $Ref })[0]
    }
}

Describe 'New-BatchRow auto-matching' {
    BeforeAll { $script:cl = New-TestClientList -Dir (Join-Path $TestDrive 'cl1') }

    It 'assigns and marks Ready when exactly one client matches the file name' {
        $row = New-BatchRow -Path 'C:\x\Aaron Brackenridge SOA.pdf' -Config $script:cfg -ClientList $script:cl
        $row.Status         | Should -Be 'Ready'
        $row.AutoMatched    | Should -BeTrue
        $row.Client.FileRef | Should -Be 'C-1003'
        $row.CandidateCount | Should -Be 1
    }

    It 'leaves the row NeedsClient when several clients match' {
        # "Smith_report.pdf" is a weak single-token match against both Smiths.
        $row = New-BatchRow -Path 'C:\x\Smith_report.pdf' -Config $script:cfg -ClientList $script:cl
        $row.Status         | Should -Be 'NeedsClient'
        $row.Client         | Should -BeNullOrEmpty
        $row.CandidateCount | Should -BeGreaterThan 1
    }

    It 'does NOT auto-assign a lone WEAK match (coincidental word in the name)' {
        # 'quarterly summary.pdf' loosely matches a client called Mary because
        # "summary" contains "mary". Exactly one candidate comes back, so the
        # old code marked the row Ready with that client pre-filled and the
        # Protect-all gate opened - one skim away from encrypting an unrelated
        # document with the wrong person's date of birth. It must stay
        # NeedsClient, with the candidate offered for the user to confirm.
        $maryList = New-TestClientList -Dir (Join-Path $TestDrive 'clMary') `
                        -Rows @('Mary OBrien,01/01/1990,C-2001')
        $row = New-BatchRow -Path 'C:\x\quarterly summary.pdf' -Config $script:cfg -ClientList $maryList
        $row.Status         | Should -Be 'NeedsClient'
        $row.Client         | Should -BeNullOrEmpty
        $row.AutoMatched    | Should -BeFalse
        $row.CandidateCount | Should -Be 1
    }

    It 'leaves the row NeedsClient when nothing matches' {
        $row = New-BatchRow -Path 'C:\x\quarterly-notes.pdf' -Config $script:cfg -ClientList $script:cl
        $row.Status         | Should -Be 'NeedsClient'
        $row.CandidateCount | Should -Be 0
    }

    It 'matches on file_ref as well as name' {
        $row = New-BatchRow -Path 'C:\x\C-1001 statement.pdf' -Config $script:cfg -ClientList $script:cl
        $row.Client.FileRef | Should -Be 'C-1001'
    }

    It 'defines every bound property even on an unmatched row' {
        # WPF binds StatusText/FileName/ClientDisplay/PreviewName. A property
        # that is absent (as opposed to empty) renders as a blank cell with no
        # error anywhere, so every row must define all four. ClientDisplay is
        # legitimately '' until a client is assigned - present, just empty.
        $row = New-BatchRow -Path 'C:\x\quarterly-notes.pdf' -Config $script:cfg -ClientList $script:cl
        foreach ($p in 'StatusText','FileName','ClientDisplay','PreviewName') {
            $row.PSObject.Properties.Name | Should -Contain $p -Because "$p is bound in the XAML"
        }
        $row.StatusText  | Should -Be 'Needs client'
        $row.FileName    | Should -Be 'quarterly-notes.pdf'
        $row.PreviewName | Should -Be 'quarterly-notes_protected.pdf'
        $row.ClientDisplay | Should -Be ''
    }

    It 'previews the name the naming module will actually produce' {
        $row = New-BatchRow -Path 'C:\x\doc.pdf' -Config $script:cfg -ClientList $script:cl
        $row.PreviewName | Should -Be 'doc_protected.pdf'
    }

    It 'never puts the DOB in a field that reaches the screen' {
        $row = New-BatchRow -Path 'C:\x\Aaron Brackenridge SOA.pdf' -Config $script:cfg -ClientList $script:cl
        $row.Client.Dob | Should -Be '05061990'      # available to the run
        foreach ($p in 'StatusText','FileName','ClientDisplay','PreviewName','Message') {
            [string]$row.$p | Should -Not -Match '05061990'
        }
    }
}

Describe 'New-BatchRowList' {
    BeforeAll { $script:cl = New-TestClientList -Dir (Join-Path $TestDrive 'cl2') }

    It 'returns one row per path' {
        $rows = New-BatchRowList -Paths @('C:\x\a.pdf','C:\x\b.pdf','C:\x\c.pdf') -Config $script:cfg -ClientList $script:cl
        @($rows).Count | Should -Be 3
    }
    It 'returns an array even for a single path (PS 5.1 scalar trap)' {
        $rows = New-BatchRowList -Paths @('C:\x\a.pdf') -Config $script:cfg -ClientList $script:cl
        @($rows).Count | Should -Be 1
        $rows -is [array] | Should -BeTrue
    }
    It 'must be assigned before wrapping - @(call) collapses to one element' {
        # The `,$rows` return that protects the single-path case above makes this
        # function emit ONE object, so the inline form silently yields a
        # 1-element array wrapping the real one. This bit the user-journey
        # simulation; pin it so the calling convention is documented in a test
        # rather than rediscovered.
        $paths = @('C:\x\a.pdf','C:\x\b.pdf','C:\x\c.pdf')
        $assigned = New-BatchRowList -Paths $paths -Config $script:cfg -ClientList $script:cl
        @($assigned).Count | Should -Be 3
        (@(New-BatchRowList -Paths $paths -Config $script:cfg -ClientList $script:cl)).Count | Should -Be 1
    }
}

Describe 'Set-BatchRowClient' {
    BeforeAll { $script:cl = New-TestClientList -Dir (Join-Path $TestDrive 'cl3') }

    It 'assigns a client to an unmatched row and makes it Ready' {
        $row = New-BatchRow -Path 'C:\x\notes.pdf' -Config $script:cfg -ClientList $script:cl
        $new = Set-BatchRowClient -Row $row -Client (Get-Client $script:cl 'C-1002') -Config $script:cfg
        $new.Status         | Should -Be 'Ready'
        $new.Client.FileRef | Should -Be 'C-1002'
        $new.AutoMatched    | Should -BeFalse
    }

    It 'returns a NEW object and leaves the original untouched' {
        # The window depends on this: it replaces the row in the collection
        # rather than mutating it, because a mutated row never repaints.
        $row = New-BatchRow -Path 'C:\x\notes.pdf' -Config $script:cfg -ClientList $script:cl
        $new = Set-BatchRowClient -Row $row -Client (Get-Client $script:cl 'C-1002') -Config $script:cfg
        [object]::ReferenceEquals($row, $new) | Should -BeFalse
        $row.Status | Should -Be 'NeedsClient'
    }

    It 'recomputes the preview when the template uses {ClientRef}' {
        $cfg = [pscustomobject]@{ output_suffix = '_protected'; output_name_template = '{ClientRef}-{OriginalName}' }
        $row = New-BatchRow -Path 'C:\x\notes.pdf' -Config $cfg -ClientList $script:cl
        $new = Set-BatchRowClient -Row $row -Client (Get-Client $script:cl 'C-1002') -Config $cfg
        $new.PreviewName | Should -Be 'C-1002-notes.pdf'
    }

    It 'refuses to change the client of a row that has already run' {
        $row = New-BatchRow -Path 'C:\x\C-1001 s.pdf' -Config $script:cfg -ClientList $script:cl
        $done = Set-BatchRowStatus -Row (Set-BatchRowStatus -Row $row -Status 'Working') -Status 'OK'
        { Set-BatchRowClient -Row $done -Client (Get-Client $script:cl 'C-1002') -Config $script:cfg } |
            Should -Throw '*OK*'
    }
}

Describe 'Set-BatchRowStatus transitions' {
    BeforeAll {
        $script:cl = New-TestClientList -Dir (Join-Path $TestDrive 'cl4')
        function New-ReadyRow { New-BatchRow -Path 'C:\x\C-1001 s.pdf' -Config $script:cfg -ClientList $script:cl }
        function New-NeedsRow { New-BatchRow -Path 'C:\x\notes.pdf'    -Config $script:cfg -ClientList $script:cl }
    }

    It 'allows Ready -> Working -> OK' {
        $w = Set-BatchRowStatus -Row (New-ReadyRow) -Status 'Working'
        $w.Status     | Should -Be 'Working'
        $w.StatusText | Should -Be 'Working...'
        $o = Set-BatchRowStatus -Row $w -Status 'OK' -Message 'Protected: C:\x\out.pdf' -OutputPath 'C:\x\out.pdf'
        $o.Status     | Should -Be 'OK'
        $o.OutputPath | Should -Be 'C:\x\out.pdf'
    }
    It 'allows Ready -> Working -> Failed' {
        $w = Set-BatchRowStatus -Row (New-ReadyRow) -Status 'Working'
        (Set-BatchRowStatus -Row $w -Status 'Failed' -Message 'boom').Status | Should -Be 'Failed'
    }
    It 'allows Ready -> NotRun (cancelled before it started)' {
        (Set-BatchRowStatus -Row (New-ReadyRow) -Status 'NotRun' -Message 'x').Status | Should -Be 'NotRun'
    }
    It 'refuses to start a row that has no client' {
        { Set-BatchRowStatus -Row (New-NeedsRow) -Status 'Working' } | Should -Throw '*NeedsClient*'
    }
    It 'refuses to skip Working' {
        { Set-BatchRowStatus -Row (New-ReadyRow) -Status 'OK' } | Should -Throw '*Ready*'
    }
    It 'treats OK, Failed and NotRun as terminal' {
        $w = Set-BatchRowStatus -Row (New-ReadyRow) -Status 'Working'
        foreach ($end in 'OK','Failed') {
            $t = Set-BatchRowStatus -Row $w -Status $end
            { Set-BatchRowStatus -Row $t -Status 'Working' } | Should -Throw
            { Set-BatchRowStatus -Row $t -Status 'NotRun'  } | Should -Throw
        }
        $n = Set-BatchRowStatus -Row (New-ReadyRow) -Status 'NotRun'
        { Set-BatchRowStatus -Row $n -Status 'Working' } | Should -Throw
    }
    It 'preserves the message when a later transition does not supply one' {
        $w = Set-BatchRowStatus -Row (New-ReadyRow) -Status 'Working' -Message 'keep me'
        (Set-BatchRowStatus -Row $w -Status 'OK').Message | Should -Be 'keep me'
    }
}

Describe 'Test-BatchReady gate' {
    BeforeAll {
        $script:cl = New-TestClientList -Dir (Join-Path $TestDrive 'cl5')
        $script:ready = New-BatchRow -Path 'C:\x\C-1001 s.pdf' -Config $script:cfg -ClientList $script:cl
        $script:needs = New-BatchRow -Path 'C:\x\notes.pdf'    -Config $script:cfg -ClientList $script:cl
    }

    It 'is false for an empty queue' {
        Test-BatchReady -Rows @() | Should -BeFalse
    }
    It 'is true for a single Ready row' {
        # Single-element case: an unwrapped scalar is where .Count returns $null
        # in PS 5.1, which would have made the gate pass vacuously.
        Test-BatchReady -Rows $script:ready | Should -BeTrue
        Test-BatchReady -Rows @($script:ready) | Should -BeTrue
    }
    It 'is false when any row still needs a client' {
        Test-BatchReady -Rows @($script:ready, $script:needs) | Should -BeFalse
    }
    It 'is false once rows have run (nothing left to protect)' {
        $done = Set-BatchRowStatus -Row (Set-BatchRowStatus -Row $script:ready -Status 'Working') -Status 'OK'
        Test-BatchReady -Rows @($done) | Should -BeFalse
    }
}

Describe 'New-BatchPromptResult' {
    BeforeAll {
        $script:cl = New-TestClientList -Dir (Join-Path $TestDrive 'cl6')
        $script:opts = @{ AllowOverwrite = $true; DeleteOriginal = $false }
    }

    It 'produces exactly the key set Invoke-ProtectFileCore reads' {
        # Pinned against Prompt-Password.ps1's contract so the two entry points
        # into the same core cannot drift apart.
        $row = New-BatchRow -Path 'C:\x\C-1001 s.pdf' -Config $script:cfg -ClientList $script:cl
        $pr = New-BatchPromptResult -Row $row -Options $script:opts
        try {
            $expected = @('SecurePassword','PasswordSource','ClientFileRef','DeleteOriginal','AllowOverwrite','OpenOutlook','Cancelled')
            (@($pr.Keys) | Sort-Object) -join ',' | Should -Be (($expected | Sort-Object) -join ',')
        } finally { if ($pr.SecurePassword) { $pr.SecurePassword.Dispose() } }
    }

    It 'wraps the client DOB as a read-only SecureString that round-trips' {
        $row = New-BatchRow -Path 'C:\x\C-1001 s.pdf' -Config $script:cfg -ClientList $script:cl
        $pr = New-BatchPromptResult -Row $row -Options $script:opts
        try {
            $pr.SecurePassword.Length | Should -Be 8
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pr.SecurePassword)
            try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) | Should -Be '01031970' }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } finally { $pr.SecurePassword.Dispose() }
    }

    It 'carries the batch options through and reports the dob source' {
        $row = New-BatchRow -Path 'C:\x\C-1001 s.pdf' -Config $script:cfg -ClientList $script:cl
        $pr = New-BatchPromptResult -Row $row -Options @{ AllowOverwrite = $true; DeleteOriginal = $true }
        try {
            $pr.PasswordSource | Should -Be 'dob'
            $pr.ClientFileRef  | Should -Be 'C-1001'
            $pr.AllowOverwrite | Should -BeTrue
            $pr.DeleteOriginal | Should -BeTrue
            $pr.Cancelled      | Should -BeFalse
            # Never offered on this path: a ticked box on a 10-file batch would
            # open 10 Outlook compose windows.
            $pr.OpenOutlook    | Should -BeFalse
        } finally { $pr.SecurePassword.Dispose() }
    }

    It 'refuses a row with no client' {
        $row = New-BatchRow -Path 'C:\x\notes.pdf' -Config $script:cfg -ClientList $script:cl
        { New-BatchPromptResult -Row $row -Options $script:opts } | Should -Throw '*no client*'
    }
}

Describe 'Get-BatchSummary' {
    BeforeAll {
        $script:cl = New-TestClientList -Dir (Join-Path $TestDrive 'cl7')
        function New-Row { New-BatchRow -Path 'C:\x\C-1001 s.pdf' -Config $script:cfg -ClientList $script:cl }
        function New-Done { param([string]$End) Set-BatchRowStatus -Row (Set-BatchRowStatus -Row (New-Row) -Status 'Working') -Status $End }
    }

    It 'counts each terminal state' {
        $rows = @((New-Done 'OK'), (New-Done 'OK'), (New-Done 'Failed'),
                  (Set-BatchRowStatus -Row (New-Row) -Status 'NotRun'))
        $s = Get-BatchSummary -Rows $rows
        $s.Total  | Should -Be 4
        $s.Ok     | Should -Be 2
        $s.Failed | Should -Be 1
        $s.NotRun | Should -Be 1
    }

    It 'reports exit code 0 even when files failed' {
        # The window showed each failure per row. Non-zero exit codes are
        # reserved for crashes and health refusals, because PasswordProtect.cmd
        # pauses with a diagnostic block on any non-zero.
        (Get-BatchSummary -Rows @((New-Done 'Failed'))).ExitCode | Should -Be 0
    }

    It 'handles an empty queue' {
        $s = Get-BatchSummary -Rows @()
        $s.Total | Should -Be 0
        $s.ExitCode | Should -Be 0
    }
}
