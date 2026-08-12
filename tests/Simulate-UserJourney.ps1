#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end simulation of what a Curo staff member and their admin actually
    do, on a real Windows host, printing a readable transcript.

.DESCRIPTION
    The Pester suites prove units and the other CI steps prove mechanisms. This
    walks the JOURNEY in order, as a person experiences it:

      1. the admin sets up the first PC (this is what mints the escrow key)
      2. a teammate's PC is set up and ADOPTS that same key
      3. the teammate drags a mixed selection onto the tool
      4. the batch window lists the files and auto-matches clients
      5. they assign the one file that did not match
      6. they click Protect all
      7. the client opens a protected PDF with their date of birth
      8. the compliance records exist (escrow sidecar + audit row per file)
      9. someone forgets a password and it is recovered from the escrow USB
     10. the escrow share goes offline and the tool refuses to protect

    Every DOB used to decrypt is READ BACK from the published client list, not
    hard-coded, so the whole chain - CSV -> client match -> password -> qpdf ->
    escrow -> recovery - is proven joined up rather than merely self-consistent.

    WHAT THIS CANNOT DO: no interactive desktop exists on a CI runner, so no
    window is rendered and no mouse is clicked. Scene 4 onwards drives the same
    module calls the window's handlers drive, and Scene 3 runs the real
    Invoke-Main entry point with UI suppressed. Test-WorkStepParity below pins
    the run loop against the shipped window so this cannot quietly become a
    simulation of code that no longer exists. Rendering and clicking remain the
    job of docs\WIN11-ACCEPTANCE.md.

.PARAMETER ToolRoot
    The tool folder to exercise (repo root by default; pass an extracted
    portable-exe payload to journey through the exe's copy instead).
.PARAMETER WorkRoot
    Sandbox for all machine state. Everything this script writes lives here.
.PARAMETER KeepWorkRoot
    Leave the sandbox behind for inspection.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Simulate-UserJourney.ps1
#>

[CmdletBinding()]
param(
    [string] $ToolRoot,
    [string] $WorkRoot,
    [switch] $KeepWorkRoot
)

$ErrorActionPreference = 'Stop'

if (-not $ToolRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
if (-not $WorkRoot) {
    $WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('curo-journey-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

$script:SceneNo = 0
$script:Passes  = 0

function Scene {
    param([string] $Title)
    $script:SceneNo++
    Write-Host ''
    Write-Host ('== Scene {0}: {1} ' -f $script:SceneNo, $Title).PadRight(78, '=')
}
function Say  { param([string] $M) Write-Host "   $M" }
function Pass { param([string] $M) $script:Passes++; Write-Host "   [PASS] $M" }
function Fail { param([string] $M) throw "JOURNEY FAILED (scene $script:SceneNo): $M" }
function Want { param([bool] $Condition, [string] $M) if (-not $Condition) { Fail $M } else { Pass $M } }

$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

function Invoke-SetupChild {
    <#
      setup.ps1 calls `exit`, which would terminate this script, so it always
      runs in a child process - exactly as a person running it in their own
      console does. Environment redirection makes the child believe it is on a
      different machine.
    #>
    param(
        [Parameter(Mandatory)] [string] $AppRoot,
        [Parameter(Mandatory)] [string] $ProgramData,
        [Parameter(Mandatory)] [string] $LocalAppData,
        [Parameter(Mandatory)] [string] $ArgLine,
        [Parameter(Mandatory)] [string] $Label
    )
    $setup = Join-Path $AppRoot 'setup.ps1'
    $cmd = "`$env:ProgramData='$ProgramData'; `$env:LOCALAPPDATA='$LocalAppData'; " +
           "Remove-Item Env:CURO_SETTINGS_PATH -ErrorAction SilentlyContinue; " +
           "& '$setup' $ArgLine; exit `$LASTEXITCODE"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prev
    Write-Host ''
    Write-Host "      ----- $Label -----"
    foreach ($line in ($out -split "`r?`n")) { if ($line.Trim()) { Write-Host "      $line" } }
    Write-Host "      ----- exit $rc -----"
    Write-Host ''
    return [pscustomobject]@{ ExitCode = $rc; Output = $out }
}

function Test-WorkStepParity {
    <#
      Anti-drift pin. This script re-drives the batch run loop because the
      window's UI-suppression seam returns before ShowDialog, so the dispatcher
      chain never executes headlessly. That is only meaningful if the loop here
      calls the SAME things the shipped window calls. Extract the command names
      inside Prompt-Batch.ps1's $script:WorkStep and require the core three.
    #>
    param([Parameter(Mandatory)] [string] $PromptBatchPath)

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($PromptBatchPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count) { Fail "Prompt-Batch.ps1 has parse errors: $($errors[0].Message)" }

    $assign = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq 'script:WorkStep'
    }, $true) | Select-Object -First 1
    if (-not $assign) { Fail 'Could not find $script:WorkStep in Prompt-Batch.ps1 - the batch window was restructured.' }

    $names = @($assign.Right.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($required in 'New-BatchPromptResult', 'Invoke-ProtectFileCore', 'Set-BatchRowStatus') {
        if ($names -notcontains $required) {
            Fail "The window's WorkStep no longer calls $required (it calls: $($names -join ', ')). This simulation would be testing a loop the product does not run."
        }
    }
    return $names
}

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '###############################################################################'
Write-Host '#  Curo PDF Protector - simulated user journey                                #'
Write-Host '###############################################################################'
Say "tool     : $ToolRoot"
Say "sandbox  : $WorkRoot"
Say "host     : $([Environment]::OSVersion.VersionString)  PS $($PSVersionTable.PSVersion)"

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

$script:SavedProgramData  = $env:ProgramData
$script:SavedLocalAppData = $env:LOCALAPPDATA

# The two shared locations a real deployment needs, plus the recovery USB.
$shared    = Join-Path $WorkRoot 'shared'           # stands in for the office share
$escrowDir = Join-Path $shared   'PDFProtect-Escrow'
$clientCsv = Join-Path $shared   'clients.csv'
$usbPfx    = Join-Path $WorkRoot 'usb\curo-escrow.pfx'
$pfxPw     = 'journey-pfx-pw'
New-Item -ItemType Directory -Force -Path $shared, (Join-Path $WorkRoot 'usb') | Out-Null

$fixture = Join-Path $ToolRoot 'tests\fixtures\clients-sample.csv'
if (-not (Test-Path -LiteralPath $fixture)) { Fail "client fixture missing at $fixture" }

# Two "machines", each with its own ProgramData + LOCALAPPDATA.
$pc1 = [pscustomobject]@{ Name = 'ADMIN-PC';    Pd = (Join-Path $WorkRoot 'pc1\programdata'); La = (Join-Path $WorkRoot 'pc1\localappdata') }
$pc2 = [pscustomobject]@{ Name = 'TEAMMATE-PC'; Pd = (Join-Path $WorkRoot 'pc2\programdata'); La = (Join-Path $WorkRoot 'pc2\localappdata') }
foreach ($pc in $pc1, $pc2) { New-Item -ItemType Directory -Force -Path $pc.Pd, $pc.La | Out-Null }

try {

# --- Scene 1 ---------------------------------------------------------------
Scene 'The admin sets up the first PC (this is what creates the escrow key)'
Say 'Running: setup.ps1 -Mode Launcher with -PfxPath (the recovery USB)'

$r1 = Invoke-SetupChild -AppRoot $ToolRoot -ProgramData $pc1.Pd -LocalAppData $pc1.La -Label 'setup.ps1 on ADMIN-PC' -ArgLine (
    "-Mode Launcher -NonInteractive -ClientListPath '$clientCsv' -EscrowDir '$escrowDir' " +
    "-ClientSource '$fixture' -PfxPath '$usbPfx' " +
    "-PfxPassword (ConvertTo-SecureString '$pfxPw' -AsPlainText -Force)")

Want ($r1.ExitCode -eq 0) 'setup finished with exit code 0'
Want (Test-Path -LiteralPath (Join-Path $pc1.La 'CuroPDFProtect\settings.json')) 'a per-user settings.json was written'
Want (Test-Path -LiteralPath $usbPfx) 'the recovery key (.pfx) was written to the USB path'
$published = Join-Path $escrowDir '_deployment\escrow.cer'
Want (Test-Path -LiteralPath $published) 'the public certificate was PUBLISHED to the shared escrow folder'
Want (@(Import-Csv -LiteralPath $clientCsv).Count -eq 2) 'the client list published 2 clients (the malformed DOB row was skipped)'

Import-Module (Join-Path $ToolRoot 'src\Config.psm1') -Force -DisableNameChecking
$fp1 = Get-CuroCertFingerprint -Path (Join-Path $pc1.Pd 'CuroPDFProtect\escrow.cer')
Say "escrow key fingerprint on ADMIN-PC: $fp1"

# --- Scene 2 ---------------------------------------------------------------
Scene "A teammate's PC is set up - it must ADOPT the same key, never mint its own"
Say 'Running the SAME command minus -PfxPath / -PfxPassword (as docs\ADMIN-SETUP.md says)'

$r2 = Invoke-SetupChild -AppRoot $ToolRoot -ProgramData $pc2.Pd -LocalAppData $pc2.La -Label 'setup.ps1 on TEAMMATE-PC' -ArgLine (
    "-Mode Launcher -NonInteractive -ClientListPath '$clientCsv' -EscrowDir '$escrowDir' -SkipClientPublish")

Want ($r2.ExitCode -eq 0) 'setup finished with exit code 0'
Want ($r2.Output -match 'Adopted') 'setup reported it ADOPTED the existing deployment key'
Want ($r2.Output -notmatch 'Generated a new escrow') 'setup did NOT mint a second key'

$fp2 = Get-CuroCertFingerprint -Path (Join-Path $pc2.Pd 'CuroPDFProtect\escrow.cer')
Want ($fp1 -eq $fp2) "both PCs carry the SAME escrow key ($fp2) - one recovery USB covers the team"

# From here on we are the teammate.
$env:ProgramData         = $pc2.Pd
$env:LOCALAPPDATA        = $pc2.La
$env:CURO_SETTINGS_PATH  = Join-Path $pc2.La 'CuroPDFProtect\settings.json'
$env:CURO_SUPPRESS_UI    = '1'          # no modal may block an unattended run

$health = Test-CuroHealth
Want ($health.Healthy) 'the health check on the teammate PC is green'
$cfg = $health.Config

# --- Scene 3 ---------------------------------------------------------------
Scene 'The teammate drags a mixed selection onto the tool'

$desk = Join-Path $WorkRoot 'teammate-desktop'
New-Item -ItemType Directory -Force -Path $desk | Out-Null

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'     # qpdf warns on stderr about the hand-built PDF
$rawPdf = Join-Path $desk '_raw.pdf'
@('%PDF-1.4','1 0 obj','<< /Type /Catalog /Pages 2 0 R >>','endobj','2 0 obj',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>','endobj','3 0 obj',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>','endobj','trailer',
  '<< /Root 1 0 R >>','%%EOF') | Set-Content -LiteralPath $rawPdf -Encoding ascii

# Named the way real advice documents are: two will auto-match a client from
# the file name, one deliberately will not.
$pdfNames = @('Smith John SOA.pdf', 'OBrien Mary annual review.pdf', 'quarterly summary.pdf')
$pdfs = @()
foreach ($n in $pdfNames) {
    $dest = Join-Path $desk $n
    & $cfg.qpdf_path $rawPdf $dest 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $dest)) { Fail "could not build the fixture PDF '$n'" }
    $pdfs += $dest
}
Remove-Item -LiteralPath $rawPdf -Force
$ErrorActionPreference = $prev

# The selection Explorer would hand over: 3 PDFs, a Word file, and a folder.
$notPdf = Join-Path $desk 'meeting notes.docx'
Set-Content -LiteralPath $notPdf -Value 'not a pdf' -Encoding ascii
$droppedFolder = Join-Path $desk 'Client files'
New-Item -ItemType Directory -Force -Path $droppedFolder | Out-Null
$dropped = @($pdfs + $notPdf + $droppedFolder)
Say "dropped: $(($dropped | ForEach-Object { Split-Path -Leaf $_ }) -join ' | ')"

# Run the REAL entry point. With UI suppressed the batch window builds itself
# for real (XAML load, rows, wiring) and returns before the modal pump, so this
# proves preflight, health, the non-PDF/folder filter and window construction.
. (Join-Path $ToolRoot 'PasswordProtect.ps1')
$rc = Invoke-Main -InputFiles $dropped
Want ($rc -eq 0) "the real entry point (Invoke-Main) handled the mixed drop and returned $rc"
Say 'The .docx and the folder were filtered out before the window - a non-PDF row could never be given a client, so it would block the run forever.'

# --- Scene 4 ---------------------------------------------------------------
Scene 'The batch window lists the files and auto-matches clients'

Import-Module (Join-Path $ToolRoot 'src\BatchQueue.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ToolRoot 'src\Protect.psm1')    -Force -DisableNameChecking
. (Join-Path $ToolRoot 'src\Find-Client.ps1')

$clientList = Get-ClientList -Config $cfg
Want (-not $clientList.HardFail) 'the client list loaded'

# Assign FIRST, then wrap. New-BatchRowList returns ,$rows so a single-path
# call cannot unroll to a scalar, which means it emits ONE object (the array).
# Inlining as @(New-BatchRowList ...) collects that one object and yields a
# 1-element array containing the array - Count 1, not 3.
$rowList = New-BatchRowList -Paths $pdfs -Config $cfg -ClientList $clientList
$rows = @($rowList)
Want ($rows.Count -eq 3) "the window shows one row per PDF (got $($rows.Count))"

Write-Host ''
Write-Host ('      {0,-12} {1,-32} {2,-24} {3}' -f 'STATUS', 'FILE', 'CLIENT', 'WILL CREATE')
foreach ($row in $rows) {
    Write-Host ('      {0,-12} {1,-32} {2,-24} {3}' -f $row.StatusText, $row.FileName, $row.ClientDisplay, $row.PreviewName)
}
Write-Host ''

$auto = @($rows | Where-Object { $_.AutoMatched })
Want ($auto.Count -eq 2) "2 rows auto-matched their client from the file name (got $($auto.Count))"
$needs = @($rows | Where-Object { $_.Status -eq 'NeedsClient' })
Want ($needs.Count -eq 1) "1 row says `"Needs client`" (got $($needs.Count))"

# 'quarterly summary.pdf' is here on purpose. The file-name matcher works on a
# squashed substring, so "summary" contains "mary" and the file loosely matches
# a client called Mary. That candidate must be OFFERED and never pre-filled:
# auto-assigning it would encrypt an unrelated document with the wrong client's
# date of birth and misattribute the audit and escrow records, on a row that
# looked confidently Ready. This is the bug this journey caught on its first run.
Want ($needs[0].FileName -eq 'quarterly summary.pdf') 'the row needing a client is the one with no real client name in it'
Want ($needs[0].CandidateCount -eq 1) 'it does have one loose candidate ("summary" contains "mary")'
Want ($null -eq $needs[0].Client) 'but that coincidence was NOT pre-filled as the client'
Want (-not (Test-BatchReady -Rows $rows)) '"Protect all" is DISABLED while a row still needs a client'
Want (@($rows | Where-Object { $_.PreviewName -like '*_protected.pdf' }).Count -eq 3) 'every row previews the file it will create'

# --- Scene 5 ---------------------------------------------------------------
Scene 'The teammate assigns the client for the unmatched file'

$hit = @(Find-Client -ClientList $clientList -Query 'Smith')
Want ($hit.Count -ge 1) 'typing "Smith" into the search box returns a match'
$idx = -1
for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Path -eq $needs[0].Path) { $idx = $i; break } }
if ($idx -lt 0) { Fail 'could not locate the unmatched row' }
$rows[$idx] = Set-BatchRowClient -Row $rows[$idx] -Client $hit[0] -Config $cfg
Say "assigned $($rows[$idx].ClientDisplay) to $($rows[$idx].FileName)"
Want ($rows[$idx].Status -eq 'Ready') 'the row flipped to Ready'
Want (Test-BatchReady -Rows $rows) '"Protect all" is now ENABLED (every row has a client)'

# --- Scene 6 ---------------------------------------------------------------
Scene 'The teammate clicks Protect all'

$parity = Test-WorkStepParity -PromptBatchPath (Join-Path $ToolRoot 'src\Prompt-Batch.ps1')
Say "run-loop parity with the shipped window confirmed (WorkStep calls: $($parity -join ', '))"

$options = @{ AllowOverwrite = $false; DeleteOriginal = $false }
for ($i = 0; $i -lt $rows.Count; $i++) {
    $rows[$i] = Set-BatchRowStatus -Row $rows[$i] -Status 'Working'
    $pr = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $pr = New-BatchPromptResult -Row $rows[$i] -Options $options
        $res = Invoke-ProtectFileCore -Config $cfg -Path $rows[$i].Path -PromptResult $pr
        $st = if ($res.Success) { 'OK' } else { 'Failed' }
        $rows[$i] = Set-BatchRowStatus -Row $rows[$i] -Status $st -Message ([string]$res.Message) -OutputPath ([string]$res.OutputPath)
    } finally {
        if ($pr -and $pr.SecurePassword) { $pr.SecurePassword.Dispose() }
    }
    $sw.Stop()
    Write-Host ('      {0,-32} {1,-8} {2,5} ms' -f $rows[$i].FileName, $rows[$i].StatusText, $sw.ElapsedMilliseconds)
}

$summary = Get-BatchSummary -Rows $rows
Say "summary line the window shows: Protected $($summary.Ok) of $($summary.Total) file(s)."
Want ($summary.Ok -eq 3) 'all 3 files protected'
Want ($summary.Failed -eq 0) 'no failures'
Want ($summary.ExitCode -eq 0) 'the run reports exit code 0 (the launcher will not show a scary console)'

# --- Scene 7 ---------------------------------------------------------------
Scene 'The client opens the protected PDF with their date of birth'

$ErrorActionPreference = 'Continue'
foreach ($row in $rows) {
    Want (Test-Path -LiteralPath $row.OutputPath) "produced $(Split-Path -Leaf $row.OutputPath)"
    Want (Test-Path -LiteralPath $row.Path) 'the original was left alone'

    # The DOB is read back from the PUBLISHED client list via the row's client
    # reference - never hard-coded - so a broken CSV -> client -> password link
    # would fail here rather than passing vacuously.
    $client = @($clientList.Clients | Where-Object { $_.FileRef -eq $row.Client.FileRef })[0]
    Want ($null -ne $client) "found $($row.Client.FileRef) in the published client list"

    $dec = "$($row.OutputPath).decrypted.pdf"
    & $cfg.qpdf_path "--password=$($client.Dob)" --decrypt $row.OutputPath $dec 2>&1 | Out-Null
    Want (($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) -and (Test-Path -LiteralPath $dec)) `
        "$(Split-Path -Leaf $row.OutputPath) opens with that client's DOB (DDMMYYYY from clients.csv)"

    # And it must NOT open without a password - the whole point.
    $bad = "$($row.OutputPath).nopw.pdf"
    & $cfg.qpdf_path --decrypt $row.OutputPath $bad 2>&1 | Out-Null
    Want ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $bad)) 'it is genuinely encrypted (no password = refused)'
}
$ErrorActionPreference = 'Stop'

# --- Scene 8 ---------------------------------------------------------------
Scene 'The compliance trail exists (this is the AFSL-facing part)'

$sidecars = @(Get-ChildItem -Path $escrowDir -Filter '*.escrow.json' -Recurse -ErrorAction SilentlyContinue)
Want ($sidecars.Count -eq 3) "one escrow recovery record per protected file ($($sidecars.Count))"
$entry = Get-Content -LiteralPath $sidecars[0].FullName -Raw | ConvertFrom-Json
Want ($entry.key_wrap_algorithm -eq 'rsa-oaep-sha256-cert') 'passwords are wrapped with RSA-OAEP-SHA256'
Want ($entry.public_key_fingerprint -eq $fp1) 'wrapped under the ONE team escrow key'

# The passwords ARE the clients' DOBs, so the real check is that no DOB appears
# in clear anywhere in the escrow records or the audit log - only wrapped.
$dobs = @($clientList.Clients | ForEach-Object { $_.Dob })
Want ($dobs.Count -ge 2) "checking against $($dobs.Count) real client DOBs from the list"
$sidecarText = (($sidecars | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n")
$leaked = @($dobs | Where-Object { $sidecarText -match [regex]::Escape($_) })
Want ($leaked.Count -eq 0) 'no client DOB appears in clear text in any escrow sidecar'

$auditLines = @(Get-Content -LiteralPath $cfg.audit_log_path | Where-Object { $_.Trim() })
$okRows = @($auditLines | Where-Object { $_ -match '"outcome":"ok"' })
Want ($okRows.Count -eq 3) "the audit log has an 'ok' row per file ($($okRows.Count))"
foreach ($line in $auditLines) { $null = $line | ConvertFrom-Json }
Pass 'every audit line is valid JSON (the log stays machine-readable for the 7-year obligation)'
$auditText = ($auditLines -join "`n")
$auditLeak = @($dobs | Where-Object { $auditText -match [regex]::Escape($_) })
Want ($auditLeak.Count -eq 0) 'no client DOB appears in the audit log either (it records the client reference instead)'

# --- Scene 9 ---------------------------------------------------------------
Scene 'Someone forgets a password - the admin recovers it from the USB'

. (Join-Path $ToolRoot 'admin\Recover-File.ps1')       # guarded: defines Unprotect-EscrowEntry only
$target = $rows[0]
$targetSha = (Get-FileHash -LiteralPath $target.OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
$match = @($sidecars | Where-Object { $_.Name -eq "$targetSha.escrow.json" })
Want ($match.Count -eq 1) 'the protected file is found in the escrow store by its SHA-256'

$entry = Get-Content -LiteralPath $match[0].FullName -Raw | ConvertFrom-Json
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
    $usbPfx, (ConvertTo-SecureString $pfxPw -AsPlainText -Force),
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
try { $recovered = Unprotect-EscrowEntry -Entry $entry -Certificate $cert -Which user } finally { $cert.Dispose() }

$expected = @($clientList.Clients | Where-Object { $_.FileRef -eq $target.Client.FileRef })[0].Dob
Want ($recovered -eq $expected) 'the recovered password equals that client DOB'
Say 'Note: the file was protected on TEAMMATE-PC and recovered with the key generated on ADMIN-PC - the cross-machine case that a split key would break.'

# --- Scene 10 --------------------------------------------------------------
Scene 'A client sends a protected PDF back - staff strip the password'

$ErrorActionPreference = 'Continue'
$target = $rows[0]
$client = @($clientList.Clients | Where-Object { $_.FileRef -eq $target.Client.FileRef })[0]
$ss = New-Object System.Security.SecureString
foreach ($ch in ([string]$client.Dob).ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$unprotPrompt = [pscustomobject]@{
    SecurePassword = $ss; PasswordSource = 'dob'; ClientFileRef = $client.FileRef
    DeleteOriginal = $false; AllowOverwrite = $false; OpenOutlook = $false; Cancelled = $false
}
try {
    $unp = Invoke-UnprotectFileCore -Config $cfg -Path $target.OutputPath -PromptResult $unprotPrompt
} finally { $ss.Dispose() }
$ErrorActionPreference = 'Stop'

Want ($unp.Success) "removed the protection from $(Split-Path -Leaf $target.OutputPath)"
Want ($unp.OutputPath -like '*_unprotected.pdf') "named it $(Split-Path -Leaf $unp.OutputPath) - not _protected_unprotected"
Want (Test-Path -LiteralPath $target.OutputPath) 'the protected original is still there (its escrow record still points at a real file)'

$ErrorActionPreference = 'Continue'
$plain = Join-Path (Split-Path -Parent $unp.OutputPath) 'opened-with-nothing.pdf'
& $cfg.qpdf_path $unp.OutputPath $plain 2>&1 | Out-Null
Want (($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) -and (Test-Path -LiteralPath $plain)) 'the copy opens with NO password at all'

# Wrong password must be refused, and leave nothing behind.
$bad = New-Object System.Security.SecureString
foreach ($ch in '31129999'.ToCharArray()) { $bad.AppendChar($ch) }
$bad.MakeReadOnly()
$badPrompt = [pscustomobject]@{ SecurePassword=$bad; PasswordSource='manual'; ClientFileRef=$null
                                DeleteOriginal=$false; AllowOverwrite=$false; OpenOutlook=$false; Cancelled=$false }
try { $badRes = Invoke-UnprotectFileCore -Config $cfg -Path $rows[1].OutputPath -PromptResult $badPrompt }
finally { $bad.Dispose() }
$ErrorActionPreference = 'Stop'
Want (-not $badRes.Success -and $badRes.ErrorCode -eq 'BAD_PASSWORD') 'a wrong password is refused as BAD_PASSWORD, not a silent empty file'

$unprotRows = @(Get-Content -LiteralPath $cfg.audit_log_path | Where-Object { $_ -match '"op":"unprotect"' })
Want ($unprotRows.Count -eq 2) "both removals - the good one and the refused one - are in the audit log ($($unprotRows.Count))"
Say 'No escrow record is written for an unprotected copy (there is no password to recover), so the audit row is the only trace - which is why it is written on failure too.'

# --- Scene 11 --------------------------------------------------------------
Scene 'The escrow share goes offline - the tool must refuse to protect'

$ErrorActionPreference = 'Continue'
$offlineWork = Join-Path $WorkRoot 'offline-test'
New-Item -ItemType Directory -Force -Path $offlineWork | Out-Null
$victim = Join-Path $offlineWork 'Smith John extra.pdf'
Copy-Item -LiteralPath $rows[0].Path -Destination $victim -Force

$brokenCfg = $cfg.PSObject.Copy()
$brokenCfg.escrow_dir = Join-Path $WorkRoot 'escrow-gone\deeper'
Set-Content -LiteralPath (Join-Path $WorkRoot 'escrow-gone') -Value 'a file, so no directory can be made under it' -Encoding ascii

$offRow = New-BatchRow -Path $victim -Config $brokenCfg -ClientList $clientList
$offRow = Set-BatchRowStatus -Row $offRow -Status 'Working'
$pr = New-BatchPromptResult -Row $offRow -Options $options
try {
    $res = Invoke-ProtectFileCore -Config $brokenCfg -Path $victim -PromptResult $pr
} finally { $pr.SecurePassword.Dispose() }
$ErrorActionPreference = 'Stop'

Want (-not $res.Success) 'the protect was refused'
Want ($res.ErrorCode -eq 'ESCROW_OFFLINE') "it reported ESCROW_OFFLINE (got '$($res.ErrorCode)')"
$leftBehind = @(Get-ChildItem -Path $offlineWork -Filter '*_protected.pdf' -ErrorAction SilentlyContinue)
Want ($leftBehind.Count -eq 0) 'NO protected file was left behind - so no file exists that cannot be recovered'
Want ((Get-Content -LiteralPath $cfg.audit_log_path -Raw) -match 'ESCROW_OFFLINE') 'the refusal was audited'
Say 'In the window this row shows FAILED and the run stops - the remaining rows are marked "Not run" rather than ground through.'

# --- Verdict ---------------------------------------------------------------
Write-Host ''
Write-Host '###############################################################################'
Write-Host "#  JOURNEY COMPLETE - $($script:Passes) checks passed across $($script:SceneNo) scenes"
Write-Host '###############################################################################'
Write-Host ''
Write-Host 'Still requires a human on a real Windows 11 PC (docs\WIN11-ACCEPTANCE.md):'
Write-Host '  - the window actually appears, and the list/search/buttons are usable'
Write-Host '  - the right-click verb is visible where staff look for it'
Write-Host '  - Windows lets the exe run (SmartScreen / Smart App Control)'
Write-Host '  - Outlook attach on a PC that has classic Outlook'
Write-Host ''

} finally {
    Remove-Item Env:CURO_SETTINGS_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:CURO_SUPPRESS_UI   -ErrorAction SilentlyContinue
    # Restore the redirected machine paths - this script is meant to be safe to
    # run on a real PC, where clobbering these for the rest of the session would
    # be rude at best.
    if ($script:SavedProgramData)  { $env:ProgramData  = $script:SavedProgramData }
    if ($script:SavedLocalAppData) { $env:LOCALAPPDATA = $script:SavedLocalAppData }
    if (-not $KeepWorkRoot) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Sandbox kept at: $WorkRoot"
    }
}
