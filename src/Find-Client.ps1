#Requires -Version 5.1
<#
.SYNOPSIS
    Loads and searches the Curo client CSV for the password picker.
.DESCRIPTION
    Reads the configured CSV (client_name, dob, file_ref), normalises DOBs to
    the canonical DDMMYYYY zero-padded 8-digit string, applies staleness
    rules (warn / hard-fail), falls back to a local cache when the share is
    temporarily unreachable, and exposes a type-ahead search.

    Returns PSCustomObjects — never ANY password-like data. DOB is the
    "password" only by policy convention; callers must treat it with the
    same care as a user-typed password (pipe to stdin, zero the memory).
#>

[CmdletBinding()]
param()

function Get-NormalisedDob {
    <#
    .SYNOPSIS
      Strip non-digits, validate 8-digit DDMMYYYY, return normalised string
      or $null if the row is malformed.
    #>
    param([string] $Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $digits = ($Raw -replace '[^\d]', '')
    if ($digits.Length -ne 8) { return $null }

    # Try DDMMYYYY first (AU convention). If that doesn't parse as a real
    # date, try YYYYMMDD as a fallback — we never guess from the leading
    # two characters alone (that breaks real DOBs with day 19 or 20).
    $try1_dd = [int]$digits.Substring(0,2)
    $try1_mm = [int]$digits.Substring(2,2)
    $try1_yy = [int]$digits.Substring(4,4)

    $try2_yy = [int]$digits.Substring(0,4)
    $try2_mm = [int]$digits.Substring(4,2)
    $try2_dd = [int]$digits.Substring(6,2)

    function Test-DateParts {
        param([int]$Dd, [int]$Mm, [int]$Yy)
        if ($Mm -lt 1 -or $Mm -gt 12) { return $false }
        if ($Dd -lt 1 -or $Dd -gt 31) { return $false }
        if ($Yy -lt 1900 -or $Yy -gt 2100) { return $false }
        try { [void][datetime]::new($Yy, $Mm, $Dd); return $true } catch { return $false }
    }

    if (Test-DateParts $try1_dd $try1_mm $try1_yy) {
        $dd = $try1_dd; $mm = $try1_mm; $yyyy = $try1_yy
    }
    elseif (Test-DateParts $try2_dd $try2_mm $try2_yy) {
        $dd = $try2_dd; $mm = $try2_mm; $yyyy = $try2_yy
    }
    else {
        return $null
    }

    return ('{0:00}{1:00}{2:0000}' -f $dd, $mm, $yyyy)
}

function Get-ClientList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config
    )

    $primary = $Config.client_lookup_file
    $cache   = $Config.client_lookup_cache_path
    $warnDays = [int]$Config.client_lookup_warn_days
    $failDays = [int]$Config.client_lookup_fail_days
    $cacheHrs = [int]$Config.client_lookup_cache_hours

    $source = $null
    $sourceKind = $null

    # Try primary (network share) first.
    if (Test-Path -LiteralPath $primary) {
        try {
            $source = $primary
            $sourceKind = 'primary'
            # Refresh cache on successful primary read.
            $cacheDir = Split-Path $cache -Parent
            if (-not (Test-Path $cacheDir)) {
                New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $primary -Destination $cache -Force
        } catch {
            Write-Warning "Could not refresh client cache from '$primary': $($_.Exception.Message)"
        }
    }
    elseif (Test-Path -LiteralPath $cache) {
        $source = $cache
        $sourceKind = 'cache'
    }
    else {
        return [pscustomobject]@{
            Source = $null
            SourceKind = 'none'
            AgeDays = $null
            Stale = $true
            HardFail = $true
            Clients = @()
            Warning = "No client list available (primary share unreachable and no local cache)."
        }
    }

    $age = (Get-Date) - (Get-Item -LiteralPath $source).LastWriteTime
    $ageDays = [math]::Floor($age.TotalDays)
    $stale = $ageDays -ge $warnDays
    $hardFail = ($sourceKind -eq 'cache' -and $age.TotalHours -gt $cacheHrs) -or ($ageDays -ge $failDays)

    $warning = $null
    if ($hardFail) {
        $warning = "Client list is $ageDays days old and beyond the hard-fail threshold. Ask the Practice Administrator to run Publish-Clients.ps1."
    } elseif ($stale) {
        $warning = "Client list is $ageDays days old. Please ask the Practice Administrator to refresh it."
    } elseif ($sourceKind -eq 'cache') {
        $warning = "Using local cached client list (network share unreachable)."
    }

    $rows = @()
    $malformed = 0
    try {
        $rows = Import-Csv -LiteralPath $source -Encoding UTF8
    } catch {
        return [pscustomobject]@{
            Source = $source
            SourceKind = $sourceKind
            AgeDays = $ageDays
            Stale = $true
            HardFail = $true
            Clients = @()
            Warning = "Could not parse client CSV: $($_.Exception.Message)"
        }
    }

    $clients = foreach ($r in $rows) {
        $norm = Get-NormalisedDob $r.dob
        if (-not $norm) { $malformed++; continue }
        [pscustomobject]@{
            Name    = $r.client_name
            Dob     = $norm              # canonical DDMMYYYY
            FileRef = $r.file_ref
            Display = if ($r.file_ref) { "$($r.client_name)  —  $($r.file_ref)" } else { $r.client_name }
        }
    }

    if ($malformed -gt 0 -and -not $warning) {
        $warning = "$malformed client row(s) had an invalid DOB and were skipped."
    }

    return [pscustomobject]@{
        Source = $source
        SourceKind = $sourceKind
        AgeDays = $ageDays
        Stale = $stale
        HardFail = $hardFail
        Clients = $clients
        Warning = $warning
        MalformedRows = $malformed
    }
}

function Find-Client {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ClientList,  # output of Get-ClientList
        [Parameter(Mandatory)] [string] $Query
    )
    if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
    $q = $Query.Trim().ToLowerInvariant()
    return $ClientList.Clients | Where-Object {
        $_.Name.ToLowerInvariant().Contains($q) -or
        ($_.FileRef -and $_.FileRef.ToLowerInvariant().Contains($q))
    } | Select-Object -First 50
}
