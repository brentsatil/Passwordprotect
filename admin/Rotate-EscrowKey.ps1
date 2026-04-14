#Requires -Version 5.1
<#
.SYNOPSIS
    Rotate the escrow keypair.
.DESCRIPTION
    Generates a fresh 4096-bit RSA keypair, writes the new public key to the
    file server path referenced in settings.json, and writes the private key
    once to the specified destination (the safe USB).

    Important: the OLD private key must be retained indefinitely — any file
    protected under the OLD public key can ONLY be recovered with the OLD
    private key. Each escrow sidecar records the pubkey fingerprint so the
    correct private key can be identified at recovery time.

    Workflow at Curo:
      1. Insert a fresh USB drive. Mount its path, e.g. E:\.
      2. Run: Rotate-EscrowKey.ps1 -NewPrivateKeyPath E:\curo-escrow-YYYY-MM-DD.key
      3. Label and seal the old USB with today's date; retain in the safe.
      4. Place the new USB in the safe, make the off-site second copy.
      5. Verify with Recover-File.ps1 against a known-good fresh entry.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $NewPrivateKeyPath,
    [int] $Bits = 4096
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path (Split-Path $here -Parent) 'src\Config.psm1') -Force
$config = Get-CuroConfig

$rsa = [System.Security.Cryptography.RSA]::Create($Bits)
try {
    $pubPem  = $rsa.ExportSubjectPublicKeyInfoPem()
    $privPem = $rsa.ExportPkcs8PrivateKeyPem()

    # New pubkey goes to the share (replacing the old one). The old file on
    # the share is overwritten, but that's fine because EVERY escrow sidecar
    # already records the fingerprint of the key that wrapped it.
    $pubPath = [Environment]::ExpandEnvironmentVariables($config.escrow_pubkey_path)
    $pubDir = Split-Path $pubPath -Parent
    if (-not (Test-Path $pubDir)) { New-Item -ItemType Directory -Path $pubDir -Force | Out-Null }

    # Also back up the old pub file with a timestamp so we know which keys
    # existed when.
    if (Test-Path -LiteralPath $pubPath) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $pubPath -Destination "$pubPath.$stamp.old" -Force
    }

    Set-Content -LiteralPath $pubPath -Value $pubPem -Encoding UTF8

    # Private key: write ONCE to the destination (the USB) and then never
    # again. Refuse to overwrite an existing file.
    if (Test-Path -LiteralPath $NewPrivateKeyPath) {
        throw "Private key destination '$NewPrivateKeyPath' already exists. Aborting to avoid clobbering an existing key."
    }
    Set-Content -LiteralPath $NewPrivateKeyPath -Value $privPem -Encoding UTF8

    # Compute and print fingerprint so operator can verify against sidecars.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fp  = ([BitConverter]::ToString($sha.ComputeHash($rsa.ExportSubjectPublicKeyInfo()))).Replace('-','').ToLowerInvariant()
    $sha.Dispose()

    Write-Host "New escrow pubkey fingerprint: $fp"
    Write-Host "Public  key written to: $pubPath"
    Write-Host "Private key written to: $NewPrivateKeyPath"
    Write-Host ""
    Write-Host "Retain the PREVIOUS private key indefinitely — it is needed" -ForegroundColor Yellow
    Write-Host "to recover files protected before this rotation." -ForegroundColor Yellow
} finally {
    $rsa.Dispose()
}
