#Requires -Version 5.1
<#
.SYNOPSIS
    Copy this machine's audit log into the shared 7-year audit archive.
.DESCRIPTION
    The audit log is deliberately PER MACHINE. It cannot simply be pointed at a
    file share: appends are serialised with a machine-scoped mutex
    (Global\CuroPDFProtect.AuditLog, src\Logging.psm1) and opened with
    FileShare.Read, so a second host appending to the same file hits a sharing
    violation - and the heartbeat write is not guarded, which turns that into a
    FAILED PROTECT. Centralising the live log would break the tool.

    So each host keeps writing locally and this script copies the log into a
    dated per-host folder in the archive:

        <ArchiveRoot>\<yyyy>\<MM>\<HOSTNAME>\audit-<yyyyMMdd-HHmmss>.log

    Copies are additive and never overwrite, so the archive is append-only in
    practice and a machine being rebuilt or decommissioned does not lose
    history. admin\Get-AuditSummary.ps1 -AuditPath can read any single file, and
    -Combined here produces one merged file for a period.

    Run it on each machine on a schedule (Task Scheduler, weekly), or by hand
    before decommissioning a PC - see docs\RUNBOOK.md.
.PARAMETER ArchiveRoot
    Shared folder for the archive. Defaults to <escrow_dir>\_audit-archive so a
    deployment that already has a shared escrow location needs no new config.
.PARAMETER AuditPath
    Source log. Defaults to the configured audit_log_path.
.PARAMETER Combined
    Also write a single merged, chronologically sorted file for the whole
    archive - convenient for handing an auditor one artefact.
.PARAMETER PruneLocalOlderThanDays
    After a SUCCESSFUL archive copy, drop events older than this many days from
    the LOCAL log to stop it growing without bound. Nothing is ever pruned that
    has not been archived first. Defaults to 0 (never prune).
.EXAMPLE
    .\Export-AuditArchive.ps1
.EXAMPLE
    .\Export-AuditArchive.ps1 -Combined -PruneLocalOlderThanDays 400
#>

[CmdletBinding()]
param(
    [string] $ArchiveRoot,
    [string] $AuditPath,
    [switch] $Combined,
    [int]    $PruneLocalOlderThanDays = 0
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root = Split-Path -Parent $here

if (-not $ArchiveRoot -or -not $AuditPath) {
    Import-Module (Join-Path $root 'src\Config.psm1') -Force
    $cfg = Get-CuroConfig
    if (-not $AuditPath)   { $AuditPath   = [Environment]::ExpandEnvironmentVariables($cfg.audit_log_path) }
    if (-not $ArchiveRoot) { $ArchiveRoot = Join-Path $cfg.escrow_dir '_audit-archive' }
    if ($PruneLocalOlderThanDays -le 0 -and $cfg.PSObject.Properties['audit_log_retention_days']) {
        # audit_log_retention_days was validated but never actually used by any
        # code. It is the retention floor: never prune anything younger.
        $script:RetentionFloorDays = [int]$cfg.audit_log_retention_days
    }
}
if (-not $script:RetentionFloorDays) { $script:RetentionFloorDays = 2555 }

if (-not (Test-Path -LiteralPath $AuditPath)) { throw "Audit log not found at '$AuditPath'." }

$now  = (Get-Date).ToUniversalTime()
$dest = Join-Path (Join-Path (Join-Path $ArchiveRoot $now.ToString('yyyy')) $now.ToString('MM')) $env:COMPUTERNAME
try {
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null }
} catch {
    throw "Audit archive '$ArchiveRoot' is unreachable: $($_.Exception.Message)"
}

$stamp  = $now.ToString('yyyyMMdd-HHmmss')
$target = Join-Path $dest "audit-$stamp.log"

# Copy via a temp name then move, so a reader never sees a half-written file.
$tmp = "$target.partial"
Copy-Item -LiteralPath $AuditPath -Destination $tmp -Force
Move-Item -LiteralPath $tmp -Destination $target -Force

$lines = @(Get-Content -LiteralPath $target -ErrorAction SilentlyContinue)
Write-Host "Archived $($lines.Count) audit line(s) from $env:COMPUTERNAME to:"
Write-Host "  $target"

if ($Combined) {
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -Path $ArchiveRoot -Filter 'audit-*.log' -Recurse -ErrorAction SilentlyContinue) {
        foreach ($l in Get-Content -LiteralPath $f.FullName) {
            if (-not $l.Trim()) { continue }
            $o = $null
            try { $o = $l | ConvertFrom-Json } catch { continue }
            # De-duplicate: each archive run copies the WHOLE log, so the same
            # event appears in every snapshot taken after it was written.
            $all.Add([pscustomobject]@{ Key = ("{0}|{1}|{2}" -f $o.ts, $o.host, $o.op); Line = $l; Ts = $o.ts }) | Out-Null
        }
    }
    $merged = Join-Path $ArchiveRoot 'audit-combined.log'
    $unique = $all | Group-Object Key | ForEach-Object { $_.Group[0] } | Sort-Object Ts
    [System.IO.File]::WriteAllLines($merged, [string[]]($unique | ForEach-Object { $_.Line }), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Combined $($unique.Count) unique event(s) into:"
    Write-Host "  $merged"
}

if ($PruneLocalOlderThanDays -gt 0) {
    if ($PruneLocalOlderThanDays -lt $script:RetentionFloorDays) {
        Write-Warning ("Refusing to prune at $PruneLocalOlderThanDays days: audit_log_retention_days is $($script:RetentionFloorDays). " +
                       'The archive copy is the retained record, but the local log must not be trimmed below the configured retention.')
    } else {
        $cutoff = $now.AddDays(-$PruneLocalOlderThanDays)
        $keep = @()
        foreach ($l in Get-Content -LiteralPath $AuditPath) {
            if (-not $l.Trim()) { continue }
            $o = $null
            try { $o = $l | ConvertFrom-Json } catch { $keep += $l; continue }   # keep anything unparseable
            $ts = $null
            if (-not [datetime]::TryParse([string]$o.ts, [ref]$ts)) { $keep += $l; continue }
            if ($ts.ToUniversalTime() -ge $cutoff) { $keep += $l }
        }
        [System.IO.File]::WriteAllLines($AuditPath, [string[]]$keep, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Local log pruned to $($keep.Count) line(s) newer than $PruneLocalOlderThanDays days (archive retains the rest)."
    }
}
