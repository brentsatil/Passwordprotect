#Requires -Version 5.1
<#
.SYNOPSIS
    WPF password prompt with client picker.
.DESCRIPTION
    Shows a WPF dialog that allows the user to:
      - Type-ahead search for a client in the CSV; selecting a client uses
        their DOB (in DDMMYYYY format) as the password.
      - OR enter a manual password (with confirm + complexity check).
    Returns a hashtable:
      @{
        SecurePassword = <SecureString>
        PasswordSource = 'dob' | 'manual'
        ClientFileRef  = <string or $null>
        DeleteOriginal = [bool]
        AllowOverwrite = [bool]
        OpenOutlook    = [bool]
        Cancelled      = [bool]
      }
    The SecureString is the caller's responsibility to dispose.
#>

param(
    [Parameter(Mandatory)] $Config,
    [Parameter(Mandatory)] $ClientList,   # from Find-Client.ps1::Get-ClientList
    [Parameter(Mandatory)] [string] $FilePath,
    [switch] $OfferOutlook
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Protect with password"
        Width="520" Height="520" WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" SizeToContent="Manual">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>  <!-- file info -->
      <RowDefinition Height="Auto"/>  <!-- warning bar -->
      <RowDefinition Height="Auto"/>  <!-- client search -->
      <RowDefinition Height="*"/>     <!-- match list -->
      <RowDefinition Height="Auto"/>  <!-- manual entry -->
      <RowDefinition Height="Auto"/>  <!-- options -->
      <RowDefinition Height="Auto"/>  <!-- buttons -->
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,8">
      <TextBlock FontWeight="Bold" Text="File:"/>
      <TextBlock Name="FilePathText" TextWrapping="Wrap" Foreground="#555"/>
    </StackPanel>

    <Border Grid.Row="1" Name="WarnBar" Background="#FFF4CE"
            BorderBrush="#E0B100" BorderThickness="1" Padding="8" Margin="0,0,0,8"
            Visibility="Collapsed">
      <TextBlock Name="WarnText" TextWrapping="Wrap"/>
    </Border>

    <StackPanel Grid.Row="2" Orientation="Vertical" Margin="0,0,0,4">
      <TextBlock Text="Search client (by name or file ref):" Margin="0,0,0,2"/>
      <TextBox Name="SearchBox" Height="24"/>
    </StackPanel>

    <ListBox Grid.Row="3" Name="ResultsList" Margin="0,4,0,8" MinHeight="100"/>

    <StackPanel Grid.Row="4" Margin="0,0,0,8">
      <TextBlock Text="Or enter a password manually:"/>
      <PasswordBox Name="ManualPwd"  Height="24" Margin="0,2"/>
      <PasswordBox Name="ManualPwd2" Height="24" Margin="0,2" ToolTip="Confirm"/>
      <TextBlock Name="ManualHint" Foreground="#888" FontSize="11"
                 Text="Minimum 10 chars with 3 character classes."/>
    </StackPanel>

    <StackPanel Grid.Row="5" Orientation="Vertical" Margin="0,4,0,8">
      <CheckBox Name="OverwriteBox" Content="Overwrite existing _protected file if present"/>
      <CheckBox Name="DeleteBox"    Content="Delete original after protecting (NOT recommended)"/>
      <CheckBox Name="OutlookBox"   Content="Open new Outlook email with this file attached"/>
    </StackPanel>

    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button Name="CancelBtn" Content="Cancel" Width="90" Margin="0,0,8,0"/>
      <Button Name="OkBtn"     Content="Protect" Width="110" IsDefault="True"/>
    </StackPanel>
  </Grid>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$FilePathText = $window.FindName('FilePathText')
$WarnBar      = $window.FindName('WarnBar')
$WarnText     = $window.FindName('WarnText')
$SearchBox    = $window.FindName('SearchBox')
$ResultsList  = $window.FindName('ResultsList')
$ManualPwd    = $window.FindName('ManualPwd')
$ManualPwd2   = $window.FindName('ManualPwd2')
$ManualHint   = $window.FindName('ManualHint')
$OverwriteBox = $window.FindName('OverwriteBox')
$DeleteBox    = $window.FindName('DeleteBox')
$OutlookBox   = $window.FindName('OutlookBox')
$OkBtn        = $window.FindName('OkBtn')
$CancelBtn    = $window.FindName('CancelBtn')

$FilePathText.Text = $FilePath

if ($ClientList.Warning) {
    $WarnBar.Visibility = 'Visible'
    $WarnText.Text = $ClientList.Warning
}

if (-not $OfferOutlook -or -not $Config.outlook_integration) {
    $OutlookBox.Visibility = 'Collapsed'
}

# Result holder passed back to caller.
$script:result = @{
    SecurePassword = $null
    PasswordSource = $null
    ClientFileRef  = $null
    DeleteOriginal = $false
    AllowOverwrite = $false
    OpenOutlook    = $false
    Cancelled      = $true
}

$script:selectedClient = $null

# Wire up type-ahead.
$SearchBox.Add_TextChanged({
    $ResultsList.Items.Clear()
    $script:selectedClient = $null
    if ([string]::IsNullOrWhiteSpace($SearchBox.Text)) { return }
    $matches = & {
        . "$PSScriptRoot\Find-Client.ps1"
        Find-Client -ClientList $ClientList -Query $SearchBox.Text
    }
    foreach ($m in $matches) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $m.Display
        $item.Tag = $m
        $ResultsList.Items.Add($item) | Out-Null
    }
})

$ResultsList.Add_SelectionChanged({
    if ($ResultsList.SelectedItem) {
        $script:selectedClient = $ResultsList.SelectedItem.Tag
        # Clear manual fields so user intent is unambiguous.
        $ManualPwd.Password = ''
        $ManualPwd2.Password = ''
    }
})

function Test-ManualComplexity {
    param([System.Security.SecureString] $Secure, [int] $MinLen, [int] $ReqClasses)
    if ($null -eq $Secure -or $Secure.Length -lt $MinLen) { return $false }
    # Marshal briefly to validate, zero immediately.
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $classes = 0
        if ($plain -cmatch '[a-z]') { $classes++ }
        if ($plain -cmatch '[A-Z]') { $classes++ }
        if ($plain -cmatch '\d')    { $classes++ }
        if ($plain -cmatch '[^\w]') { $classes++ }
        return $classes -ge $ReqClasses
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        Remove-Variable plain -ErrorAction SilentlyContinue
    }
}

$OkBtn.Add_Click({
    $script:result.AllowOverwrite = [bool]$OverwriteBox.IsChecked
    $script:result.DeleteOriginal = [bool]$DeleteBox.IsChecked
    $script:result.OpenOutlook    = [bool]$OutlookBox.IsChecked

    if ($script:selectedClient) {
        # Build SecureString from DOB digits without ever creating a
        # long-lived managed-string copy.
        $ss = New-Object System.Security.SecureString
        foreach ($ch in $script:selectedClient.Dob.ToCharArray()) { $ss.AppendChar($ch) }
        $ss.MakeReadOnly()
        $script:result.SecurePassword = $ss
        $script:result.PasswordSource = 'dob'
        $script:result.ClientFileRef  = $script:selectedClient.FileRef
        $script:result.Cancelled = $false
        $window.Close()
        return
    }

    # Manual path.
    if ($ManualPwd.SecurePassword.Length -eq 0) {
        [System.Windows.MessageBox]::Show('Select a client or enter a password.','No password') | Out-Null
        return
    }
    if ($ManualPwd.Password -cne $ManualPwd2.Password) {
        [System.Windows.MessageBox]::Show('Password confirmation does not match.','Confirm') | Out-Null
        return
    }
    $ok = Test-ManualComplexity -Secure $ManualPwd.SecurePassword `
        -MinLen $Config.manual_password_min_length `
        -ReqClasses $Config.manual_password_required_classes
    if (-not $ok) {
        [System.Windows.MessageBox]::Show(
            "Manual password must be at least $($Config.manual_password_min_length) characters with at least $($Config.manual_password_required_classes) character classes (lower, upper, digit, symbol).",
            'Password too weak') | Out-Null
        return
    }
    $script:result.SecurePassword = $ManualPwd.SecurePassword.Copy()
    $script:result.SecurePassword.MakeReadOnly()
    $script:result.PasswordSource = 'manual'
    $script:result.ClientFileRef  = $null
    $script:result.Cancelled = $false
    $window.Close()
})

$CancelBtn.Add_Click({ $window.Close() })

$window.ShowDialog() | Out-Null

return $script:result
