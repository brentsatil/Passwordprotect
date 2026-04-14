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
    [int]    $Days = 7
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root = Split-Path -Parent $here
Import-Module (Join-Path $root 'src\Config.psm1') -Force
$config = Get-CuroConfig
if (-not $AuditPath) { $AuditPath = [Environment]::ExpandEnvironmentVariables($config.audit_log_path) }

if (-not (Test-Path -LiteralPath $AuditPath)) { throw "Audit log not found at $AuditPath" }

$cutoff = (Get-Date).AddDays(-$Days).ToUniversalTime()
$events = Get-Content -LiteralPath $AuditPath |
    ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
    Where-Object { $_ -and ([datetime]$_.ts) -ge $cutoff }

if (-not $events) { Write-Host "No events in the last $Days days."; return }

Write-Host "=== Curo PDF Protector — last $Days days ===" -ForegroundColor Cyan
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
