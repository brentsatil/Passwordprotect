#Requires -Version 5.1
<#!
.SYNOPSIS
    Rotate the escrow recovery certificate.
.DESCRIPTION
    Creates a self-signed RSA certificate compatible with Windows PowerShell
    5.1. The public .cer is deployed for wrapping; the password-protected .pfx
    private key is retained offline for recovery.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $NewPrivateKeyPath,
    [Parameter(Mandatory)] [securestring] $PfxPassword,
    [string] $Subject = 'CN=Curo PDF Protector Escrow',
    [int] $Years = 10
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path (Split-Path $here -Parent) 'src\Config.psm1') -Force
$config = Get-CuroConfig

$cert = New-SelfSignedCertificate -Subject $Subject -KeyAlgorithm RSA -KeyLength 4096 -KeyExportPolicy Exportable -KeyUsage KeyEncipherment,DataEncipherment -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears($Years)
try {
    $pubPath = if ($config.escrow_cert_path) { $config.escrow_cert_path } else { $config.escrow_pubkey_path }
    $pubDir = Split-Path $pubPath -Parent
    if (-not (Test-Path $pubDir)) { New-Item -ItemType Directory -Path $pubDir -Force | Out-Null }
    if (Test-Path -LiteralPath $pubPath) { Copy-Item -LiteralPath $pubPath -Destination ("$pubPath.$((Get-Date).ToString('yyyyMMdd-HHmmss')).old") -Force }
    Export-Certificate -Cert $cert -FilePath $pubPath -Force | Out-Null

    if (Test-Path -LiteralPath $NewPrivateKeyPath) { throw "Private key destination '$NewPrivateKeyPath' already exists. Aborting." }
    Export-PfxCertificate -Cert $cert -FilePath $NewPrivateKeyPath -Password $PfxPassword | Out-Null

    Write-Host "New escrow certificate fingerprint: $($cert.Thumbprint.ToLowerInvariant())"
    Write-Host "Public certificate written to: $pubPath"
    Write-Host "Private recovery PFX written to: $NewPrivateKeyPath"
    Write-Host 'Retain previous recovery PFX files indefinitely.' -ForegroundColor Yellow
} finally {
    Remove-Item -LiteralPath ("Cert:\CurrentUser\My\$($cert.Thumbprint)") -Force -ErrorAction SilentlyContinue
}
