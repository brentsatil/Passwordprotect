# BatchQueue.psm1
# Pure row-state machine for the batch protect window (Prompt-Batch.ps1).
# NO WPF types in here - everything is unit-testable headlessly, which is the
# point: the window is a thin shell and the behaviour lives where Pester can
# reach it.
#
# Rows are IMMUTABLE snapshots: every change returns a NEW [pscustomobject].
# That is not style - it is how the window repaints. PSObjects raise no
# property-change events, so mutating a displayed row updates nothing on
# screen, silently. The shell replaces the row at its index instead, which
# raises the collection-change WPF does listen to.
#
# Every BOUND property (StatusText, FileName, ClientDisplay, PreviewName)
# must be set on EVERY row: a missing bound property is a silently blank
# cell, not an error. tests\Xaml.Tests.ps1 pins the binding paths against
# this row shape.
#
# The client's DOB never appears in StatusText, ClientDisplay, PreviewName,
# or Message - those reach the screen and the batch summary.

$script:here = $PSScriptRoot
. (Join-Path $script:here 'Find-Client.ps1')
Import-Module (Join-Path $script:here 'Naming.psm1') -Force -DisableNameChecking

$script:StatusTexts = @{
    NeedsClient = 'Needs client'
    Ready       = 'Ready'
    Working     = 'Working...'
    OK          = 'OK'
    Failed      = 'FAILED'
    NotRun      = 'Not run'
}

function New-BatchRowInternal {
    # Single construction point so every row carries every property.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Status,
        $Client,
        [bool] $AutoMatched = $false,
        [int] $CandidateCount = 0,
        [string] $PreviewName = '',
        [string] $Message = '',
        [string] $OutputPath = ''
    )
    return [pscustomobject]@{
        Path           = $Path
        FileName       = (Split-Path -Leaf $Path)
        Status         = $Status
        StatusText     = [string]$script:StatusTexts[$Status]
        Client         = $Client
        ClientDisplay  = if ($Client) { [string]$Client.Display } else { '' }
        AutoMatched    = $AutoMatched
        CandidateCount = $CandidateCount
        PreviewName    = $PreviewName
        Message        = $Message
        OutputPath     = $OutputPath
    }
}

function New-BatchRow {
    <#
    .SYNOPSIS
        Build one queue row for a PDF, auto-matching the client from the file
        name. Exactly one match -> assigned + Ready; zero or many -> NeedsClient.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $ClientList
    )
    # @() is load-bearing: one match comes back as a scalar in PS 5.1.
    $matched = @(Find-ClientForFileName -ClientList $ClientList -FilePath $Path)
    $client  = $null
    $status  = 'NeedsClient'
    $auto    = $false
    if ($matched.Count -eq 1) {
        $client = $matched[0]
        $status = 'Ready'
        $auto   = $true
    }
    $ref = if ($client) { [string]$client.FileRef } else { '' }
    $preview = [System.IO.Path]::GetFileName((Get-ProtectedOutputPath -Config $Config -InputPath $Path -ClientRef $ref))
    return (New-BatchRowInternal -Path $Path -Status $status -Client $client `
        -AutoMatched $auto -CandidateCount $matched.Count -PreviewName $preview)
}

function New-BatchRowList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Paths,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $ClientList
    )
    $rows = @()
    foreach ($p in $Paths) {
        $rows += New-BatchRow -Path $p -Config $Config -ClientList $ClientList
    }
    return ,$rows
}

function Set-BatchRowClient {
    <#
    .SYNOPSIS
        Assign (or reassign) the client on a pre-run row. Returns a NEW row;
        recomputes the preview name because {ClientRef} may appear in the
        naming template. Throws once the row has started or finished running.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] $Client,
        [Parameter(Mandatory)] $Config
    )
    if ($Row.Status -notin @('NeedsClient', 'Ready')) {
        throw "Cannot change the client of a row in state '$($Row.Status)'."
    }
    $preview = [System.IO.Path]::GetFileName((Get-ProtectedOutputPath -Config $Config -InputPath $Row.Path -ClientRef ([string]$Client.FileRef)))
    return (New-BatchRowInternal -Path $Row.Path -Status 'Ready' -Client $Client `
        -AutoMatched $false -CandidateCount $Row.CandidateCount -PreviewName $preview `
        -Message $Row.Message -OutputPath $Row.OutputPath)
}

function Set-BatchRowStatus {
    <#
    .SYNOPSIS
        Move a row through the run lifecycle. Legal transitions only:
          Ready -> Working ; Working -> OK | Failed ; Ready -> NotRun.
        Everything else throws - OK/Failed/NotRun are terminal, and a row
        cannot start work without a client (NeedsClient never reaches Working).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] [ValidateSet('NeedsClient','Ready','Working','OK','Failed','NotRun')] [string] $Status,
        [string] $Message,
        [string] $OutputPath
    )
    $legal = switch ($Row.Status) {
        'Ready'   { @('Working', 'NotRun') }
        'Working' { @('OK', 'Failed') }
        default   { @() }
    }
    if ($Status -notin $legal) {
        throw "Illegal batch row transition: '$($Row.Status)' -> '$Status' for '$($Row.FileName)'."
    }
    $msg = if ($PSBoundParameters.ContainsKey('Message'))    { $Message }    else { $Row.Message }
    $out = if ($PSBoundParameters.ContainsKey('OutputPath')) { $OutputPath } else { $Row.OutputPath }
    return (New-BatchRowInternal -Path $Row.Path -Status $Status -Client $Row.Client `
        -AutoMatched $Row.AutoMatched -CandidateCount $Row.CandidateCount `
        -PreviewName $Row.PreviewName -Message $msg -OutputPath $out)
}

function Test-BatchReady {
    <#
    .SYNOPSIS
        The "Protect all" gate: true only when there is at least one row and
        every row is Ready (has a client, has not run).
    #>
    [CmdletBinding()]
    param(
        # [object[]] so a single row coerces to a one-element array. An
        # untyped scalar row would make .Count $null in PS 5.1 and the gate
        # would pass vacuously - the exact trap this project has hit before.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows
    )
    $all = @($Rows)
    if ($all.Count -eq 0) { return $false }
    return (@($all | Where-Object { $_.Status -ne 'Ready' }).Count -eq 0)
}

function New-BatchPromptResult {
    <#
    .SYNOPSIS
        Build the PromptResult contract Invoke-ProtectFileCore reads, from an
        assigned row + the batch-wide options. The SecureString is built from
        the client's DOB and is the CALLER'S responsibility to dispose after
        the core call returns.
    .NOTES
        Key set deliberately identical to Prompt-Password.ps1's result -
        tests pin it so the two entry points cannot drift apart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] [hashtable] $Options
    )
    if (-not $Row.Client) { throw "Row '$($Row.FileName)' has no client assigned." }
    $ss = New-Object System.Security.SecureString
    foreach ($ch in ([string]$Row.Client.Dob).ToCharArray()) { $ss.AppendChar($ch) }
    $ss.MakeReadOnly()
    return @{
        SecurePassword = $ss
        PasswordSource = 'dob'
        ClientFileRef  = [string]$Row.Client.FileRef
        DeleteOriginal = [bool]$Options['DeleteOriginal']
        AllowOverwrite = [bool]$Options['AllowOverwrite']
        OpenOutlook    = $false   # deliberately never offered on the batch path
        Cancelled      = $false
    }
}

function Get-BatchSummary {
    <#
    .SYNOPSIS
        Counts + the exit code policy in one testable place. Exit code is 0
        for any run the user saw through (including failures - the window
        showed them per-row); non-zero exits stay reserved for crashes and
        health refusals, per Invoke-Main's documented contract.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows
    )
    $all = @($Rows)
    return [pscustomobject]@{
        Total    = $all.Count
        Ok       = @($all | Where-Object { $_.Status -eq 'OK' }).Count
        Failed   = @($all | Where-Object { $_.Status -eq 'Failed' }).Count
        NotRun   = @($all | Where-Object { $_.Status -eq 'NotRun' }).Count
        ExitCode = 0
    }
}

Export-ModuleMember -Function New-BatchRow, New-BatchRowList, Set-BatchRowClient, Set-BatchRowStatus, Test-BatchReady, New-BatchPromptResult, Get-BatchSummary
