#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -LiteralPath $root -Recurse -Include *.ps1,*.psm1 | Where-Object { $_.FullName -notmatch '\\.git' }
$errors = @()
foreach ($f in $files) {
    $tokens=$null; $parseErrors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { $errors += $parseErrors | ForEach-Object { "$($f.FullName): $($_.Message)" } }
}
if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Host "Parsed $($files.Count) PowerShell files successfully."
