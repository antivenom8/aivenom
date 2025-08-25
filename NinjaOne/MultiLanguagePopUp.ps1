<#
.SYNOPSIS
    Reboot reminder that will display in the language of the OS.

.DESCRIPTION
    Reboot reminder that will display in the language of the OS. Uses Google's unoffical translate API.

    # ---------------------------------------------------------------
    # Author: Mark Giordano
    # Date: 8/20/2025
    # ---------------------------------------------------------------

.NOTES
    Script Form Variables
    Name: Threshold
    Type: Int
    Set the # of days the device needs to be up by to determine if a reboot is needed.

    Name: Language
    Type: String/Text
    This allows you to enter the 2 letter set to indicate the language the pop up should display in.
    This will override the detection part of the script so it doesn't use the detected languade from OS.
    https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes
    
#>


function Get-Translation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Original,
        [Parameter(Mandatory = $true)]
        [string]$TargetLanguage
    )

    $Encode = [uri]::EscapeDataString($Original)
    $uri = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$TargetLanguage&dt=t&q=$Encode"
    try {
        $Response = Invoke-RestMethod $Uri
        return ($Response[0] | ForEach-Object { $_[0] }) -join ''
    }
    catch {
        #In case translation fails, returning the original English text
        return $Original 
    }
}

$Threshold = [int]$env:Threshold
if (!($Threshold)) {
    Write-Host 'No threshold entered. Cannot continue.'
    exit 0
}

Add-Type -AssemblyName PresentationCore, PresentationFramework | Out-Null

$DaysSinceLastReboot = (New-TimeSpan -Start ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime) -End ([DateTime]::Now)).Days

# Exiting immediately if the computer has been up for less than 10 days.
if ($DaysSinceLastReboot -lt $Threshold) {
    Write-Host "Computer uptime is at $($DaysSinceLastReboot) days. Reboot not needed. Exiting."
    exit 0
}

$PopupDetails = @{
    Title        = 'Reboot Recommended'
    Msg          = "To maintain optimal performance, please reboot your computer every $($Threshold) days."
    RebootButton = 'Reboot Now'
    CancelButton = 'Cancel' 
}

$Culture = Get-UICulture
$OSLanguage = $($Culture.TwoLetterISOLanguageName)
if ($env:Language) {
    $OSLanguage = $env:Language
}

if ($ToLanguage -ne 'en') {
    foreach ($Key in @($PopupDetails.Keys)) {
        $PopupDetails[$Key] = Get-Translation -Original $PopupDetails[$Key] -TargetLanguage $OSLanguage
    }
}

$Xaml = @"
  <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
          SizeToContent="WidthAndHeight"
          WindowStartupLocation="CenterScreen"
          ResizeMode="NoResize"
          Topmost="True"
          WindowStyle="ToolWindow"
          ShowInTaskbar="True">
    <Grid Margin="20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="25"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="MessageText"
                 TextWrapping="Wrap"
                 MaxWidth="400"
                 FontSize="16"/>
      <StackPanel Grid.Row="2"
                  Orientation="Horizontal"
                  HorizontalAlignment="Right">
        <Button x:Name="RebootButton" Margin="0,10,10,0" Padding="14,8"/>
        <Button x:Name="CancelButton" Margin="0,10,0,0" Padding="14,8"/>
      </StackPanel>
    </Grid>
  </Window>
"@
  
$ReadXaml = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($ReadXaml)
  
$Window.Title = $PopupDetails.Title
$MessageText = $Window.FindName('MessageText')
$RebootButton = $Window.FindName('RebootButton')
$CancelButton = $Window.FindName('CancelButton')
$MessageText.Text = $PopupDetails.Msg
$RebootButton.Content = $PopupDetails.RebootButton
$CancelButton.Content = $PopupDetails.CancelButton

Add-Type -AssemblyName WindowsBase | Out-Null
$TimeoutMinutes = 3
$StopTime = (Get-Date).AddMinutes($TimeoutMinutes)

$CancelButton.Content = ("{0} ({1:mm\:ss})" -f $PopupDetails.Cancel, ([TimeSpan]::FromMinutes($TimeoutMinutes)))

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromSeconds(1)
$Timer.Add_Tick({
        $Remaining = $StopTime - (Get-Date)
        if ($Remaining -le [TimeSpan]::Zero) {
            $Timer.Stop()
            $Window.Close()
            return
        }
        $CancelButton.Content = ("{0} ({1:mm\:ss})" -f $PopupDetails.CancelButton, $Remaining)
    })
  
$Timer.Start()
    
$RebootButton.Add_Click({
        $Timer.Stop()
        try {
            Restart-Computer -Force
        }
        catch {
            Write-Host "Failed to restart computer. The following error occured:"
            Write-Host "$($_.Exception.Message)"
        }
        $Windows.Close()
    })

$CancelButton.Add_Click({ $Window.Close() })
  
[void]$Window.ShowDialog()

exit 0