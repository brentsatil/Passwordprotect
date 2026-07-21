#Requires -Modules Pester
<#
  End-to-end test of the guided setup.ps1 in Launcher mode.

  setup.ps1 runs in a CHILD powershell.exe (so its env changes - including
  CURO_SETTINGS_PATH - never leak into the Pester session) with %ProgramData%
  redirected under $TestDrive, so the escrow cert / audit / cache land in the
  sandbox instead of the real machine. Child output goes to a file so no
  child-side error records can terminate these tests.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:fixture = Join-Path $PSScriptRoot 'fixtures\clients-sample.csv'

    # A self-contained copy of the tool (just the parts setup needs).
    $script:app = Join-Path $TestDrive 'app'
    New-Item -ItemType Directory -Path $script:app -Force | Out-Null
    foreach ($sub in 'src','bin','config','admin') {
        Copy-Item -Path (Join-Path $script:repoRoot $sub) -Destination $script:app -Recurse -Force
    }
    foreach ($f in 'setup.ps1','install.ps1','VERSION') {
        Copy-Item -Path (Join-Path $script:repoRoot $f) -Destination $script:app -Force
    }

    # Sandbox locations.
    $script:pd        = Join-Path $TestDrive 'pd'          # redirected %ProgramData%
    $script:clientOut = Join-Path $TestDrive 'shared\clients.csv'
    $script:escrowDir = Join-Path $TestDrive 'escrow-store'
    $script:pfxPath   = Join-Path $TestDrive 'escrow.pfx'
    $script:settings  = Join-Path $script:app 'config\settings.json'
    $script:certPath  = Join-Path $script:pd 'CuroPDFProtect\escrow.cer'

    # Run a child setup.ps1; return @{ Exit; Output }. Everything (stdout +
    # stderr) is redirected to a file so no error record reaches the pipeline.
    function Invoke-SetupRaw {
        param([string] $Inner)
        $outFile = Join-Path $TestDrive ("setup-out-{0}.txt" -f ([guid]::NewGuid().Guid))
        $cmd = "`$env:ProgramData = '$script:pd'; $Inner; exit `$LASTEXITCODE"
        & $script:psExe -NoProfile -ExecutionPolicy Bypass -Command $cmd > $outFile 2>&1
        $rc = $LASTEXITCODE
        $out = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw } else { '' }
        return [pscustomobject]@{ Exit = $rc; Output = $out }
    }

    function Invoke-Setup {
        $setupPath = Join-Path $script:app 'setup.ps1'
        $inner = "& '$setupPath' -Mode Launcher -NonInteractive " +
                 "-ClientListPath '$script:clientOut' -EscrowDir '$script:escrowDir' " +
                 "-ClientSource '$script:fixture' -PfxPath '$script:pfxPath' " +
                 "-PfxPassword (ConvertTo-SecureString 'test-pfx-pw-1' -AsPlainText -Force)"
        return Invoke-SetupRaw -Inner $inner
    }
}

Describe 'setup.ps1 -Mode Launcher (first run)' {
    BeforeAll { $script:run1 = Invoke-Setup; Write-Host $script:run1.Output }

    It 'exits 0' { $script:run1.Exit | Should -Be 0 }

    It 'writes a valid settings.json into the tool config folder' {
        $script:settings | Should -Exist
        Import-Module (Join-Path $script:app 'src\Config.psm1') -Force
        $cfg = Get-CuroConfig -Path $script:settings
        $cfg.schema_version | Should -Be 1
        $cfg.qpdf_path | Should -Match 'bin\\qpdf.exe$'
    }

    It 'generates the escrow keypair (public cert + private pfx)' {
        $script:certPath | Should -Exist
        $script:pfxPath  | Should -Exist
    }

    It 'publishes the client list, skipping the malformed DOB row' {
        $script:clientOut | Should -Exist
        # fixture has 3 rows; the 99/99/9999 one is rejected.
        @(Import-Csv -LiteralPath $script:clientOut).Count | Should -Be 2
    }
}

Describe 'setup.ps1 -Mode Launcher (idempotent re-run)' {
    It 're-runs cleanly and leaves the escrow certificate untouched' {
        $script:certPath | Should -Exist   # created by the first-run Describe
        $before = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:certPath).Hash
        $run2 = Invoke-Setup
        Write-Host $run2.Output
        $run2.Exit | Should -Be 0
        (Get-FileHash -Algorithm SHA256 -LiteralPath $script:certPath).Hash | Should -Be $before
    }
}

Describe 'setup.ps1 -NonInteractive with a missing required value' {
    It 'fails fast and names the missing parameter' {
        $setupPath = Join-Path $script:app 'setup.ps1'
        # Omit -ClientListPath; -NonInteractive must refuse to prompt.
        $r = Invoke-SetupRaw -Inner "& '$setupPath' -Mode Launcher -NonInteractive -EscrowDir '$script:escrowDir'"
        $r.Exit   | Should -Not -Be 0
        $r.Output | Should -Match 'ClientListPath'
    }
}
