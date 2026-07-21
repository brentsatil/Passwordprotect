#Requires -Modules Pester
<#
  End-to-end test of the guided setup.ps1 in Launcher mode.

  setup.ps1 runs in a CHILD powershell.exe (so its env changes - including
  CURO_SETTINGS_PATH - never leak into the Pester session) with %ProgramData%
  redirected under $TestDrive, so the escrow cert / audit / cache land in the
  sandbox instead of the real machine.
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

    function Invoke-Setup {
        param([string[]] $ExtraArgs = @(), [string] $Pfx = $script:pfxPath)
        $setupPath = Join-Path $script:app 'setup.ps1'
        $argLine = @(
            "-Mode Launcher -NonInteractive"
            "-ClientListPath '$script:clientOut'"
            "-EscrowDir '$script:escrowDir'"
            "-ClientSource '$script:fixture'"
            "-PfxPath '$Pfx'"
            "-PfxPassword (ConvertTo-SecureString 'test-pfx-pw-1' -AsPlainText -Force)"
        ) + $ExtraArgs -join ' '
        $cmd = "`$env:ProgramData='$script:pd'; & '$setupPath' $argLine; exit `$LASTEXITCODE"
        & $script:psExe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String | Write-Host
        return $LASTEXITCODE
    }
}

Describe 'setup.ps1 -Mode Launcher (first run)' {
    BeforeAll { $script:rc = Invoke-Setup }

    It 'exits 0' { $script:rc | Should -Be 0 }

    It 'writes a valid settings.json into the tool config folder' {
        $script:settings | Should -Exist
        Import-Module (Join-Path $script:app 'src\Config.psm1') -Force
        $cfg = Get-CuroConfig -Path $script:settings
        $cfg.schema_version | Should -Be 1
        $cfg.qpdf_path | Should -Match 'bin\\qpdf.exe$'
    }

    It 'generates the escrow keypair (public cert + private pfx)' {
        (Join-Path $script:pd 'CuroPDFProtect\escrow.cer') | Should -Exist
        $script:pfxPath | Should -Exist
    }

    It 'publishes the client list, skipping the malformed DOB row' {
        $script:clientOut | Should -Exist
        $rows = Import-Csv -LiteralPath $script:clientOut
        # fixture has 3 rows; the 99/99/9999 one is rejected.
        @($rows).Count | Should -Be 2
    }
}

Describe 'setup.ps1 -Mode Launcher (idempotent re-run)' {
    It 're-runs cleanly and leaves the escrow certificate untouched' {
        $certPath = Join-Path $script:pd 'CuroPDFProtect\escrow.cer'
        $before = (Get-FileHash -Algorithm SHA256 -LiteralPath $certPath).Hash
        $rc2 = Invoke-Setup
        $rc2 | Should -Be 0
        (Get-FileHash -Algorithm SHA256 -LiteralPath $certPath).Hash | Should -Be $before
    }
}

Describe 'setup.ps1 -NonInteractive with a missing required value' {
    It 'fails fast and names the missing parameter' {
        $setupPath = Join-Path $script:app 'setup.ps1'
        # Omit -ClientListPath; -NonInteractive must refuse to prompt.
        $cmd = "`$env:ProgramData='$script:pd'; & '$setupPath' -Mode Launcher -NonInteractive -EscrowDir '$script:escrowDir'; exit `$LASTEXITCODE"
        $out = & $script:psExe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'ClientListPath'
    }
}
