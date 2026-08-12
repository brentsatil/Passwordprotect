#Requires -Version 5.1
<#
.SYNOPSIS
    Batch protect window: one window for every dropped PDF, with a client per
    row, a preview of the file each row will create, and per-row status as the
    run proceeds.
.DESCRIPTION
    Replaces the old drag-drop flow of N sequential modal prompts. Ported from
    the app\ prototype's batch grid when it was folded into this tool, but
    driving the SAME audited core (Invoke-ProtectFileCore), so escrow, the
    audit log, PDF-only and fail-closed all still apply per file.

    Two mechanics here are load-bearing and easy to "tidy" into breakage:

    1. Rows are replaced, never mutated. A [pscustomobject] raises no
       property-change notification, so `$row.StatusText = 'OK'` updates
       nothing on screen and reports no error. Assigning $script:Rows[$i]
       raises the collection-change event WPF does act on.

    2. Each file runs as TWO chained dispatcher items at Background priority.
       Render (7) and Input (5) outrank Background (4), so between the "mark
       this row Working" item and the "run the core" item the row actually
       repaints - and a Cancel click gets delivered. Doing both in one item
       would leave "Working..." invisible until the file finished.

    Everything runs on the UI thread on purpose. Invoke-ProtectFileCore takes
    a machine-wide named mutex for its audit append and disposes
    SecureStrings; keeping it on one thread makes that trivially correct and
    avoids re-importing modules into a worker runspace.

.OUTPUTS
    [hashtable] @{
      Cancelled = [bool]  closed before any file was protected
      Ran       = [bool]  the run was started
      Rows      = [object[]] final row snapshots
      Summary   = Get-BatchSummary output (or $null if never run)
    }
#>

param(
    [Parameter(Mandatory)] $Config,
    [Parameter(Mandatory)] $ClientList,   # from Find-Client.ps1::Get-ClientList
    [Parameter(Mandatory)] [string[]] $Paths
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Import-Module (Join-Path $PSScriptRoot 'BatchQueue.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Protect.psm1')    -Force -DisableNameChecking
# Dot-sourced ONCE here, not per keystroke inside the search handler.
. (Join-Path $PSScriptRoot 'Find-Client.ps1')

# Single-quoted here-string: the XAML contains {Binding ...} and must not be
# touched by PowerShell expansion.
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Protect PDFs with password"
        Width="820" Height="600" MinWidth="700" MinHeight="500"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- header -->
      <RowDefinition Height="Auto"/>   <!-- warning bar -->
      <RowDefinition Height="*"/>      <!-- file list -->
      <RowDefinition Height="Auto"/>   <!-- assign client -->
      <RowDefinition Height="Auto"/>   <!-- options -->
      <RowDefinition Height="Auto"/>   <!-- progress -->
      <RowDefinition Height="Auto"/>   <!-- buttons -->
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Name="HeaderText" FontWeight="Bold" Margin="0,0,0,8"
               TextWrapping="Wrap"/>

    <Border Grid.Row="1" Name="WarnBar" Background="#FFF4CE"
            BorderBrush="#E0B100" BorderThickness="1" Padding="8" Margin="0,0,0,8"
            Visibility="Collapsed">
      <TextBlock Name="WarnText" TextWrapping="Wrap"/>
    </Border>

    <ListView Grid.Row="2" Name="RowList" Margin="0,0,0,8">
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Status"      Width="95"  DisplayMemberBinding="{Binding StatusText}"/>
          <GridViewColumn Header="File"        Width="230" DisplayMemberBinding="{Binding FileName}"/>
          <GridViewColumn Header="Client"      Width="220" DisplayMemberBinding="{Binding ClientDisplay}"/>
          <GridViewColumn Header="Will create" Width="220" DisplayMemberBinding="{Binding PreviewName}"/>
        </GridView>
      </ListView.View>
    </ListView>

    <GroupBox Grid.Row="3" Name="AssignPanel" Header="Client for the selected file" Margin="0,0,0,8">
      <StackPanel Margin="4">
        <TextBlock Name="AssignHint" Foreground="#555" TextWrapping="Wrap" Margin="0,0,0,4"/>
        <TextBox Name="SearchBox" Height="24"/>
        <ListBox Name="ResultsList" Height="90" Margin="0,4,0,0"/>
      </StackPanel>
    </GroupBox>

    <StackPanel Grid.Row="4" Name="OptionsPanel" Margin="0,0,0,8">
      <CheckBox Name="OverwriteBox" Content="Overwrite existing protected files if present"/>
      <CheckBox Name="DeleteBox"    Content="Delete originals after protecting (NOT recommended)"/>
    </StackPanel>

    <TextBlock Grid.Row="5" Name="ProgressText" Foreground="#555" TextWrapping="Wrap" Margin="0,0,0,8"/>

    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button Name="CancelBtn"  Content="Cancel"      Width="90"  Margin="0,0,8,0"/>
      <Button Name="ProtectBtn" Content="Protect all" Width="130" IsEnabled="False" IsDefault="True"/>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$HeaderText   = $window.FindName('HeaderText')
$WarnBar      = $window.FindName('WarnBar')
$WarnText     = $window.FindName('WarnText')
$RowList      = $window.FindName('RowList')
$AssignPanel  = $window.FindName('AssignPanel')
$AssignHint   = $window.FindName('AssignHint')
$SearchBox    = $window.FindName('SearchBox')
$ResultsList  = $window.FindName('ResultsList')
$OptionsPanel = $window.FindName('OptionsPanel')
$OverwriteBox = $window.FindName('OverwriteBox')
$DeleteBox    = $window.FindName('DeleteBox')
$ProgressText = $window.FindName('ProgressText')
$CancelBtn    = $window.FindName('CancelBtn')
$ProtectBtn   = $window.FindName('ProtectBtn')

# --- state (script scope: event handlers cannot see function locals) --------
$script:Rows            = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:CurrentIndex    = 0
$script:IsRunning       = $false
$script:CancelRequested = $false
$script:AbortReason     = $null
$script:RunOptions      = @{}
$script:SuppressSel     = $false
$script:Result          = @{ Cancelled = $true; Ran = $false; Rows = @(); Summary = $null }

foreach ($r in (New-BatchRowList -Paths $Paths -Config $Config -ClientList $ClientList)) {
    $script:Rows.Add($r)
}
$RowList.ItemsSource = $script:Rows
$script:Result.Rows = @($script:Rows)

if ($ClientList.Warning) {
    $WarnBar.Visibility = 'Visible'
    $WarnText.Text = $ClientList.Warning
}

function Update-Gate {
    $ready = Test-BatchReady -Rows @($script:Rows)
    $ProtectBtn.IsEnabled = $ready -and -not $script:IsRunning
    $need = @($script:Rows | Where-Object { $_.Status -eq 'NeedsClient' }).Count
    $total = $script:Rows.Count
    $HeaderText.Text = if ($need -gt 0) {
        "$total file(s) to protect. $need still need a client - select a row and search below."
    } else {
        "$total file(s) ready. Each password is that client's date of birth."
    }
}

function Update-AssignPanel {
    $i = $RowList.SelectedIndex
    $ResultsList.Items.Clear()
    $SearchBox.Text = ''
    if ($i -lt 0) {
        $AssignHint.Text = 'Select a file above to set or change its client.'
        return
    }
    $row = $script:Rows[$i]
    $AssignHint.Text = if ($row.Client -and $row.AutoMatched) {
        "Matched from the file name: $($row.ClientDisplay). Search below to change it."
    } elseif ($row.Client) {
        "Client: $($row.ClientDisplay). Search below to change it."
    } elseif ($row.CandidateCount -gt 1) {
        "$($row.CandidateCount) clients match this file name - pick the right one below."
    } elseif ($row.CandidateCount -eq 1) {
        # A single WEAK match. Deliberately not pre-filled: the match may be a
        # coincidence ('quarterly summary.pdf' loosely matches a Mary), and
        # protecting with the wrong client's DOB is worse than one extra click.
        'One possible client below - check it is right for this file, then click it. Or search for another.'
    } else {
        'No client matched this file name - search by name or file reference below.'
    }

    # Offer the row's own candidates without the user retyping. Populating the
    # list selects nothing, so the assignment handler stays a deliberate click.
    if (-not $row.Client) {
        foreach ($m in @(Find-ClientForFileName -ClientList $ClientList -FilePath $row.Path)) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Content = $m.Display
            $item.Tag     = $m
            $ResultsList.Items.Add($item) | Out-Null
        }
    }
}

# --- the run: two chained dispatcher items per file -------------------------

$script:FinishRun = {
    # Rows never started keep durable meaning: anything already protected has
    # its escrow sidecar and audit row written and is NOT rolled back. Undoing
    # completed files would orphan their escrow records.
    for ($j = 0; $j -lt $script:Rows.Count; $j++) {
        if ($script:Rows[$j].Status -eq 'Ready') {
            $why = if ($script:AbortReason) { "Stopped: $($script:AbortReason)" } else { 'Cancelled before this file started' }
            $script:Rows[$j] = Set-BatchRowStatus -Row $script:Rows[$j] -Status 'NotRun' -Message $why
        }
    }
    $script:IsRunning = $false
    $window.Cursor = $null
    $summary = Get-BatchSummary -Rows @($script:Rows)
    $script:Result.Ran       = $true
    $script:Result.Cancelled = $false
    $script:Result.Rows      = @($script:Rows)
    $script:Result.Summary   = $summary

    $line = "Protected $($summary.Ok) of $($summary.Total) file(s)."
    if ($summary.Failed -gt 0) { $line += "  Failed: $($summary.Failed)." }
    if ($summary.NotRun -gt 0) { $line += "  Not run: $($summary.NotRun)." }
    if ($script:AbortReason)   { $line += "  Run stopped: $($script:AbortReason)." }
    $ProgressText.Text = $line
    # The window IS the summary - the Status column carries the per-file
    # detail, so no extra modal is shown here.
    $CancelBtn.Content   = 'Close'
    $CancelBtn.IsEnabled = $true
}

$script:WorkStep = {
    $i   = $script:CurrentIndex
    $row = $script:Rows[$i]
    $pr  = $null
    try {
        $pr  = New-BatchPromptResult -Row $row -Options $script:RunOptions
        $res = Invoke-ProtectFileCore -Config $Config -Path $row.Path -PromptResult $pr
        $st  = if ($res.Success) { 'OK' } else { 'Failed' }
        $script:Rows[$i] = Set-BatchRowStatus -Row $row -Status $st `
            -Message ([string]$res.Message) -OutputPath ([string]$res.OutputPath)
        if (-not $res.Success -and $res.ErrorCode -eq 'ESCROW_OFFLINE') {
            # Same call as the folder batch: escrow being unreachable will fail
            # every remaining file, so stop rather than grind through them.
            $script:CancelRequested = $true
            $script:AbortReason = 'the escrow location is unreachable'
        }
    } catch {
        # The core can throw - an audit-append failure escapes Write-AuditEvent.
        $script:Rows[$i] = Set-BatchRowStatus -Row $row -Status 'Failed' -Message $_.Exception.Message
    } finally {
        if ($pr -and $pr.SecurePassword) { $pr.SecurePassword.Dispose() }
        [GC]::Collect()
    }
    $script:CurrentIndex = $i + 1
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]$script:MarkStep)
}

$script:MarkStep = {
    $i = $script:CurrentIndex
    if ($script:CancelRequested -or $i -ge $script:Rows.Count) { & $script:FinishRun; return }
    $script:Rows[$i] = Set-BatchRowStatus -Row $script:Rows[$i] -Status 'Working'
    $ProgressText.Text = "Protecting file $($i + 1) of $($script:Rows.Count) - the window may pause for a few seconds per file."
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]$script:WorkStep)
}

# --- wiring -----------------------------------------------------------------

$RowList.Add_SelectionChanged({
    if ($script:SuppressSel -or $script:IsRunning) { return }
    Update-AssignPanel
})

$SearchBox.Add_TextChanged({
    if ($script:IsRunning) { return }
    $ResultsList.Items.Clear()
    if ([string]::IsNullOrWhiteSpace($SearchBox.Text)) { return }
    foreach ($m in @(Find-Client -ClientList $ClientList -Query $SearchBox.Text)) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $m.Display
        $item.Tag     = $m
        $ResultsList.Items.Add($item) | Out-Null
    }
})

$ResultsList.Add_SelectionChanged({
    if ($script:IsRunning) { return }
    $sel = $ResultsList.SelectedItem
    if (-not $sel) { return }                      # Items.Clear() fires this too
    $i = $RowList.SelectedIndex
    if ($i -lt 0) { return }
    $script:Rows[$i] = Set-BatchRowClient -Row $script:Rows[$i] -Client $sel.Tag -Config $Config
    # Replacing the selected item clears the selection, and restoring it
    # re-fires SelectionChanged - hence the guard.
    $script:SuppressSel = $true
    try { $RowList.SelectedIndex = $i } finally { $script:SuppressSel = $false }
    $AssignHint.Text = "Client: $($script:Rows[$i].ClientDisplay). Search again to change it."
    Update-Gate
})

$ProtectBtn.Add_Click({
    if ($script:IsRunning) { return }
    if (-not (Test-BatchReady -Rows @($script:Rows))) { return }
    $script:RunOptions = @{
        AllowOverwrite = [bool]$OverwriteBox.IsChecked
        DeleteOriginal = [bool]$DeleteBox.IsChecked
    }
    $script:IsRunning    = $true
    $script:CurrentIndex = 0
    # Lock down everything except Cancel. IsHitTestVisible rather than
    # IsEnabled on the list so the status text stays readable, not greyed.
    $AssignPanel.IsEnabled     = $false
    $OptionsPanel.IsEnabled    = $false
    $ProtectBtn.IsEnabled      = $false
    $RowList.IsHitTestVisible  = $false
    $window.Cursor             = [System.Windows.Input.Cursors]::Wait
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]$script:MarkStep)
})

$CancelBtn.Add_Click({
    if ($script:IsRunning) {
        $script:CancelRequested = $true
        $CancelBtn.IsEnabled = $false
        $ProgressText.Text = 'Finishing the current file, then stopping...'
        return
    }
    $window.Close()
})

$window.Add_Closing({
    param($s, $e)
    # Closing mid-run means cancel: the current file must finish so its escrow
    # record is written. The window closes once the run stops.
    if ($script:IsRunning) {
        $script:CancelRequested = $true
        $e.Cancel = $true
    }
})

Update-Gate
Update-AssignPanel

# CI seam: with UI suppressed, everything above has still executed for real -
# XAML load, all FindName lookups, row construction, event wiring - which is
# what tests\Xaml.Tests.ps1 asserts. Only the modal pump is skipped.
if ($env:CURO_SUPPRESS_UI -eq '1') { return $script:Result }

$window.ShowDialog() | Out-Null

return $script:Result
