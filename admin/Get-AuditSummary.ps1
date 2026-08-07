#Requires -Version 5.1
<#
.SYNOPSIS
    Weekly summary of the tool's audit log across the business.
.DESCRIPTION
    Aggregates JSONL audit events from one or more hosts (copy them to a
    common folder, or run this on each host and aggregate in Excel).
    Prints counts by user, by outcome, by error_code, and flags anomalies.
#>

[CmdletBinding()]
param(
    [string] $AuditPath,
    [int]    $Days = 7,
    # Summarise the whole shared archive (every host) instead of just this
    # machine's log. Point it at the folder admin\Export-AuditArchive.ps1
    # writes to, or omit the value to use <escrow_dir>\_audit-archive.
    [string] $ArchiveRoot,
    [switch] $Archive
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root = Split-Path -Parent $here
# The audit path is the only thing config provides here; skip the config load
# entirely when the caller passes -AuditPath (e.g. aggregating copied logs).
if (-not $AuditPath -and -not $ArchiveRoot) {
    Import-Module (Join-Path $root 'src\Config.psm1') -Force
    $cfg = Get-CuroConfig
    if ($Archive) { $ArchiveRoot = Join-Path $cfg.escrow_dir '_audit-archive' }
    else          { $AuditPath   = [Environment]::ExpandEnvironmentVariables($cfg.audit_log_path) }
}

# One machine's log, or every host's snapshots from the archive. Each archive
# run copies the whole log, so the same event recurs across snapshots and must
# be de-duplicated or every count would be inflated.
$rawLines = @()
if ($ArchiveRoot) {
    if (-not (Test-Path -LiteralPath $ArchiveRoot)) { throw "Audit archive not found at $ArchiveRoot" }
    $files = @(Get-ChildItem -Path $ArchiveRoot -Filter 'audit-*.log' -Recurse -ErrorAction SilentlyContinue)
    if (-not $files.Count) { throw "No archived audit logs under $ArchiveRoot. Run admin\Export-AuditArchive.ps1 on each machine first." }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $files) {
        foreach ($l in Get-Content -LiteralPath $f.FullName) {
            if ($l.Trim() -and $seen.Add($l)) { $rawLines += $l }
        }
    }
    Write-Host "Archive: $($files.Count) snapshot(s), $($rawLines.Count) unique event(s) from $ArchiveRoot"
} else {
    if (-not (Test-Path -LiteralPath $AuditPath)) { throw "Audit log not found at $AuditPath" }
    $rawLines = @(Get-Content -LiteralPath $AuditPath)
}

$cutoff = (Get-Date).AddDays(-$Days).ToUniversalTime()
$events = $rawLines |
    ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
    Where-Object { $_ -and ([datetime]$_.ts) -ge $cutoff }

if (-not $events) { Write-Host "No events in the last $Days days."; return }

Write-Host "=== Curo PDF Protector - last $Days days ===" -ForegroundColor Cyan
Write-Host ("Events:            {0}" -f $events.Count)
Write-Host ""

Write-Host "By operation:"
$events | Group-Object op | Sort-Object Count -Descending | ForEach-Object {
    "  {0,-20} {1,5}" -f $_.Name, $_.Count
}
Write-Host ""

Write-Host "By outcome:"
$events | Group-Object outcome | Sort-Object Count -Descending | ForEach-Object {
    "  {0,-20} {1,5}" -f $_.Name, $_.Count
}
Write-Host ""

$errors = $events | Where-Object error_code
if ($errors) {
    Write-Host "Errors by code:" -ForegroundColor Yellow
    $errors | Group-Object error_code | Sort-Object Count -Descending | ForEach-Object {
        "  {0,-20} {1,5}" -f $_.Name, $_.Count
    }
    Write-Host ""
}

Write-Host "By user:"
$events | Group-Object user | Sort-Object Count -Descending | ForEach-Object {
    "  {0,-30} {1,5}" -f $_.Name, $_.Count
}
Write-Host ""

Write-Host "Password source (protect ops):"
$events | Where-Object op -eq 'protect' | Where-Object outcome -eq 'ok' |
    Group-Object password_source | ForEach-Object {
        "  {0,-10} {1,5}" -f $_.Name, $_.Count
    }
