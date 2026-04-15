#Requires -Version 5.1
<#
.SYNOPSIS
    Open a new Outlook mail with the protected file attached.
.DESCRIPTION
    Supports three modes: new-compose, reply-to-current-selection, and
    forward-current-selection. Times out at configurable N seconds (default 5)
    when Outlook COM does not respond; on timeout or any failure it falls
    back to copying the file to the user's desktop and toasting the path.

    Supported on Outlook Classic (Desktop). For "New Outlook" (Monarch) the
    COM interface is reduced; we detect it and go straight to fallback.

    Recipient hint text (DOB format reminder) is prepended to the body as
    a standard Curo boilerplate paragraph.
#>

function Test-NewOutlook {
    # "New Outlook" (olk.exe) doesn't register a classic Outlook.Application
    # COM server the way the desktop client does. Heuristic: check if the
    # classic olmapi32.dll path exists under Office16.
    $classic = @(
        "${env:ProgramFiles}\Microsoft Office\root\Office16\OUTLOOK.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE"
    )
    foreach ($p in $classic) { if (Test-Path $p) { return $false } }
    return $true
}

function Send-ProtectedToOutlook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $AttachmentPath,
        [ValidateSet('New','Reply','Forward')] [string] $Mode = 'New',
        [string] $Body = ''
    )

    if (Test-NewOutlook) {
        return Invoke-DesktopDropFallback -AttachmentPath $AttachmentPath `
            -Reason "Only the New Outlook client is detected; classic COM required for in-tool attach."
    }

    $hint = if ($Config.show_recipient_hint) { $Config.recipient_hint_text } else { '' }
    $fullBody = if ($hint) { "$hint`r`n`r`n$Body" } else { $Body }

    $timeoutMs = [int]$Config.outlook_com_timeout_seconds * 1000
    $job = Start-Job -ScriptBlock {
        param($Attach, $BodyText, $Mode)
        try {
            $outlook = New-Object -ComObject Outlook.Application
            $mailItem = $null
            switch ($Mode) {
                'Reply'   {
                    $exp = $outlook.ActiveExplorer()
                    if (-not $exp -or $exp.Selection.Count -eq 0) { throw "No message selected for Reply." }
                    $mailItem = $exp.Selection.Item(1).Reply()
                }
                'Forward' {
                    $exp = $outlook.ActiveExplorer()
                    if (-not $exp -or $exp.Selection.Count -eq 0) { throw "No message selected for Forward." }
                    $mailItem = $exp.Selection.Item(1).Forward()
                }
                default   { $mailItem = $outlook.CreateItem(0) }   # olMailItem
            }
            $mailItem.Attachments.Add($Attach) | Out-Null
            if ($BodyText) {
                if ($mailItem.Body) {
                    $mailItem.Body = "$BodyText`r`n`r`n$($mailItem.Body)"
                } else {
                    $mailItem.Body = $BodyText
                }
            }
            $mailItem.Display($false) | Out-Null
            return @{ ok = $true; mode = $Mode }
        } catch {
            return @{ ok = $false; err = $_.Exception.Message }
        }
    } -ArgumentList $AttachmentPath, $fullBody, $Mode

    if (-not (Wait-Job $job -Timeout ([int]$Config.outlook_com_timeout_seconds))) {
        Stop-Job $job | Out-Null
        Remove-Job $job -Force | Out-Null
        if ($Config.outlook_fallback_desktop_drop) {
            return Invoke-DesktopDropFallback -AttachmentPath $AttachmentPath `
                -Reason "Outlook COM did not respond within $([int]$Config.outlook_com_timeout_seconds)s."
        }
        return [pscustomobject]@{ Success=$false; Mode='Timeout'; Error='Outlook COM timeout' }
    }

    $res = Receive-Job $job
    Remove-Job $job -Force | Out-Null

    if ($res.ok) {
        return [pscustomobject]@{ Success=$true; Mode=$res.mode; Error=$null }
    }

    if ($Config.outlook_fallback_desktop_drop) {
        return Invoke-DesktopDropFallback -AttachmentPath $AttachmentPath -Reason $res.err
    }
    return [pscustomobject]@{ Success=$false; Mode=$Mode; Error=$res.err }
}

function Invoke-DesktopDropFallback {
    param([string]$AttachmentPath, [string]$Reason)
    $desktop = [Environment]::GetFolderPath('Desktop')
    $target  = Join-Path $desktop (Split-Path $AttachmentPath -Leaf)
    try {
        Copy-Item -LiteralPath $AttachmentPath -Destination $target -Force
        $msg = "Outlook was not available ($Reason).`n`nA copy of the protected file was placed on your desktop:`n$target`n`nPlease attach it to your email manually."
        [System.Windows.Forms.MessageBox]::Show($msg, 'Outlook unavailable') | Out-Null
        return [pscustomobject]@{ Success=$true; Mode='DesktopDrop'; Error=$Reason }
    } catch {
        return [pscustomobject]@{ Success=$false; Mode='DesktopDropFailed'; Error=$_.Exception.Message }
    }
}
