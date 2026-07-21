#Requires -Modules Pester
<#
  The Explorer shims run with -WindowStyle Hidden. These tests prove that a
  machine with no config fails LOUDLY (nonzero exit + diagnostic log)
  instead of dying silently, and that the notifier helpers never throw.

  The process-level tests spawn the real powershell.exe exactly as the
  registered context-menu commands do, with CURO_SUPPRESS_UI=1 so no modal
  dialog can hang a headless runner.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Show-CuroError.ps1')
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

Describe 'Write-CuroShimLog' {
    It 'appends a diagnostic record and returns the log path' {
        $log = Join-Path $TestDrive 'shim.log'
        $err = $null
        try { throw 'boom-for-test' } catch { $err = $_ }
        $ret = Write-CuroShimLog -ErrorRecord $err -Message 'context note' -LogPath $log
        $ret | Should -Be $log
        $log | Should -Exist
        $content = Get-Content -LiteralPath $log -Raw
        $content | Should -Match 'boom-for-test'
        $content | Should -Match 'context note'
    }

    It 'accepts a bare message with no error record and never throws' {
        $log = Join-Path $TestDrive 'shim2.log'
        { Write-CuroShimLog -Message 'just a note' -LogPath $log } | Should -Not -Throw
        (Get-Content -LiteralPath $log -Raw) | Should -Match 'just a note'
    }
}

Describe 'Show-CuroError under CURO_SUPPRESS_UI' {
    It 'returns without UI and without throwing' {
        $env:CURO_SUPPRESS_UI = '1'
        try {
            { Show-CuroError -Title 'T' -Message 'M' -Icon Error } | Should -Not -Throw
            { Show-CuroError -Title 'T' -Message 'M' -Icon Information } | Should -Not -Throw
        } finally {
            Remove-Item Env:CURO_SUPPRESS_UI -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Hidden shim invocations fail loudly when the machine has no config' {
    # These run against the real, unconfigured runner state: no
    # %ProgramData%\CuroPDFProtect\settings.json exists, which is exactly
    # the fresh-teammate-machine failure being pinned.
    BeforeAll {
        $script:shimLog = Join-Path (Join-Path $env:LOCALAPPDATA 'CuroPDFProtect') 'error.log'
        $machineConfig = Join-Path $env:ProgramData 'CuroPDFProtect\settings.json'
        if (Test-Path -LiteralPath $machineConfig) {
            throw "Machine config exists at $machineConfig - these tests require an unconfigured machine (CI runner)."
        }
    }
    BeforeEach {
        if (Test-Path -LiteralPath $script:shimLog) { Remove-Item -LiteralPath $script:shimLog -Force }
        $env:CURO_SUPPRESS_UI = '1'
    }
    AfterEach {
        Remove-Item Env:CURO_SUPPRESS_UI -ErrorAction SilentlyContinue
    }

    It 'Protect-File.ps1 exits 2 and writes the shim log' {
        $shim = Join-Path $script:repoRoot 'src\Protect-File.ps1'
        & $script:psExe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $shim -Path (Join-Path $TestDrive 'x.pdf')
        $LASTEXITCODE | Should -Be 2
        $script:shimLog | Should -Exist
        (Get-Content -LiteralPath $script:shimLog -Raw) | Should -Match 'Config file not found'
    }

    It 'Protect-Folder.ps1 exits 2 and writes the shim log' {
        $shim = Join-Path $script:repoRoot 'src\Protect-Folder.ps1'
        & $script:psExe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $shim -Path $TestDrive
        $LASTEXITCODE | Should -Be 2
        $script:shimLog | Should -Exist
        (Get-Content -LiteralPath $script:shimLog -Raw) | Should -Match 'Config file not found'
    }
}
