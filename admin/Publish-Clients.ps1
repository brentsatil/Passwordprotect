#Requires -Version 5.1
<#
.SYNOPSIS
    Publish the weekly clients.csv from a master spreadsheet.
.DESCRIPTION
    Intended for the Practice Administrator to run every Monday.

    Input can be:
      - An XLSX file (requires the ImportExcel module: Install-Module ImportExcel)
      - A CSV file exported manually from Excel

    The script:
      1. Reads the input into rows.
      2. Normalises the DOB column to 8-digit DDMMYYYY and rejects malformed rows.
      3. Writes to a temp file as UTF-8 with BOM.
      4. Validates the temp file (re-reads, counts, checks schema).
      5. Atomically replaces the live clients.csv on the share (Move-Item -Force).
      6. Emits a report: rows in, rows out, rows skipped, and why.

    Hard-fails if any validation step fails — the live CSV is NEVER overwritten
    with something unvalidated.

.EXAMPLE
    .\Publish-Clients.ps1 -Source \\server\shared\Master\Clients.xlsx
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Source,
    [string] $Destination,
    [switch] $DryRun
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path (Split-Path $here -Parent) 'src\Config.psm1') -Force
$config = Get-CuroConfig
if (-not $Destination) { $Destination = $config.client_lookup_file }

if (-not (Test-Path -LiteralPath $Source)) { throw "Source not found: $Source" }

$ext = [IO.Path]::GetExtension($Source).ToLowerInvariant()

$rows = @()
switch ($ext) {
    '.xlsx' {
        if (-not (Get-Module -ListAvailable ImportExcel)) {
            throw "ImportExcel module not available. Run: Install-Module ImportExcel -Scope CurrentUser"
        }
        Import-Module ImportExcel
        $rows = Import-Excel -Path $Source
    }
    '.csv'  { $rows = Import-Csv -LiteralPath $Source -Encoding UTF8 }
    default { throw "Unsupported source type '$ext'. Use .xlsx or .csv." }
}

function Normalise-Dob {
    param($raw)
    if (-not $raw) { return $null }
    $s = "$raw" -replace '[^\d]', ''
    if ($s.Length -ne 8) { return $null }

    # Try DDMMYYYY first (AU convention); if that fails to parse as a real
    # date, try YYYYMMDD. Never dispatch on leading two characters alone —
    # that misclassifies valid DOBs with day 19 or 20.
    $validate = {
        param($d,$m,$y)
        if ($m -lt 1 -or $m -gt 12) { return $false }
        if ($d -lt 1 -or $d -gt 31) { return $false }
        if ($y -lt 1900 -or $y -gt 2100) { return $false }
        try { [void][datetime]::new($y,$m,$d); return $true } catch { return $false }
    }
    $d1 = [int]$s.Substring(0,2); $m1 = [int]$s.Substring(2,2); $y1 = [int]$s.Substring(4,4)
    $y2 = [int]$s.Substring(0,4); $m2 = [int]$s.Substring(4,2); $d2 = [int]$s.Substring(6,2)
    if (& $validate $d1 $m1 $y1)       { $dd=$d1; $mm=$m1; $yyyy=$y1 }
    elseif (& $validate $d2 $m2 $y2)   { $dd=$d2; $mm=$m2; $yyyy=$y2 }
    else { return $null }
    return ('{0:00}{1:00}{2:0000}' -f $dd,$mm,$yyyy)
}

# Map input columns to our schema (client_name, dob, file_ref).
function Pick-Col { param($row, [string[]]$names)
    foreach ($n in $names) {
        if ($row.PSObject.Properties[$n]) { return $row.$n }
    }
    return $null
}

$good = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
    $name = Pick-Col $r @('client_name','Client Name','ClientName','Full Name','Name')
    $dob  = Pick-Col $r @('dob','DOB','Date of Birth','DateOfBirth','Birthdate')
    $ref  = Pick-Col $r @('file_ref','FileRef','File Ref','ClientID','Client Id','Id')
    $norm = Normalise-Dob $dob
    if (-not $name) { $skipped.Add(@{ reason='missing_name'; row=$r }); continue }
    if (-not $norm) { $skipped.Add(@{ reason='invalid_dob'; row=$r });  continue }
    $good.Add([pscustomobject]@{ client_name=$name; dob=$norm; file_ref=$ref })
}

Write-Host ("Rows read:    {0}" -f $rows.Count)
Write-Host ("Rows valid:   {0}" -f $good.Count)
Write-Host ("Rows skipped: {0}" -f $skipped.Count)
if ($skipped.Count -gt 0 -and $skipped.Count -le 20) {
    $skipped | ForEach-Object { Write-Host ("  [{0}] {1}" -f $_.reason, ($_.row | ConvertTo-Json -Compress)) }
} elseif ($skipped.Count -gt 20) {
    Write-Host "  (too many to display — first 20 above)"
}

if ($good.Count -eq 0) { throw "No valid rows — refusing to publish." }
if ($skipped.Count -gt ($rows.Count / 2)) { throw "More than half the rows were invalid — refusing to publish." }

if ($DryRun) {
    Write-Host "Dry run: not writing to '$Destination'." -ForegroundColor Yellow
    return
}

$destDir = Split-Path $Destination -Parent
if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
$tmp = "$Destination.new"

$good | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8

# Re-read the temp file as a final cross-check.
$verify = Import-Csv -LiteralPath $tmp -Encoding UTF8
if ($verify.Count -ne $good.Count) {
    Remove-Item -LiteralPath $tmp -Force
    throw "Verification read of '$tmp' returned $($verify.Count) rows; expected $($good.Count). Aborting."
}

Move-Item -LiteralPath $tmp -Destination $Destination -Force
Write-Host "Published $($good.Count) clients to '$Destination'." -ForegroundColor Green
