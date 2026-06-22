#Requires -Version 5.1
<#
.SYNOPSIS
    Minimal WPF date-of-birth prompt for the standalone PasswordProtect tool.
.DESCRIPTION
    Three numeric fields (Day / Month / Year) map exactly to a DDMMYYYY
    password with no locale ambiguity. A live read-back label shows the
    resulting password so the user can eyeball it before committing. The
    password is built straight into a SecureString — no long-lived plain copy.
.OUTPUTS
    @{ SecurePassword = <SecureString or $null>; Cancelled = [bool] }
    The caller disposes the SecureString.
#>

param(
    [int] $FileCount = 1
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$fileWord = if ($FileCount -eq 1) { 'file' } else { 'files' }

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Password = date of birth"
        Width="380" Height="280" WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" SizeToContent="Manual">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Name="HeaderText" TextWrapping="Wrap" FontWeight="Bold" Margin="0,0,0,4"/>
    <TextBlock Grid.Row="1" Text="Enter the date of birth to use as the password." TextWrapping="Wrap"
               Foreground="#555" Margin="0,0,0,12"/>

    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,8">
      <StackPanel Margin="0,0,12,0">
        <TextBlock Text="Day" Margin="0,0,0,2"/>
        <TextBox Name="DayBox" Width="50" Height="26" MaxLength="2"/>
      </StackPanel>
      <StackPanel Margin="0,0,12,0">
        <TextBlock Text="Month" Margin="0,0,0,2"/>
        <TextBox Name="MonthBox" Width="50" Height="26" MaxLength="2"/>
      </StackPanel>
      <StackPanel>
        <TextBlock Text="Year" Margin="0,0,0,2"/>
        <TextBox Name="YearBox" Width="70" Height="26" MaxLength="4"/>
      </StackPanel>
    </StackPanel>

    <TextBlock Grid.Row="3" Name="ReadBack" Foreground="#1A6E1A" Margin="0,0,0,4"
               Text="Password will be: --------"/>

    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button Name="CancelBtn" Content="Cancel" Width="90" Margin="0,0,8,0"/>
      <Button Name="OkBtn"     Content="Protect" Width="110" IsDefault="True"/>
    </StackPanel>
  </Grid>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$HeaderText = $window.FindName('HeaderText')
$DayBox     = $window.FindName('DayBox')
$MonthBox   = $window.FindName('MonthBox')
$YearBox    = $window.FindName('YearBox')
$ReadBack   = $window.FindName('ReadBack')
$OkBtn      = $window.FindName('OkBtn')
$CancelBtn  = $window.FindName('CancelBtn')

$HeaderText.Text = "Protecting $FileCount $fileWord with this date of birth."

$script:result = @{ SecurePassword = $null; Cancelled = $true }

# Parse the three boxes into a validated DDMMYYYY string, or $null.
function Get-DobString {
    $d = 0; $m = 0; $y = 0
    if (-not [int]::TryParse($DayBox.Text.Trim(),   [ref]$d)) { return $null }
    if (-not [int]::TryParse($MonthBox.Text.Trim(), [ref]$m)) { return $null }
    if (-not [int]::TryParse($YearBox.Text.Trim(),  [ref]$y)) { return $null }
    if ($d -lt 1 -or $d -gt 31)   { return $null }
    if ($m -lt 1 -or $m -gt 12)   { return $null }
    if ($y -lt 1900 -or $y -gt 9999 -or $YearBox.Text.Trim().Length -ne 4) { return $null }
    return ('{0:D2}{1:D2}{2:D4}' -f $d, $m, $y)
}

$brushReady   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x1A, 0x6E, 0x1A))
$brushPending = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x99, 0x99, 0x99))

$updateReadBack = {
    $s = Get-DobString
    if ($s) { $ReadBack.Text = "Password will be: $s"; $ReadBack.Foreground = $brushReady }
    else    { $ReadBack.Text = "Password will be: --------"; $ReadBack.Foreground = $brushPending }
}
$DayBox.Add_TextChanged($updateReadBack)
$MonthBox.Add_TextChanged($updateReadBack)
$YearBox.Add_TextChanged($updateReadBack)

$OkBtn.Add_Click({
    $s = Get-DobString
    if (-not $s) {
        [System.Windows.MessageBox]::Show(
            'Enter a valid date: day 1-31, month 1-12, and a 4-digit year (1900 or later).',
            'Check the date') | Out-Null
        return
    }
    # Build the SecureString without a long-lived managed string copy.
    $ss = New-Object System.Security.SecureString
    foreach ($ch in $s.ToCharArray()) { $ss.AppendChar($ch) }
    $ss.MakeReadOnly()
    $script:result.SecurePassword = $ss
    $script:result.Cancelled = $false
    $window.Close()
})

$CancelBtn.Add_Click({ $window.Close() })

$DayBox.Focus() | Out-Null
$window.ShowDialog() | Out-Null

return $script:result
