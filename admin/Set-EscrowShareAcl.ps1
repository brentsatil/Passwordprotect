#Requires -Version 5.1
<#
.SYNOPSIS
    Apply the escrow-share permissions docs\DECISIONS.md #4 describes.
.DESCRIPTION
    DECISIONS #4 states: "Read access on the escrow share: Brent and Ian only.
    Write access: SYSTEM + domain users (tool writes)." Nothing in the repo
    implemented that, so in practice the escrow folder inherited whatever the
    parent share had - usually full read for everyone, which means any staff
    member can enumerate every recovery record in the practice.

    Staff genuinely need very little. Tracing what the tool does
    (src\Write-Escrow.ps1):
      - create the YYYY\MM folder      -> CreateDirectories on the root
      - write <sha>.escrow.json.tmp    -> CreateFiles/WriteData
      - rename it into place           -> Delete on the temp it just made
      - Test-Path the result           -> ReadAttributes
    Reading sidecar CONTENT is only ever done by admin\Recover-File.ps1. So
    staff get write-without-read and recovery operators get full control.

    Note this is write-only by convention, not a hard guarantee: a user who can
    create a file can generally read the one they just created. It stops casual
    enumeration of everyone else's records, which is the actual risk.

.PARAMETER EscrowDir
    Escrow root. Defaults to the configured escrow_dir.
.PARAMETER RecoveryOperator
    Identities that may READ recovery records (the people who hold the .pfx).
    Accepts DOMAIN\user, DOMAIN\group or a local group.
.PARAMETER StaffGroup
    Identity that may WRITE records. Defaults to BUILTIN\Users.
.PARAMETER WhatIf
    Show the ACEs that would be applied and change nothing.
.EXAMPLE
    .\Set-EscrowShareAcl.ps1 -RecoveryOperator 'CURO\brent','CURO\ian' -WhatIf
.EXAMPLE
    .\Set-EscrowShareAcl.ps1 -RecoveryOperator 'CURO\Escrow Operators' -StaffGroup 'CURO\Domain Users'
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]   $EscrowDir,
    [Parameter(Mandatory)] [string[]] $RecoveryOperator,
    [string]   $StaffGroup = 'BUILTIN\Users'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root = Split-Path -Parent $here

if (-not $EscrowDir) {
    Import-Module (Join-Path $root 'src\Config.psm1') -Force
    $EscrowDir = (Get-CuroConfig).escrow_dir
}
if (-not (Test-Path -LiteralPath $EscrowDir)) { throw "Escrow directory not found at '$EscrowDir'." }

$FSR = [System.Security.AccessControl.FileSystemRights]
$both = 'ContainerInherit,ObjectInherit'

# Write-but-not-read for staff: enough to create the YYYY\MM shard and drop a
# sidecar in it, and to clean up their own temp file - but NOT ReadData, so the
# folder cannot be browsed for other people's records.
$staffRights = $FSR::CreateFiles -bor $FSR::CreateDirectories -bor $FSR::WriteData -bor
               $FSR::AppendData  -bor $FSR::WriteAttributes   -bor $FSR::WriteExtendedAttributes -bor
               $FSR::ReadAttributes -bor $FSR::Synchronize -bor $FSR::DeleteSubdirectoriesAndFiles

$acl = Get-Acl -LiteralPath $EscrowDir
$acl.SetAccessRuleProtection($true, $false)   # break inheritance; drop inherited ACEs

foreach ($id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $id, 'FullControl', $both, 'None', 'Allow')))
}
foreach ($id in $RecoveryOperator) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $id, 'FullControl', $both, 'None', 'Allow')))
}
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $StaffGroup, $staffRights, $both, 'None', 'Allow')))

Write-Host "Escrow root: $EscrowDir"
Write-Host "  FullControl : SYSTEM, BUILTIN\Administrators, $($RecoveryOperator -join ', ')"
Write-Host "  Write-only  : $StaffGroup (create/write records, no directory read)"

if ($PSCmdlet.ShouldProcess($EscrowDir, 'Apply escrow ACL')) {
    Set-Acl -LiteralPath $EscrowDir -AclObject $acl
    Write-Host 'Applied.'
    Write-Host 'Verify a staff account can still protect a file, and that'
    Write-Host 'admin\Recover-File.ps1 still works for a recovery operator.'
    Write-Host 'NOTE: admin\Get-PDFProtectDiagnostics.ps1 enumerates this folder,'
    Write-Host 'so it will report 0 sidecars when run by a staff account - that'
    Write-Host 'is the ACL working, not an empty escrow store.'
} else {
    Write-Host '(WhatIf) No changes made.'
}
