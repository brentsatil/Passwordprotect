#Requires -Version 5.1
<#
.SYNOPSIS
    Recover a forgotten password from the escrow log.
.DESCRIPTION
    Admin-only. Requires the escrow private key (normally on the safe USB).

    Accepts any of:
      -OutputPath  : path to the protected file — computes sha256 and looks up
      -SourceName  : original filename as recorded in the sidecar
      -ClientRef   : client file_ref — returns all matching entries
      -Sha256      : direct hash lookup

    Writes the recovered password to the clipboard (never to the console,
    never to a file) and emits an audit record on the LOCAL machine. The
    operator must clear their clipboard when done.

.EXAMPLE
    .\Recover-File.ps1 -PrivateKeyPath E:\curo-escrow.key -OutputPath 'C:\Quotes\SoA_Smith_protected.pdf'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PrivateKeyPath,
    [string] $EscrowDir,
    [string] $OutputPath,
    [string] $SourceName,
    [string] $ClientRef,
    [string] $Sha256
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path (Split-Path $here -Parent) 'src\Config.psm1') -Force
Import-Module (Join-Path (Split-Path $here -Parent) 'src\Logging.psm1') -Force
$config = Get-CuroConfig
if (-not $EscrowDir) { $EscrowDir = $config.escrow_dir }

if (-not (Test-Path -LiteralPath $PrivateKeyPath)) {
    throw "Private key not found at '$PrivateKeyPath'. Insert the escrow USB."
}

function Get-FileSha256 { param($p)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $fs=[IO.File]::OpenRead($p); try { ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-','').ToLowerInvariant() } finally { $fs.Dispose() } }
    finally { $sha.Dispose() }
}

$candidates = @()
if ($Sha256) { $candidates = Get-ChildItem -Path $EscrowDir -Filter "$Sha256.escrow.json" -Recurse -ErrorAction SilentlyContinue }
elseif ($OutputPath) {
    $h = Get-FileSha256 $OutputPath
    $candidates = Get-ChildItem -Path $EscrowDir -Filter "$h.escrow.json" -Recurse -ErrorAction SilentlyContinue
}
else {
    $all = Get-ChildItem -Path $EscrowDir -Filter '*.escrow.json' -Recurse -ErrorAction SilentlyContinue
    foreach ($f in $all) {
        $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
        $hit = $true
        if ($SourceName -and $j.source_filename -ne $SourceName) { $hit = $false }
        if ($ClientRef  -and $j.client_file_ref -ne $ClientRef)  { $hit = $false }
        if ($hit) { $candidates += $f }
    }
}

if (-not $candidates) { throw "No matching escrow sidecar found." }

if ($candidates.Count -gt 1) {
    Write-Host ""
    Write-Host "Multiple escrow entries match. Pick one:"
    $i = 0
    foreach ($c in $candidates) {
        $j = Get-Content $c.FullName -Raw | ConvertFrom-Json
        Write-Host "  [$i] $($j.created_utc)  $($j.source_filename)  ref=$($j.client_file_ref)"
        $i++
    }
    $choice = [int](Read-Host 'Index')
    $candidates = @($candidates[$choice])
}

$entry = Get-Content $candidates[0].FullName -Raw | ConvertFrom-Json

$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportFromPem((Get-Content -LiteralPath $PrivateKeyPath -Raw))
try {
    $wrapped = [Convert]::FromBase64String($entry.wrapped_password_b64)
    $plainBytes = $rsa.Decrypt($wrapped, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    $password = [System.Text.Encoding]::UTF8.GetString($plainBytes)
} finally {
    $rsa.Dispose()
}

# Write to clipboard — requires a STA host. Avoid writing to console.
Set-Clipboard -Value $password
[Array]::Clear($plainBytes, 0, $plainBytes.Length)
Remove-Variable password

Write-AuditEvent -Config $config -Fields @{
    op='recover'; outcome='ok';
    recovered_sha256=$entry.output_sha256;
    recovered_source=$entry.source_filename;
    recovered_client_ref=$entry.client_file_ref;
    operator=$env:USERNAME;
}

Write-Host "`nPassword copied to clipboard." -ForegroundColor Green
Write-Host "Source file : $($entry.source_filename)"
Write-Host "Protected   : $($entry.output_filename)"
Write-Host "Client ref  : $($entry.client_file_ref)"
Write-Host "Wrapped by  : pubkey $($entry.pubkey_fingerprint_sha256.Substring(0,16))..."
Write-Host "`nClear your clipboard when you're finished." -ForegroundColor Yellow
