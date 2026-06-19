#Requires -Version 5.1
<#
.SYNOPSIS
    Always-on drop window for the standalone PasswordProtect tool. Shown only
    when the program is launched with no file arguments (i.e. double-clicked).
.OUTPUTS
    [string[]] the dropped file paths (empty if the user closed the window).
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Password Protect"
        Width="440" Height="300" WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" SizeToContent="Manual">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Name="DropZone" AllowDrop="True"
            Background="#F3F7FF" BorderBrush="#7AA7E0" BorderThickness="2"
            CornerRadius="8" Padding="20">
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
        <TextBlock Text="Drag PDF or document files here" FontSize="16" FontWeight="Bold"
                   HorizontalAlignment="Center" Foreground="#2B5797"/>
        <TextBlock Text="PDFs become password-protected PDFs; other files become encrypted .7z archives."
                   TextWrapping="Wrap" TextAlignment="Center" Foreground="#666" Margin="0,8,0,0"/>
        <TextBlock Text="You'll be asked for a date of birth to use as the password."
                   TextWrapping="Wrap" TextAlignment="Center" Foreground="#666" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button Name="CloseBtn" Content="Close" Width="90"/>
    </StackPanel>
  </Grid>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$DropZone = $window.FindName('DropZone')
$CloseBtn = $window.FindName('CloseBtn')

$script:dropped = @()

$DropZone.Add_DragOver({
    param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { $e.Effects = 'Copy' }
    else { $e.Effects = 'None' }
    $e.Handled = $true
})

$DropZone.Add_Drop({
    param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $script:dropped = @($e.Data.GetData([Windows.DataFormats]::FileDrop))
        $window.Close()
    }
})

$CloseBtn.Add_Click({ $window.Close() })

$window.ShowDialog() | Out-Null

return $script:dropped
