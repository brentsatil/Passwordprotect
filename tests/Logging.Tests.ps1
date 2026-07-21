#Requires -Modules Pester
<#
  Audit-log concurrency (the mutex must stop concurrent appenders from crashing
  each other / garbling lines) and bundled-binary integrity verification.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\src\Config.psm1')  -Force -DisableNameChecking
    $script:psExe   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:logging = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Logging.psm1')).Path
    $script:binReal = (Resolve-Path (Join-Path $PSScriptRoot '..\bin')).Path
}

Describe 'Audit log concurrency' {
    It 'keeps every line intact when two processes append at once' {
        $log = Join-Path $TestDrive 'audit.log'

        # A child that appends N audit rows. Written to a file (not an inline
        # -Command string) so no quoting can corrupt it.
        $childScript = Join-Path $TestDrive 'append-child.ps1'
        @"
param([string]`$Log, [string]`$Tag, [int]`$N)
Import-Module '$script:logging' -Force -DisableNameChecking
`$cfg = [pscustomobject]@{ audit_log_path = `$Log }
for (`$i = 0; `$i -lt `$N; `$i++) { Write-AuditEvent -Config `$cfg -Fields @{ op='stress'; tag=`$Tag; i=`$i } }
"@ | Set-Content -LiteralPath $childScript -Encoding ascii

        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$childScript,'-Log',$log,'-N','200','-Tag')
        $p1 = Start-Process $script:psExe -ArgumentList ($args + 'A') -PassThru -WindowStyle Hidden
        $p2 = Start-Process $script:psExe -ArgumentList ($args + 'B') -PassThru -WindowStyle Hidden
        $p1.WaitForExit(); $p2.WaitForExit()

        $lines = @(Get-Content -LiteralPath $log)
        $lines.Count | Should -Be 400
        $bad = 0
        foreach ($l in $lines) { try { $null = ($l | ConvertFrom-Json) } catch { $bad++ } }
        $bad | Should -Be 0
    }
}

Describe 'Test-CuroBinaryIntegrity' {
    It 'passes on the real bundled binaries' {
        Test-CuroBinaryIntegrity -QpdfPath (Join-Path $script:binReal 'qpdf.exe') | Should -BeNullOrEmpty
    }

    It 'detects a flipped byte in a pinned binary' {
        $binCopy = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $binCopy -Force | Out-Null
        Copy-Item (Join-Path $script:binReal '*') $binCopy -Force
        $target = Join-Path $binCopy 'qpdf29.dll'
        $bytes = [IO.File]::ReadAllBytes($target)
        $bytes[100] = $bytes[100] -bxor 0xFF
        [IO.File]::WriteAllBytes($target, $bytes)
        Test-CuroBinaryIntegrity -QpdfPath (Join-Path $binCopy 'qpdf.exe') | Should -Match 'qpdf29.dll'
    }

    It 'reports missing HASHES.txt' {
        $binCopy = Join-Path $TestDrive 'bin-nohash'
        New-Item -ItemType Directory -Path $binCopy -Force | Out-Null
        Copy-Item (Join-Path $script:binReal 'qpdf.exe') $binCopy -Force
        Test-CuroBinaryIntegrity -QpdfPath (Join-Path $binCopy 'qpdf.exe') | Should -Match 'HASHES.txt'
    }
}
